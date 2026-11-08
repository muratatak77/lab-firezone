defmodule Portal.DevicesTest do
  use Portal.DataCase, async: true

  import Ecto.Query

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.SiteFixtures
  import Portal.SubjectFixtures

  alias Portal.Device
  alias Portal.Devices
  alias Portal.GatewayToken
  alias Portal.SiteDevice

  describe "provision_gateway/3" do
    test "creates a gateway and mints its single-owner token" do
      account = account_fixture()
      site = site_fixture(account: account)
      subject =
        subject_fixture(account: account, actor: %{type: :api_client, account: account})

      assert {:ok, %Device{} = gateway, %GatewayToken{} = token, encoded_token} =
               Devices.provision_gateway(site, "edge-nyc-1", subject)

      assert gateway.name == "edge-nyc-1"
      assert gateway.site_id == site.id
      assert gateway.account_id == site.account_id
      assert gateway.type == :gateway

      assert Repo.get_by(SiteDevice,
               account_id: account.id,
               site_id: site.id,
               device_id: gateway.id
             )

      assert token.device_id == gateway.id
      assert is_nil(token.site_id)
      # secret_fragment is scrubbed - only the encoded token carries the secret.
      assert is_nil(token.secret_fragment)
      assert is_binary(encoded_token)
    end

    # Regression: the Device insert and the GatewayToken insert are
    # authorized separately - Safe.permit/3 lets an account_user insert a
    # Device (clients create their own row on first connect) but not a
    # GatewayToken. Before both writes shared a transaction, the Device
    # was committed and then the token insert returned :unauthorized,
    # leaving a tokenless Gateway behind while the caller saw a 401.
    test "leaves no gateway behind when the caller cannot mint a token" do
      account = account_fixture()
      site = site_fixture(account: account)

      subject =
        subject_fixture(account: account, actor: %{type: :account_user, account: account})

      assert {:error, :unauthorized} = Devices.provision_gateway(site, "orphan-gw", subject)

      assert Repo.aggregate(
               from(d in Device, where: d.site_id == ^site.id and d.type == :gateway),
               :count
             ) == 0

      assert Repo.aggregate(
               from(t in GatewayToken, where: t.account_id == ^account.id),
               :count
             ) == 0

      assert Repo.aggregate(
               from(sd in SiteDevice, where: sd.account_id == ^account.id),
               :count
             ) == 0
    end

    test "generates a random name when none is given" do
      account = account_fixture()
      site = site_fixture(account: account)
      subject =
        subject_fixture(account: account, actor: %{type: :api_client, account: account})

      assert {:ok, %Device{name: name}, _token, _encoded_token} =
               Devices.provision_gateway(site, nil, subject)

      refute is_nil(name)
      refute name == ""
    end
  end

  describe "next_free_slug/3" do
    setup do
      %{account: account_fixture()}
    end

    test "slugs the device name", %{account: account} do
      assert Devices.next_free_slug(account.id, "Jamil's MacBook Pro", nil) == "jamils-macbook-pro"
      assert Devices.next_free_slug(account.id, "Pixel 8", nil) == "pixel-8"
      assert Devices.next_free_slug(account.id, "DESKTOP-ABC123", nil) == "desktop-abc123"
    end

    test "keeps only the part before the first dot", %{account: account} do
      assert Devices.next_free_slug(account.id, "Jamils-MacBook-Pro.local", nil) ==
               "jamils-macbook-pro"
    end

    test "drops curly apostrophes and non-ASCII letters", %{account: account} do
      assert Devices.next_free_slug(account.id, "Zoë’s iPhone", nil) == "zo-s-iphone"
    end

    test "collapses runs of separators and trims the ends", %{account: account} do
      assert Devices.next_free_slug(account.id, "  --my__laptop!! ", nil) == "my-laptop"
    end

    test "falls back to device when nothing is left", %{account: account} do
      assert Devices.next_free_slug(account.id, "***", nil) == "device"
    end

    test "puts the owner's first name in front of stock names", %{account: account} do
      assert Devices.next_free_slug(account.id, "iPhone", "Jamil Bou Kheir") == "jamils-iphone"
      assert Devices.next_free_slug(account.id, "DESKTOP-ABC123", "Jamil") == "jamils-desktop-abc123"
      assert Devices.next_free_slug(account.id, "iPad", "jamil@firezone.dev") == "jamils-ipad"
      assert Devices.next_free_slug(account.id, "iPhone", "James Smith") == "james-iphone"
      assert Devices.next_free_slug(account.id, "***", "Jamil") == "jamils-device"
    end

    test "leaves names that already carry the owner's name alone", %{account: account} do
      assert Devices.next_free_slug(account.id, "Jamil's MacBook Pro", "Jamil Bou Kheir") ==
               "jamils-macbook-pro"

      assert Devices.next_free_slug(account.id, "Jamils-MacBook-Pro.local", "Jamil") ==
               "jamils-macbook-pro"

      assert Devices.next_free_slug(account.id, "jamil-laptop", "Jamil") == "jamil-laptop"
      assert Devices.next_free_slug(account.id, "Samsung Galaxy", "Sam") == "sams-samsung-galaxy"
    end

    test "ignores an owner name that leaves no label", %{account: account} do
      assert Devices.next_free_slug(account.id, "iPhone", "***") == "iphone"
      assert Devices.next_free_slug(account.id, "iPhone", "") == "iphone"
    end

    test "numbers a slug another device in the account holds", %{account: account} do
      actor = actor_fixture(account: account, name: "Jamil Bou Kheir")
      client_fixture(account: account, actor: actor, name: "iPhone")
      client_fixture(account: account, actor: actor, name: "iPhone")

      assert Devices.next_free_slug(account.id, "iPhone", "Jamil Bou Kheir") == "jamils-iphone-3"
      assert Devices.next_free_slug(account_fixture().id, "iPhone", "Jamil") == "jamils-iphone"
    end

    test "trims a long owner name rather than crowding out the device name", %{account: account} do
      owner = String.duplicate("a", 70)
      slug = Devices.next_free_slug(account.id, "iPhone", owner)

      assert String.length(slug) == 63
      assert String.ends_with?(slug, "-iphone")

      email_owner = String.duplicate("b", 64) <> "@example.com"
      email_slug = Devices.next_free_slug(account.id, "MacBook Pro", email_owner)

      assert String.length(email_slug) == 63
      assert String.ends_with?(email_slug, "-macbook-pro")
    end

    test "drops the owner name when the device name fills the label", %{account: account} do
      slug = Devices.next_free_slug(account.id, String.duplicate("c", 70), "Jamil")

      assert slug == String.duplicate("c", 63)
    end

    test "caps the slug at 63 characters, numbers included", %{account: account} do
      name = String.duplicate("a", 70)
      assert String.length(Devices.next_free_slug(account.id, name, nil)) == 63

      client_fixture(account: account, name: name, slug: Devices.next_free_slug(account.id, name, nil))
      numbered = Devices.next_free_slug(account.id, name, nil)

      assert String.length(numbered) == 63
      assert String.ends_with?(numbered, "-2")
    end
  end

  describe "verify_client/3" do
    setup do
      account = account_fixture()
      client = client_fixture(account: account)
      subject = admin_subject_fixture(account: account)

      %{account: account, client: client, subject: subject}
    end

    test "verifies a client until revoked and records the verification", %{
      client: client,
      subject: subject
    } do
      assert {:ok, %Device{} = verified} = Devices.verify_client(client, %{}, subject)

      assert verified.verified_at
      assert is_nil(verified.verification_expires_at)
      assert Device.verified?(verified)

      assert [verification] = verifications(client)
      assert verification.verified_at == verified.verified_at
      assert is_nil(verification.expires_at)
      assert is_nil(verification.revoked_at)
      assert is_nil(verification.note)
    end

    test "verifies a client until expires_at with a note", %{client: client, subject: subject} do
      expires_at = DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second)

      assert {:ok, verified} =
               Devices.verify_client(
                 client,
                 %{"expires_at" => DateTime.to_iso8601(expires_at), "note" => "  Asset tag 4471  "},
                 subject
               )

      assert DateTime.compare(verified.verification_expires_at, expires_at) == :eq

      assert [verification] = verifications(client)
      assert DateTime.compare(verification.expires_at, expires_at) == :eq
      assert verification.note == "Asset tag 4471"
    end

    test "changes nothing when verified again on the same terms", %{
      client: client,
      subject: subject
    } do
      attrs = %{"expires_at" => DateTime.add(DateTime.utc_now(), 1, :day), "note" => "Lab"}

      assert {:ok, first} = Devices.verify_client(client, attrs, subject)
      assert {:ok, second} = Devices.verify_client(first, attrs, subject)

      assert second.verified_at == first.verified_at
      assert [_verification] = verifications(client)
    end

    test "keeps a verification recorded before expiries existed", %{client: client, subject: subject} do
      verified_at = DateTime.add(DateTime.utc_now(), -10, :day)
      client = client |> Ecto.Changeset.change(verified_at: verified_at) |> Repo.update!()
      device_verification_fixture(client, verified_at: verified_at)

      assert {:ok, verified} = Devices.verify_client(client, %{}, subject)

      assert DateTime.compare(verified.verified_at, verified_at) == :eq
      assert [_verification] = verifications(client)
    end

    test "revokes the current verification when verified on other terms", %{
      client: client,
      subject: subject
    } do
      assert {:ok, first} = Devices.verify_client(client, %{}, subject)

      expires_at = DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second)

      assert {:ok, second} =
               Devices.verify_client(first, %{"expires_at" => expires_at}, subject)

      assert DateTime.compare(second.verification_expires_at, expires_at) == :eq
      assert DateTime.compare(second.verified_at, first.verified_at) == :gt

      assert [current, previous] = verifications(client)
      assert is_nil(current.revoked_at)
      assert DateTime.compare(current.expires_at, expires_at) == :eq
      assert DateTime.compare(previous.revoked_at, second.verified_at) == :eq
    end

    test "starts a new verification once the current one has expired", %{
      client: client,
      subject: subject
    } do
      verified_at = DateTime.add(DateTime.utc_now(), -10, :day)
      expires_at = DateTime.add(DateTime.utc_now(), -1, :day)

      client =
        client
        |> Ecto.Changeset.change(verified_at: verified_at, verification_expires_at: expires_at)
        |> Repo.update!()

      expired = device_verification_fixture(client, verified_at: verified_at, expires_at: expires_at)

      assert {:ok, verified} = Devices.verify_client(client, %{}, subject)

      assert Device.verified?(verified)
      assert is_nil(verified.verification_expires_at)
      assert Repo.get_by!(Portal.DeviceVerification, id: expired.id).revoked_at
    end

    test "refuses an expiry that is not in the future", %{client: client, subject: subject} do
      past = DateTime.add(DateTime.utc_now(), -1, :minute)

      assert {:error, changeset} = Devices.verify_client(client, %{"expires_at" => past}, subject)
      assert %{expires_at: ["must be in the future"]} = errors_on(changeset)

      assert is_nil(Repo.get_by!(Device, id: client.id).verified_at)
      assert verifications(client) == []
    end

    test "refuses a note longer than 1024 characters", %{client: client, subject: subject} do
      note = String.duplicate("a", 1025)

      assert {:error, changeset} = Devices.verify_client(client, %{"note" => note}, subject)
      assert %{note: ["should be at most 1024 character(s)"]} = errors_on(changeset)
    end

    test "is refused to actors that are not admins" do
      account = account_fixture()
      client = client_fixture(account: account)
      subject = subject_fixture(account: account, actor: %{type: :account_user, account: account})

      assert {:error, :unauthorized} = Devices.verify_client(client, %{}, subject)

      assert is_nil(Repo.get_by!(Device, id: client.id).verified_at)
      assert verifications(client) == []
    end
  end

  describe "unverify_client/2" do
    setup do
      account = account_fixture()
      client = client_fixture(account: account)
      subject = admin_subject_fixture(account: account)

      %{account: account, client: client, subject: subject}
    end

    test "revokes the verification of a client", %{client: client, subject: subject} do
      expires_at = DateTime.add(DateTime.utc_now(), 1, :day)
      {:ok, client} = Devices.verify_client(client, %{"expires_at" => expires_at}, subject)

      assert {:ok, unverified} = Devices.unverify_client(client, subject)

      assert is_nil(unverified.verified_at)
      assert is_nil(unverified.verification_expires_at)

      assert [verification] = verifications(client)
      assert verification.revoked_at
    end

    test "leaves a client that is not verified as it is", %{client: client, subject: subject} do
      assert {:ok, unverified} = Devices.unverify_client(client, subject)

      assert is_nil(unverified.verified_at)
      assert verifications(client) == []
    end

    test "returns a constraint violation as an error", %{client: client, subject: subject} do
      # Another node's clock ran ahead, so revoking now would end the
      # verification before it began.
      verified_at = DateTime.add(DateTime.utc_now(), 1, :hour)
      device_verification_fixture(client, verified_at: verified_at)

      assert {:error, %Ecto.Changeset{} = changeset} = Devices.unverify_client(client, subject)
      assert %{revoked_at: ["must not be before the verification started"]} = errors_on(changeset)
    end
  end

  describe "list_verifications/3" do
    test "lists the verifications of the client, most recent first" do
      account = account_fixture()
      client = client_fixture(account: account)
      other_client = client_fixture(account: account)
      subject = admin_subject_fixture(account: account)

      now = DateTime.utc_now()

      older =
        device_verification_fixture(client,
          verified_at: DateTime.add(now, -2, :day),
          revoked_at: DateTime.add(now, -1, :day)
        )

      newer = device_verification_fixture(client, verified_at: now)
      device_verification_fixture(other_client)

      assert {:ok, [first, second], _metadata} = Devices.list_verifications(client, subject)
      assert first.id == newer.id
      assert second.id == older.id
    end
  end

  defp verifications(client) do
    from(v in Portal.DeviceVerification,
      where: v.device_id == ^client.id,
      order_by: [desc: v.verified_at]
    )
    |> Repo.all()
  end

  describe "owner_name/1" do
    test "is the name of people and nothing for service accounts" do
      assert Devices.owner_name(%Portal.Actor{type: :account_user, name: "Jamil"}) == "Jamil"
      assert Devices.owner_name(%Portal.Actor{type: :account_admin_user, name: "Jamil"}) == "Jamil"
      assert is_nil(Devices.owner_name(%Portal.Actor{type: :service_account, name: "CI"}))
      assert is_nil(Devices.owner_name(nil))
    end
  end
end
