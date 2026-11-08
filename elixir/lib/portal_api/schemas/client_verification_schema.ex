defmodule PortalAPI.Schemas.ClientVerification do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    @derive {PortalAPI.JSON.Encoder,
             for: Portal.DeviceVerification,
             internal: [:account_id, :device_id, :inserted_at, :updated_at]}
    OpenApiSpex.schema(%{
      title: "ClientVerification",
      description: "A period a Client spent verified",
      type: :object,
      properties: %{
        id: %Schema{
          example: "0b2d4c1e-7a8f-4e3b-9c6d-5f1a2b3c4d5e",
          type: :string,
          format: :uuid,
          description: "Verification ID"
        },
        client_id: %Schema{
          example: "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          type: :string,
          format: :uuid,
          description: "ID of the verified Client"
        },
        verified_at: %Schema{
          example: "2025-01-01T00:00:00Z",
          type: :string,
          format: :"date-time",
          description: "When the verification started"
        },
        expires_at: %Schema{
          example: "2025-04-01T00:00:00Z",
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "When the verification stops counting. Null when it holds until revoked."
        },
        revoked_at: %Schema{
          example: "2025-02-01T00:00:00Z",
          type: :string,
          format: :"date-time",
          nullable: true,
          description:
            "When the verification ended before or after expiring, by unverifying the Client " <>
              "or by verifying it again on different terms"
        },
        note: %Schema{
          example: "Asset tag 4471, checked by IT",
          type: :string,
          nullable: true,
          description: "Why the Client was verified"
        },
        status: %Schema{
          type: :string,
          enum: ["active", "expired", "revoked"],
          description: "Where the verification stands now"
        }
      },
      required: [:id, :client_id, :verified_at, :expires_at, :revoked_at, :note, :status]
    })

    def map(%Portal.DeviceVerification{} = verification, _map) do
      %{
        client_id: verification.device_id,
        status: verification |> Portal.DeviceVerification.status() |> Atom.to_string()
      }
    end
  end

  defmodule Request do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "ClientVerifyRequest",
      description:
        "Optional PUT body for verifying a Client. Without it the Client is verified until " <>
          "the verification is revoked.",
      type: :object,
      properties: %{
        verification: %Schema{
          type: :object,
          properties: %{
            expires_at: %Schema{
              example: "2025-04-01T00:00:00Z",
              type: :string,
              format: :"date-time",
              nullable: true,
              description:
                "When the verification stops counting, in the future. Policies that require " <>
                  "a verified Client stop granting access at this time. Omit or set to null " <>
                  "for a verification that holds until revoked."
            },
            note: %Schema{
              example: "Asset tag 4471, checked by IT",
              type: :string,
              nullable: true,
              maxLength: 1024,
              description: "Why the Client is verified"
            }
          }
        }
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.ClientVerification
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(%{
      title: "ClientVerificationListResponse",
      description: "Response schema for the verifications of a Client",
      type: :object,
      properties: %{
        data: %Schema{
          description: "Verifications, most recent first",
          type: :array,
          items: ClientVerification.Schema
        },
        metadata: PaginationMetadata
      }
    })
  end
end
