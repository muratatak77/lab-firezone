defmodule Portal.Repo.Migrations.BackfillDeviceVerifications do
  use Ecto.Migration

  # Every client verified today gets the open-ended verification it already
  # has. Gateways cannot be verified, see Portal.Device.changeset/1.
  def up do
    execute("""
    INSERT INTO device_verifications
      (account_id, id, device_id, verified_at, expires_at, inserted_at, updated_at)
    SELECT account_id, gen_random_uuid(), id, verified_at, verification_expires_at, verified_at, verified_at
    FROM devices
    WHERE type = 'client' AND verified_at IS NOT NULL
    ON CONFLICT DO NOTHING
    """)
  end

  # Rows written by the app since the backfill are indistinguishable from it.
  def down, do: :ok
end
