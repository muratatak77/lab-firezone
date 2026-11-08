defmodule PortalAPI.ClientVerificationControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.SiteFixtures

  setup do
    account = account_fixture()
    actor = api_client_fixture(account: account)
    client = client_fixture(account: account)

    %{account: account, actor: actor, client: client}
  end

  describe "index/2" do
    test "returns error when not authorized", %{conn: conn, client: client} do
      conn = get(conn, ~p"/clients/#{client}/verifications")

      assert %{"type" => "about:blank", "status" => 401, "title" => "Unauthorized"} =
               json_response(conn, 401)
    end

    test "lists the verifications of the client, most recent first", %{
      conn: conn,
      account: account,
      actor: actor,
      client: client
    } do
      now = DateTime.utc_now()

      revoked =
        device_verification_fixture(client,
          verified_at: DateTime.add(now, -3, :day),
          revoked_at: DateTime.add(now, -2, :day),
          note: "Loaner"
        )

      active =
        device_verification_fixture(client,
          verified_at: DateTime.add(now, -1, :day),
          expires_at: DateTime.add(now, 30, :day)
        )

      device_verification_fixture(client_fixture(account: account))

      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/clients/#{client}/verifications")

      assert %{"data" => [first, second], "metadata" => %{"count" => 2}} = json_response(conn, 200)

      assert first["id"] == active.id
      assert first["client_id"] == client.id
      assert first["status"] == "active"
      assert first["expires_at"]
      assert is_nil(first["revoked_at"])
      assert is_nil(first["note"])

      assert second["id"] == revoked.id
      assert second["status"] == "revoked"
      assert second["revoked_at"]
      assert second["note"] == "Loaner"
    end

    test "reports a verification that has lapsed as expired", %{
      conn: conn,
      actor: actor,
      client: client
    } do
      now = DateTime.utc_now()

      device_verification_fixture(client,
        verified_at: DateTime.add(now, -2, :day),
        expires_at: DateTime.add(now, -1, :day)
      )

      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/clients/#{client}/verifications")

      assert %{"data" => [%{"status" => "expired"}]} = json_response(conn, 200)
    end

    test "paginates the verifications", %{conn: conn, actor: actor, client: client} do
      now = DateTime.utc_now()

      for days_ago <- 1..3 do
        device_verification_fixture(client,
          verified_at: DateTime.add(now, -days_ago, :day),
          revoked_at: DateTime.add(now, -days_ago + 1, :day)
        )
      end

      conn = authorize_conn(conn, actor)

      assert %{"data" => [_, _], "metadata" => %{"next_page" => next_page}} =
               conn |> get(~p"/clients/#{client}/verifications", limit: 2) |> json_response(200)

      assert %{"data" => [_]} =
               conn
               |> get(~p"/clients/#{client}/verifications", limit: 2, page_cursor: next_page)
               |> json_response(200)
    end

    test "returns not found for a client of another account", %{conn: conn, actor: actor} do
      client = client_fixture()
      device_verification_fixture(client)

      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/clients/#{client}/verifications")

      assert %{"status" => 404, "title" => "Not Found"} = json_response(conn, 404)
    end

    test "returns not found for a gateway", %{conn: conn, account: account, actor: actor} do
      gateway = gateway_fixture(account: account, site: site_fixture(account: account))

      conn =
        conn
        |> authorize_conn(actor)
        |> get(~p"/clients/#{gateway.id}/verifications")

      assert %{"status" => 404} = json_response(conn, 404)
    end
  end
end
