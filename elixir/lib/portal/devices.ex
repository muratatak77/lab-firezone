defmodule Portal.Devices do
  @moduledoc """
  Domain functions for provisioning devices, shared between the admin
  LiveView (`PortalWeb.Live.Sites`) and the REST API
  (`PortalAPI.GatewayController`) so there's one source of truth for the
  "insert a gateway and mint its single-owner token" flow.

  Verifying and unverifying a client is shared the same way between
  `PortalWeb.Devices` and `PortalAPI.ClientController`, so the device row and
  its `Portal.DeviceVerification` history never disagree.
  """

  alias Portal.Authentication
  alias Portal.Device
  alias Portal.DeviceVerification
  alias Portal.GatewayToken
  alias Portal.Site
  alias __MODULE__.Database

  @doc "Puts the slug a device named in `changeset` gets in `account_id`, see `next_free_slug/3`."
  @spec put_free_slug(Ecto.Changeset.t(), Ecto.UUID.t(), String.t() | nil) :: Ecto.Changeset.t()
  defdelegate put_free_slug(changeset, account_id, owner_name), to: Database

  @doc """
  The slug a device named `name` gets in `account_id`, composed by the `device_slug`
  database function: the name's first dotted part, lowercased, with `owner_name`'s
  first name in front unless the name already carries it, then numbered when
  another device in the account holds it.
  """
  @spec next_free_slug(Ecto.UUID.t(), String.t(), String.t() | nil) :: String.t()
  defdelegate next_free_slug(account_id, name, owner_name), to: Database

  @doc "The name that prefixes a device slug: the owner's for people, nothing for service accounts."
  @spec owner_name(Portal.Actor.t() | nil) :: String.t() | nil
  def owner_name(%Portal.Actor{type: type, name: name})
      when type in [:account_user, :account_admin_user],
      do: name

  def owner_name(_actor), do: nil

  @doc """
  Inserts a Gateway without a token.

  The Gateway cannot connect until a token is minted for it, which is a
  separate grant: callers that may manage Gateways are not necessarily allowed
  to hand out the credential that lets one join a Site.
  """
  @spec create_gateway(Site.t(), String.t() | nil, Authentication.Subject.t()) ::
          {:ok, Device.t()} | {:error, term()}
  def create_gateway(%Site{} = site, name, %Authentication.Subject{} = subject) do
    Database.insert_gateway(site, name, subject)
  end

  @doc """
  Inserts a Gateway and mints its single-owner token.

  Both writes happen in one transaction. They are separately authorized -
  `Safe.permit/3` lets an `account_user` insert a Device (clients create
  their own row on first connect) but not a GatewayToken - so without the
  transaction a caller who can do the first and not the second gets a 401
  back while a tokenless Gateway stays behind in their account. The same
  applies to any other failure of the token insert, not just an
  authorization one.
  """
  @spec provision_gateway(Site.t(), String.t() | nil, Authentication.Subject.t()) ::
          {:ok, Device.t(), GatewayToken.t(), binary()} | {:error, term()}
  def provision_gateway(%Site{} = site, name, %Authentication.Subject{} = subject) do
    with :ok <- Portal.Devices.RegistrationRateLimit.check(subject.account) do
      do_provision_gateway(site, name, subject)
    end
  end

  @doc """
  Verifies a client, optionally until `expires_at` and with a `note`.

  Verifying a client again on the terms it is already verified under changes
  nothing, so the call is idempotent. Different terms, or a verification that
  has expired, revoke the current verification and start a new one.

  Returns `{:ok, client}` with the client as it is verified now, or
  `{:error, reason}`, for example an invalid terms changeset or
  `:unauthorized`.
  """
  @spec verify_client(Device.t(), map(), Authentication.Subject.t()) ::
          {:ok, Device.t()} | {:error, term()}
  def verify_client(%Device{type: :client} = client, attrs, %Authentication.Subject{} = subject) do
    now = DateTime.utc_now()
    terms = DeviceVerification.terms_changeset(attrs, now)

    with {:ok, terms} <- Ecto.Changeset.apply_action(terms, :insert) do
      Database.transact(fn -> verify_locked_client(client, terms, now, subject) end)
    end
  end

  @doc """
  Revokes a client's verification. A client that is not verified is left as
  it is.

  Returns `{:ok, client}` with the client as it is now unverified, or
  `{:error, reason}`, for example `:unauthorized`.
  """
  @spec unverify_client(Device.t(), Authentication.Subject.t()) ::
          {:ok, Device.t()} | {:error, term()}
  def unverify_client(%Device{type: :client} = client, %Authentication.Subject{} = subject) do
    now = DateTime.utc_now()

    Database.transact(fn ->
      with {:ok, client} <- Database.lock_client(client, subject),
           {:ok, current} <- Database.fetch_unrevoked_verification(client, subject),
           {:ok, _revoked} <- revoke_verification(current, now, subject) do
        Database.update_verification_state(client, nil, nil, subject)
      end
    end)
  end

  @doc """
  Lists the verifications of a client, most recent first.

  Returns `{:ok, verifications, metadata}`, with the pagination metadata for
  the page, or `{:error, reason}`, for example `:unauthorized`.
  """
  @spec list_verifications(Device.t(), Authentication.Subject.t(), Keyword.t()) ::
          {:ok, [DeviceVerification.t()], Portal.Repo.Paginator.Metadata.t()} | {:error, term()}
  defdelegate list_verifications(client, subject, opts \\ []), to: Database

  defp verify_locked_client(client, terms, now, subject) do
    with {:ok, client} <- Database.lock_client(client, subject),
         {:ok, current} <- Database.fetch_unrevoked_verification(client, subject) do
      if Device.verified?(client, now) and same_terms?(current, terms) do
        {:ok, client}
      else
        start_verification(client, current, terms, now, subject)
      end
    end
  end

  defp same_terms?(nil, _terms), do: false

  defp same_terms?(%DeviceVerification{} = current, %DeviceVerification{} = terms) do
    current.note == terms.note and same_instant?(current.expires_at, terms.expires_at)
  end

  defp same_instant?(nil, nil), do: true
  defp same_instant?(%DateTime{} = left, %DateTime{} = right), do: DateTime.compare(left, right) == :eq
  defp same_instant?(_left, _right), do: false

  defp start_verification(client, current, terms, now, subject) do
    with {:ok, _revoked} <- revoke_verification(current, now, subject),
         {:ok, _verification} <- Database.insert_verification(client, terms, now, subject) do
      Database.update_verification_state(client, now, terms.expires_at, subject)
    end
  end

  defp revoke_verification(nil, _now, _subject), do: {:ok, nil}

  defp revoke_verification(%DeviceVerification{} = verification, now, subject),
    do: Database.revoke_verification(verification, now, subject)

  defp do_provision_gateway(site, name, subject) do
    Database.transact(fn ->
      with {:ok, gateway} <- Database.insert_gateway(site, name, subject),
           {:ok, token} <- Authentication.create_gateway_token(gateway, subject) do
        {:ok, {gateway, %{token | secret_fragment: nil}, Authentication.encode_fragment!(token)}}
      end
    end)
    |> case do
      {:ok, {gateway, token, encoded_fragment}} -> {:ok, gateway, token, encoded_fragment}
      {:error, reason} -> {:error, reason}
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    # Repo.transact/1 rolls the transaction back when fun returns
    # {:error, _}, which is what makes provision_gateway/3 all-or-nothing.
    def transact(fun), do: Safe.transact(fun)

    # Builds a changeset rather than a bare struct on purpose: Safe.insert/1
    # only applies the schema's own changeset/1 to changesets, not to structs
    # (see its two Scoped clauses). Inserting a struct here would skip
    # Device.changeset/1 entirely and persist names it rejects - blank,
    # whitespace-only, or longer than 255 - instead of returning the 422 the
    # provisioning endpoint documents.
    #
    # Only a nil name gets a generated one. An explicitly supplied blank
    # string is invalid input, not an omitted value, so it is validated and
    # refused rather than silently replaced.
    def insert_gateway(site, name, subject) do
      name = name || Portal.Crypto.random_token(5, encoder: :user_friendly)

      Safe.transact(fn ->
        with {:ok, gateway} <-
               %Device{}
               |> Ecto.Changeset.cast(%{name: name}, [:name])
               |> Ecto.Changeset.put_change(:type, :gateway)
               |> Ecto.Changeset.put_change(:site_id, site.id)
               |> put_free_slug(subject.account.id, nil)
               |> Safe.scoped(subject)
               |> Safe.insert(),
             {:ok, _site_device} <-
               %Portal.SiteDevice{site_id: site.id, device_id: gateway.id}
               |> Safe.scoped(subject)
               |> Safe.insert() do
          {:ok, gateway}
        end
      end)
    end

    # Serializes verification changes on a client, so two of them cannot both
    # find no verification in effect and both start one.
    def lock_client(client, subject) do
      from(d in Device, as: :devices)
      |> where([devices: d], d.id == ^client.id and d.type == :client)
      |> lock("FOR NO KEY UPDATE")
      |> Safe.scoped(subject)
      |> Safe.one()
      |> case do
        nil -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
        %Device{} = client -> {:ok, client}
      end
    end

    def fetch_unrevoked_verification(client, subject) do
      from(v in DeviceVerification, as: :device_verifications)
      |> where([device_verifications: v], v.device_id == ^client.id and is_nil(v.revoked_at))
      |> Safe.scoped(subject)
      |> Safe.one()
      |> case do
        {:error, reason} -> {:error, reason}
        verification -> {:ok, verification}
      end
    end

    def insert_verification(client, terms, now, subject) do
      %DeviceVerification{}
      |> Ecto.Changeset.change(
        device_id: client.id,
        verified_at: now,
        expires_at: terms.expires_at,
        note: terms.note
      )
      |> Safe.scoped(subject)
      |> Safe.insert()
    end

    def revoke_verification(verification, now, subject) do
      verification
      |> Ecto.Changeset.change(revoked_at: now)
      |> Safe.scoped(subject)
      |> Safe.update()
    end

    def update_verification_state(client, verified_at, expires_at, subject) do
      client
      |> Ecto.Changeset.change(verified_at: verified_at, verification_expires_at: expires_at)
      |> Safe.scoped(subject)
      |> Safe.update()
    end

    def list_verifications(client, subject, opts) do
      from(v in DeviceVerification, as: :device_verifications)
      |> where([device_verifications: v], v.device_id == ^client.id)
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, opts)
    end

    def cursor_fields do
      [
        {:device_verifications, :desc, :verified_at},
        {:device_verifications, :desc, :id}
      ]
    end

    def put_free_slug(changeset, account_id, owner_name) do
      case Ecto.Changeset.get_field(changeset, :name) do
        nil -> changeset
        name -> Ecto.Changeset.put_change(changeset, :slug, next_free_slug(account_id, name, owner_name))
      end
    end

    # Two devices inserted at the same time can still race for the slug; callers that
    # must not fail retry on the unique violation.
    def next_free_slug(account_id, name, owner_name) do
      from(
        slug in fragment(
          "SELECT next_free_device_slug(?, ?, ?) AS slug",
          type(^account_id, :binary_id),
          ^name,
          ^owner_name
        ),
        select: %{slug: slug.slug}
      )
      |> Safe.unscoped()
      |> Safe.one()
      |> Map.fetch!(:slug)
    end
  end
end
