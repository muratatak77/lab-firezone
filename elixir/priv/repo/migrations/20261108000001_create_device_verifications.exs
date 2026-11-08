defmodule Portal.Repo.Migrations.CreateDeviceVerifications do
  @moduledoc """
  Keeps every period a client spent verified, with the note it was verified
  under. `devices.verified_at` and `devices.verification_expires_at` stay the
  state policies are evaluated against; this table is the history behind it.

  A device has at most one verification that has not been revoked.
  """
  use Ecto.Migration

  def change do
    create table(:device_verifications, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:id, :binary_id, null: false, primary_key: true)

      add(
        :device_id,
        references(:devices,
          with: [account_id: :account_id],
          type: :binary_id,
          on_delete: :delete_all
        ),
        null: false
      )

      add(:verified_at, :timestamptz, null: false)
      add(:expires_at, :timestamptz)
      add(:revoked_at, :timestamptz)
      add(:note, :text)

      timestamps()
    end

    create(
      constraint(:device_verifications, :expires_after_verified,
        check: "expires_at IS NULL OR expires_at > verified_at"
      )
    )

    create(
      constraint(:device_verifications, :revoked_after_verified,
        check: "revoked_at IS NULL OR revoked_at >= verified_at"
      )
    )

    create(index(:device_verifications, [:account_id, :device_id, :verified_at]))

    create(
      unique_index(:device_verifications, [:account_id, :device_id],
        name: :device_verifications_unrevoked_index,
        where: "revoked_at IS NULL"
      )
    )
  end
end
