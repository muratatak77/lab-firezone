defmodule Portal.DeviceVerification do
  @moduledoc """
  One period a client device spent verified.

  A period ends when it is revoked, either by unverifying the device or by
  verifying it again on different terms, or when it expires on its own. The
  device row carries the current period's `verified_at` and `expires_at`, which
  is what policies are evaluated against.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Portal.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @note_max_length 1024

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          account_id: Ecto.UUID.t(),
          device_id: Ecto.UUID.t(),
          verified_at: DateTime.t(),
          expires_at: DateTime.t() | nil,
          revoked_at: DateTime.t() | nil,
          note: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "device_verifications" do
    belongs_to :account, Portal.Account, primary_key: true
    field :id, :binary_id, primary_key: true, autogenerate: true

    belongs_to :device, Portal.Device

    field :verified_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :note, :string

    timestamps()
  end

  @doc """
  Casts the terms an admin verifies a device under: when the verification
  expires, if ever, and a note on why the device was trusted.
  """
  @spec terms_changeset(map(), DateTime.t()) :: Ecto.Changeset.t()
  def terms_changeset(attrs, %DateTime{} = now) do
    %__MODULE__{}
    |> cast(attrs, [:expires_at, :note])
    |> trim_change(:note)
    |> validate_change(:expires_at, fn :expires_at, expires_at ->
      if DateTime.after?(expires_at, now), do: [], else: [expires_at: "must be in the future"]
    end)
    |> changeset()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_length(:note, min: 1, max: @note_max_length)
    |> assoc_constraint(:account)
    |> assoc_constraint(:device)
    |> check_constraint(:expires_at,
      name: :expires_after_verified,
      message: "must be after the verification started"
    )
    |> check_constraint(:revoked_at,
      name: :revoked_after_verified,
      message: "must not be before the verification started"
    )
    |> unique_constraint(:device_id,
      name: :device_verifications_unrevoked_index,
      message: "already has a verification in effect"
    )
  end

  @doc """
  Where the verification stands at `now`. A verification that had already
  expired when it was revoked, for example because the device was verified
  again afterwards, counts as expired.
  """
  @spec status(t(), DateTime.t()) :: :active | :expired | :revoked
  def status(%__MODULE__{} = verification, now \\ DateTime.utc_now()) do
    ended_at = verification.revoked_at || now

    cond do
      verification.expires_at && not DateTime.after?(verification.expires_at, ended_at) -> :expired
      verification.revoked_at -> :revoked
      true -> :active
    end
  end
end
