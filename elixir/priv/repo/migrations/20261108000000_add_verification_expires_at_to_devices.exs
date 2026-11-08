defmodule Portal.Repo.Migrations.AddVerificationExpiresAtToDevices do
  @moduledoc """
  Lets a client verification lapse on its own. NULL keeps today's behaviour of
  a verification that holds until it is revoked.

  The column starts out NULL everywhere, so the constraint is added NOT VALID
  and validated afterwards without blocking writes for the scan.
  """
  use Ecto.Migration

  @disable_ddl_transaction true

  def change do
    alter table(:devices) do
      add(:verification_expires_at, :timestamptz)
    end

    create(
      constraint(:devices, :verification_expires_at_requires_verified_at,
        check: "verification_expires_at IS NULL OR verified_at IS NOT NULL",
        validate: false
      )
    )

    execute(
      "ALTER TABLE devices VALIDATE CONSTRAINT verification_expires_at_requires_verified_at",
      ""
    )
  end
end
