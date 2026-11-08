defmodule PortalAPI.ClientVerificationController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Pagination
  alias PortalAPI.JSON
  alias PortalAPI.Error
  alias PortalAPI.Schemas.ProblemDetails
  alias __MODULE__.Database

  tags ["Clients"]

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :index,
    summary: "List Verifications for a Client",
    description: """
    Lists every period the Client spent verified, most recent first. At most \
    one of them has not been revoked; it is `active` until it expires.
    """,
    parameters: [
      client_id: [
        in: :path,
        description: "Client ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ],
      limit: [
        in: :query,
        description: "Limit Verifications returned",
        schema: PortalAPI.Pagination.limit_schema(),
        example: 10
      ],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string]
    ],
    responses:
      [
        ok:
          {"Client Verification List Response", "application/json",
           PortalAPI.Schemas.ClientVerification.ListResponse}
      ] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :not_found, :too_many_requests])

  # coveralls-ignore-stop

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, %{"client_id" => client_id} = params) do
    subject = conn.assigns.subject

    with {:ok, list_opts} <- Pagination.params_to_list_opts(params),
         {:ok, client} <- Database.fetch_client(client_id, subject),
         {:ok, verifications, metadata} <-
           Portal.Devices.list_verifications(client, subject, list_opts) do
      json(
        conn,
        JSON.encode(verifications, metadata, schema: PortalAPI.Schemas.ClientVerification.Schema)
      )
    else
      error -> Error.handle(conn, error)
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{Device, Safe}

    def fetch_client(id, subject) do
      from(d in Device, as: :devices)
      |> where([devices: d], d.id == ^id and d.type == :client)
      |> Safe.scoped(subject)
      |> Safe.one()
      |> case do
        nil -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
        client -> {:ok, client}
      end
    end
  end
end
