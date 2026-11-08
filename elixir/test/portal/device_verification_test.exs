defmodule Portal.DeviceVerificationTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.DeviceFixtures

  alias Portal.Device
  alias Portal.DeviceVerification

  describe "terms_changeset/2" do
    setup do
      %{now: DateTime.utc_now()}
    end

    test "accepts no terms at all", %{now: now} do
      changeset = DeviceVerification.terms_changeset(%{}, now)

      assert changeset.valid?
      assert is_nil(Ecto.Changeset.get_field(changeset, :expires_at))
      assert is_nil(Ecto.Changeset.get_field(changeset, :note))
    end

    test "accepts an expiry in the future and trims the note", %{now: now} do
      expires_at = DateTime.add(now, 1, :hour)

      changeset =
        DeviceVerification.terms_changeset(%{"expires_at" => expires_at, "note" => " Lab "}, now)

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :expires_at) == expires_at
      assert Ecto.Changeset.get_field(changeset, :note) == "Lab"
    end

    test "refuses an expiry that is not in the future", %{now: now} do
      changeset = DeviceVerification.terms_changeset(%{"expires_at" => now}, now)

      assert %{expires_at: ["must be in the future"]} = errors_on(changeset)
    end

    test "refuses an expiry that is not a timestamp", %{now: now} do
      changeset = DeviceVerification.terms_changeset(%{"expires_at" => "next week"}, now)

      assert %{expires_at: ["is invalid"]} = errors_on(changeset)
    end

    test "refuses a note longer than 1024 characters", %{now: now} do
      changeset =
        DeviceVerification.terms_changeset(%{"note" => String.duplicate("a", 1025)}, now)

      assert %{note: ["should be at most 1024 character(s)"]} = errors_on(changeset)
    end
  end

  describe "status/2" do
    test "is revoked once revoked, whatever the expiry" do
      now = DateTime.utc_now()

      verification = %DeviceVerification{
        verified_at: DateTime.add(now, -2, :day),
        expires_at: DateTime.add(now, 1, :day),
        revoked_at: DateTime.add(now, -1, :day)
      }

      assert DeviceVerification.status(verification, now) == :revoked
    end

    test "is expired when it had expired before it was revoked" do
      now = DateTime.utc_now()

      verification = %DeviceVerification{
        verified_at: DateTime.add(now, -3, :day),
        expires_at: DateTime.add(now, -2, :day),
        revoked_at: DateTime.add(now, -1, :day)
      }

      assert DeviceVerification.status(verification, now) == :expired
    end

    test "is active until it expires" do
      now = DateTime.utc_now()
      verification = %DeviceVerification{verified_at: now, expires_at: DateTime.add(now, 1, :hour)}

      assert DeviceVerification.status(verification, now) == :active
      assert DeviceVerification.status(verification, DateTime.add(now, 1, :hour)) == :expired
      assert DeviceVerification.status(%{verification | expires_at: nil}, now) == :active
    end
  end

  describe "Portal.Device.verified?/2" do
    test "holds for a verification without an expiry" do
      assert Device.verified?(%Device{verified_at: DateTime.utc_now()})
      refute Device.verified?(%Device{verified_at: nil})
    end

    test "holds until the verification expires" do
      now = DateTime.utc_now()

      device = %Device{
        verified_at: DateTime.add(now, -1, :day),
        verification_expires_at: DateTime.add(now, 1, :hour)
      }

      assert Device.verified?(device, now)
      refute Device.verification_expired?(device, now)

      later = DateTime.add(now, 1, :hour)
      refute Device.verified?(device, later)
      assert Device.verification_expired?(device, later)
    end

    test "an unverified device is not expired" do
      refute Device.verification_expired?(%Device{verified_at: nil})
    end
  end

  describe "database constraints" do
    test "allow one verification in effect per device" do
      account = account_fixture()
      client = client_fixture(account: account)

      device_verification_fixture(client)

      assert {:error, changeset} =
               %DeviceVerification{account_id: account.id}
               |> Ecto.Changeset.change(device_id: client.id, verified_at: DateTime.utc_now())
               |> DeviceVerification.changeset()
               |> Repo.insert()

      assert %{device_id: ["already has a verification in effect"]} = errors_on(changeset)
    end

    test "refuse an expiry that is not after the verification started" do
      account = account_fixture()
      client = client_fixture(account: account)
      now = DateTime.utc_now()

      assert {:error, changeset} =
               %DeviceVerification{account_id: account.id}
               |> Ecto.Changeset.change(device_id: client.id, verified_at: now, expires_at: now)
               |> DeviceVerification.changeset()
               |> Repo.insert()

      assert %{expires_at: ["must be after the verification started"]} = errors_on(changeset)
    end

    test "refuse an expiry on a device that is not verified" do
      account = account_fixture()
      client = client_fixture(account: account)

      assert {:error, changeset} =
               client
               |> Ecto.Changeset.change(verification_expires_at: DateTime.utc_now())
               |> Device.changeset()
               |> Repo.update()

      assert %{verification_expires_at: ["requires the device to be verified"]} =
               errors_on(changeset)
    end

    test "are deleted with their device" do
      account = account_fixture()
      client = client_fixture(account: account)
      verification = device_verification_fixture(client)

      Repo.delete!(client)

      refute Repo.get_by(DeviceVerification, id: verification.id)
    end
  end
end
