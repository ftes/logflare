defmodule LogflareWeb.SourceControllerTest do
  use LogflareWeb.FluffyConnCase

  alias Logflare.Backends
  alias Logflare.Backends.SourceSup
  alias Logflare.Repo
  alias Logflare.Sources
  alias Logflare.Sources.Counters
  alias Logflare.Sources.Source.SlackHookServer
  alias Logflare.Sources.Source.Supervisor, as: SourceSupervisor
  alias Logflare.Sources.Source.WebhookNotificationServer
  alias Logflare.SystemMetrics.AllLogsLogged
  alias Logflare.Teams
  alias Logflare.TestUtils
  alias Phoenix.HTML

  setup do
    start_supervised!(AllLogsLogged)
    :ok
  end

  describe "dashboard" do
    setup do
      insert(:plan, name: "Free")
      user = insert(:user)
      home_team = insert(:team, user: user)

      [invited_team1, invited_team2] = insert_pair(:team)
      team_user1 = insert(:team_user, email: user.email, team: invited_team1)
      team_user2 = insert(:team_user, email: user.email, team: invited_team2)

      {:ok,
       user: user,
       home_team: home_team,
       invited_team1: invited_team1,
       invited_team2: invited_team2,
       team_user1: team_user1,
       team_user2: team_user2}
    end

    test "navigating between teams results in correct query params being set", %{
      conn: conn,
      user: user,
      invited_team1: invited_team1
    } do
      html =
        conn
        |> login_user(user)
        |> get(~p"/dashboard?t=#{invited_team1.id}")
        |> html_response(200)
        |> Floki.parse_document!()

      assert html
             |> Floki.find("a[href*='?t=#{invited_team1.id}']")
             |> Enum.any?(&(Floki.text(&1) =~ "Dashboard"))
    end
  end

  describe "dashboard admin link in navbar" do
    setup do
      insert(:plan, name: "Free")
      user = insert(:user, admin: true)
      admin_team = insert(:team, user: user)

      # user1 has home team
      user1 = insert(:user)
      insert(:team, user: user1)
      team_user1 = insert(:team_user, email: user1.email, team: admin_team)

      # user2 has no home tema
      team_user2 = insert(:team_user, email: "some@email.com", team: admin_team)

      {:ok, user: user, admin_team: admin_team, team_user1: team_user1, team_user2: team_user2}
    end

    defp nav_and_assert_admin_link(conn, team_name, team_id) do
      conn
      |> start_app_session()
      |> visit(~p"/")
      |> then(fn session ->
        try do
          click(
            session,
            by_css(~s|a[href^="/teams/switch?team_id=#{team_id}"]|)
            |> filter(has_text: team_name)
          )
        rescue
          _ -> session
        end
      end)
      |> expect(
        Expect.visible(by_css("a[href*='t=#{team_id}']") |> filter(has_text: "Admin") |> first())
      )
    end

    test "viewing as invited team_user - no home team", %{
      conn: conn,
      user: user,
      team_user2: team_user,
      admin_team: admin_team
    } do
      conn
      |> login_user(user, team_user)
      |> nav_and_assert_admin_link(admin_team.name, admin_team.id)
    end

    @tag :feature
    test "viewing as invited team_user - with home team", %{
      conn: conn,
      team_user1: team_user,
      admin_team: admin_team
    } do
      conn
      |> start_browser_session(team_user.email)
      |> visit(~p"/dashboard")
      |> expect(Fluffy.Page.to_have_url(~r|/dashboard(?:\?.*)?$|, timeout: 5_000))
      |> click(by_css("#teamDropdown"))
      |> click(
        by_css(~s|a[href^="/teams/switch?team_id=#{admin_team.id}"]|)
        |> filter(has_text: admin_team.name)
      )
      |> expect(
        Expect.visible(
          by_css("a[href*='t=#{admin_team.id}']")
          |> filter(has_text: "Admin")
          |> first()
        )
      )
    end

    test "viewing as admin user", %{
      conn: conn,
      user: user,
      admin_team: admin_team
    } do
      conn |> login_user(user) |> nav_and_assert_admin_link(admin_team.name, admin_team.id)
    end

    defp start_browser_session(conn, current_email) do
      cookie_options = Plug.Session.COOKIE.init(signing_salt: "INPMyhPE")

      session_cookie =
        conn
        |> Map.put(:secret_key_base, LogflareWeb.Endpoint.config(:secret_key_base))
        |> Plug.Session.COOKIE.put(nil, %{"current_email" => current_email}, cookie_options)

      storage_state = %{
        cookies: [
          %{
            name: "_logflare_key",
            value: session_cookie,
            domain: "localhost",
            path: "/",
            expires: -1,
            http_only: true,
            secure: false,
            same_site: "Lax"
          }
        ],
        origins: []
      }

      start_session(:playwright,
        base_url: LogflareWeb.Endpoint.url(),
        browser_context: [storage_state: storage_state],
        timeout: :timer.seconds(40)
      )
    end
  end

  describe "list" do
    setup %{conn: conn} do
      user = insert(:user)
      insert(:plan, name: "Free")
      team = insert(:team, user: user)
      source = insert(:source, user: user)
      user = Repo.preload(user, :sources)
      [user: user, source: source, team: team, conn: login_user(conn, user)]
    end

    test "show source", %{conn: conn, source: source} do
      conn
      |> start_app_session()
      |> visit(~p"/sources/#{source}")
      |> expect(
        Expect.visible(
          by_text(by_css("h5 > a[href='#{~p"/sources/#{source}"}']"), source.name, [])
        )
      )
      |> expect(Expect.visible(by_text(by_css("li > a"), "Sign out", exact: true)))
      |> expect(Expect.visible(by_text(by_css("button > span"), "Search", exact: true)))
    end

    test "show source uses default search LQL as search input value", %{conn: conn, user: user} do
      source = insert(:source, user: user, default_search_lql: "level:error")

      html =
        conn
        |> get(~p"/sources/#{source}")
        |> html_response(200)

      assert html =~ ~s|id="source-search-querystring"|
      assert html =~ ~s|value="level:error "|
    end

    test "show source's recent logs", %{conn: conn, source: source} do
      start_supervised!({SourceSup, source})
      le = build(:log_event, level: "debug", source: source)
      Backends.ingest_logs([le], source)

      conn
      |> start_app_session()
      |> visit(~p"/sources/#{source}")
      |> expect(Expect.visible(by_text(by_css("li > a"), "event body", exact: true)))
      |> expect(Expect.visible(by_text(by_css("li mark.log-level-debug"), "debug", [])))
      |> expect(
        Expect.visible(
          by_text(
            by_css("pre > code"),
            Logflare.JSON.encode!(le.body["event_message"], pretty: true),
            []
          )
        )
      )
    end

    test "show source's recent logs when log is a plain map without :via_rule_id", %{
      conn: conn,
      source: source
    } do
      le = build(:log_event, source: source)

      plain_map_log =
        le
        |> Map.from_struct()
        |> Map.drop([:via_rule_id])

      Backends
      |> expect(:list_recent_logs, fn _source -> [plain_map_log] end)

      html =
        conn
        |> get(~p"/sources/#{source}")
        |> html_response(200)

      assert html =~ le.body["event_message"]
    end

    test "renders inputs for recommended query fields", %{
      conn: conn,
      user: user
    } do
      source =
        insert(:source,
          user: user,
          suggested_keys: "metadata.level!,m.user_id",
          bigquery_clustering_fields: "session_id"
        )

      conn
      |> start_app_session()
      |> visit(~p"/sources/#{source}")
      |> expect(Expect.visible(by_text(by_css("label"), "session_id", []) |> first()))
      |> expect(Expect.visible(by_text(by_css("label"), "metadata.level", []) |> first()))
      |> expect(Expect.visible(by_text(by_css("label"), "m.user_id", []) |> first()))
      |> expect(
        Expect.visible(by_text(by_css(".required-field-indicator"), "required", []) |> first())
      )
      |> expect(Expect.visible(by_css("input.form-control[id='recent-logs-field-session_id']")))
      |> expect(
        Expect.visible(by_css("input.form-control[id='recent-logs-field-metadata.level']"))
      )
      |> expect(Expect.visible(by_css("input.form-control[id='recent-logs-field-m.user_id']")))
    end

    test "shows source schema modal trigger and content", %{conn: conn, source: source} do
      insert(:source_schema,
        source: source,
        bigquery_schema: TestUtils.build_bq_schema(%{"metadata" => %{"status" => 200}})
      )

      conn
      |> start_app_session()
      |> visit(~p"/sources/#{source}")
      |> expect(
        Expect.visible(by_text(by_css("a[data-target='#sourceSchemaModal']"), "schema", []))
      )
      |> expect(Expect.count(by_css("div#sourceSchemaModal"), 1))
      |> expect(Expect.visible(by_text(by_css("h5"), "Source Schema", []) |> first()))
      |> expect(
        Expect.visible(
          by_text(
            by_css("#source-schema-modal-table button[title='Copy markdown to clipboard']"),
            "Copy markdown",
            []
          )
        )
      )
      |> expect(Expect.visible(by_text(by_css("kbd"), "metadata.status", [])))
    end

    test "invalid source", %{conn: conn, source: source} do
      html =
        conn
        |> get(~p"/sources/12345")
        |> html_response(404)

      # main nav
      assert html =~ "Sign out"
      refute html =~ "Sign in"
      # subnav
      refute html =~ source.name
      refute html =~ "scroll down"
      refute html =~ "Search"
    end

    test "forbidden source", %{conn: conn} do
      other_source = insert(:source, user: build(:user))

      html =
        conn
        |> get(~p"/sources/#{other_source}")
        |> html_response(404)

      # main nav
      assert html =~ "Sign out"
      refute html =~ "Sign in"
      # error content
      assert html =~ "404"
      assert html =~ "not found"
    end
  end

  describe "Premium only features" do
    setup %{conn: conn} do
      insert(:plan, name: "Free")
      paid_user = insert(:user, billing_enabled: true)
      plan = insert(:plan, name: "Paid", stripe_id: "stripe-id")
      insert(:billing_account, user: paid_user, stripe_plan_id: plan.stripe_id)
      insert(:team, user: paid_user)

      free_user = insert(:user)
      insert(:team, user: free_user)

      [conn: conn, paid_user: paid_user, free_user: free_user]
    end

    test "can see SMS alert options", %{conn: conn, paid_user: paid_user} do
      source = insert(:source, user: paid_user)

      conn
      |> login_user(paid_user)
      |> start_app_session()
      |> visit(~p"/sources/#{source}/edit")
      |> expect(Expect.visible(by_text(by_css("button"), "Update SMS preferences", exact: true)))
      |> expect(
        Expect.count(
          by_text(by_css("p"), "SMS alerts are not available with the Free plan.", []),
          0
        )
      )
    end

    test "free user", %{conn: conn, free_user: free_user} do
      source = insert(:source, user: free_user)

      conn
      |> login_user(free_user)
      |> start_app_session()
      |> visit(~p"/sources/#{source}/edit")
      |> expect(Expect.count(by_text(by_css("button"), "Update SMS preferences", exact: true), 0))
      |> expect(
        Expect.visible(
          by_text(by_css("p"), "SMS alerts are not available with the Free plan.", [])
        )
      )
    end
  end

  describe "edit" do
    setup %{conn: conn} do
      insert(:plan, name: "Free")
      free_user = insert(:user)
      insert(:team, user: free_user)

      [conn: conn, free_user: free_user]
    end

    test "pipeline", %{conn: conn, free_user: user} do
      source = insert(:source, user: user)

      conn
      |> login_user(user)
      |> start_app_session()
      |> visit(~p"/sources/#{source}/edit")
      |> expect(Expect.visible(by_text(by_css("h3"), "Pipeline Rules", exact: true)))
      |> expect(Expect.visible(by_text(by_css("h5"), "Copy fields", []) |> first()))
      |> expect(
        Expect.visible(by_text(by_css("button"), "Update field copying rules", exact: true))
      )

      conn =
        conn
        |> login_user(user)
        |> patch(~p"/sources/#{source}", %{
          source: %{
            transform_copy_fields: """
            test:123
            123:1234
            """
          }
        })

      assert html_response(conn, 302) =~ "redirected"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Source updated!"

      assert Sources.get_by(id: source.id).transform_copy_fields
    end
  end

  describe "show" do
    setup [:create_plan, :old_setup]

    test "returns 404 for a source not owned by the user", %{
      conn: conn,
      users: [_u1, u2 | _],
      sources: [s1 | _]
    } do
      conn =
        conn
        |> login_user(u2)
        |> get(~p"/sources/#{s1}")

      assert html_response(conn, 404) =~ "not found"
    end
  end

  describe "new" do
    setup [:create_plan]

    setup do
      user = insert(:user)

      team = insert(:team, user: user)
      [user: user, team: team]
    end

    test "logged user can create a new source", %{conn: conn, user: user} do
      plan = Repo.get_by!(Logflare.Billing.Plan, name: "Free")

      plan
      |> Ecto.Changeset.change(limit_source_ttl: :timer.hours(24) * 3)
      |> Repo.update!()

      conn
      |> login_user(user)
      |> start_app_session()
      |> visit(~p"/dashboard")
      |> click(by_role(:link, name: "New source"))
      |> expect(Fluffy.Page.to_have_url(~r|/sources/new(?:\?.*)?$|))
      |> expect(Expect.visible(by_text(by_css("h5"), "~/logs/new", [])))
      |> expect(Expect.visible(by_css("form")))
      |> expect(Expect.visible(by_css("input[name='source[retention_days]'][placeholder='3']")))
      |> fill(by_label("Source Name", exact: true), "MyApp.Logs")
      |> fill(by_label("Backend TTL", exact: true), "2")
      |> submit(by_css("form"))
      |> expect(Fluffy.Page.to_have_url(~r|/sources/[^/?]+\?[^#]*new=true[^#]*$|))

      assert %{bigquery_table_ttl: 2} = Sources.get_by(name: "MyApp.Logs")
    end

    test "shows an error when the retention exceeds the plan limit", %{
      conn: conn,
      user: user
    } do
      conn
      |> login_user(user)
      |> start_app_session()
      |> visit(~p"/sources/new")
      |> fill(by_label("Source Name", exact: true), "MyApp.OverLimit")
      |> fill(by_label("Backend TTL", exact: true), "4")
      |> submit(by_css("form"))
      |> expect(Fluffy.Page.to_have_url(~r|/sources(?:\?.*)?$|))
      |> expect(Expect.visible(by_text(by_css(".help-block"), "ttl is over your plan limit", [])))

      refute Sources.get_by(name: "MyApp.OverLimit")
    end

    test "team user can create a new source", %{conn: conn, user: user} do
      team = insert(:team, name: "Team1")
      team_user = insert(:team_user, email: user.email, team: team)

      conn
      |> login_user(team.user, team_user)
      |> start_app_session()
      |> visit(~p"/dashboard?t=#{team.id}")
      |> click(by_role(:link, name: "New source"))
      |> expect(Fluffy.Page.to_have_url(~r|/sources/new\?[^#]*t=#{team.id}[^#]*$|))
      |> expect(Expect.visible(by_text(by_css("h5"), "~/logs/new", [])))
      |> expect(Expect.visible(by_css("form")))
      |> fill(by_label("Source Name", exact: true), "MyApp.Logs")
      |> submit(by_css("form"))
      |> expect(Fluffy.Page.to_have_url(~r|/sources/[^/?]+\?[^#]*new=true[^#]*$|))
      |> expect(Expect.visible(by_css("a[href='#{~p"/dashboard?t=#{team.id}"}']")))
    end

    test "returns 403 for a user not logged in", %{conn: conn} do
      conn
      |> start_app_session()
      |> visit(~p"/sources/new")
      |> expect(Fluffy.Page.to_have_url(~p"/auth/login"))
    end
  end

  describe "update" do
    setup [:create_plan, :old_setup]

    test "source details form includes current description value", %{
      conn: conn,
      users: [u1, _u2],
      sources: [s1, _s2 | _]
    } do
      description = "Current source description"
      source = Repo.update!(Ecto.Changeset.change(s1, description: description))

      html =
        conn
        |> login_user(u1)
        |> get(~p"/sources/#{source}/edit")
        |> html_response(200)
        |> Floki.parse_document!()

      assert [_textarea] = Floki.find(html, "textarea[name='source[description]']")

      assert html
             |> Floki.find("textarea[name='source[description]']")
             |> Floki.text()
             |> String.trim() == description
    end

    test "returns 200 with valid params", %{conn: conn, users: [u1, _u2], sources: [s1, _s2 | _]} do
      new_name = TestUtils.random_string()
      new_description = TestUtils.random_string()

      params = %{
        "id" => s1.id,
        "source" => %{
          "favorite" => true,
          "name" => new_name,
          "description" => new_description
        }
      }

      conn =
        conn
        |> login_user(u1)
        |> patch(~p"/sources/#{s1}", params)

      s1_new = Sources.get_by(token: s1.token)

      assert html_response(conn, 302) =~ "redirected"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Source updated!"
      assert s1_new.name == new_name
      assert s1_new.description == new_description
      assert s1_new.favorite == true

      conn =
        conn
        |> recycle()
        |> login_user(u1)
        |> get(~p"/sources/#{s1}")

      assert conn.assigns.source.name == new_name
      assert conn.assigns.source.description == new_description
    end

    test "able to update labels", %{conn: conn, users: [u1, _u2], sources: [s1, _s2 | _]} do
      params = %{
        "id" => s1.id,
        "source" => %{
          "labels" => "test=some_label"
        }
      }

      conn =
        conn
        |> login_user(u1)
        |> patch(~p"/sources/#{s1}", params)

      s1_new = Sources.get_by(token: s1.token)

      assert html_response(conn, 302) =~ "redirected"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Source updated!"
      assert s1_new.labels == "test=some_label"
    end

    test "returns 406 with invalid params", %{
      conn: conn,
      users: [u1, _u2],
      sources: [s1, _s2 | _]
    } do
      new_name = "this should never be inserted"

      params = %{
        "id" => s1.id,
        "source" => %{
          "favorite" => 123,
          "name" => new_name
        }
      }

      conn =
        conn
        |> login_user(u1)
        |> patch(~p"/sources/#{s1}", params)

      s1_new = Sources.get_by(token: s1.token)

      assert s1_new.name != new_name
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Something went wrong!"
      assert html_response(conn, 406) =~ "Source Name"
    end

    test "shows the plan limit error when retention days exceeds the plan", %{
      conn: conn,
      users: [u1, _u2],
      sources: [s1, _s2 | _]
    } do
      conn =
        conn
        |> login_user(u1)
        |> patch(~p"/sources/#{s1}", %{
          "source" => %{"retention_days" => "7"}
        })

      assert html_response(conn, 406) =~ "ttl is over your plan limit"
      assert Sources.get(s1.id).retention_days == 3
    end

    test "updates description when valid", %{
      conn: conn,
      users: [u1, _u2],
      sources: [s1, _s2 | _]
    } do
      new_description = "  valid description  "

      conn =
        conn
        |> login_user(u1)
        |> patch(~p"/sources/#{s1}", %{
          "id" => s1.id,
          "source" => %{
            "description" => new_description
          }
        })

      s1_new = Sources.get_by(id: s1.id)

      assert html_response(conn, 302) =~ "redirected"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Source updated!"
      assert s1_new.description == "valid description"
    end

    test "returns 200 but doesn't change restricted params", %{
      conn: conn,
      users: [u1, _u2],
      sources: [s1, _s2 | _]
    } do
      nope_token = TestUtils.gen_uuid()
      nope_api_quota = 1337
      nope_user_id = 1

      params = %{
        "id" => s1.id,
        "source" => %{
          "name" => s1.name,
          "token" => nope_token,
          "api_quota" => nope_api_quota,
          "user_id" => nope_user_id
        }
      }

      conn =
        conn
        |> login_user(u1)
        |> patch(~p"/sources/#{s1}", params)

      s1_new = Sources.get_by(id: s1.id)

      refute conn.assigns[:changeset]
      refute s1_new.token == nope_token
      refute s1_new.api_quota == nope_api_quota
      refute s1_new.user_id == nope_user_id
      assert redirected_to(conn, 302) =~ source_path(conn, :edit, s1.id)
    end

    test "returns 404 when user is not an owner of source", %{
      conn: conn,
      users: [u1, _u2],
      sources: [s1, _s2, u2s1 | _]
    } do
      conn =
        conn
        |> login_user(u1)
        |> patch(
          ~p"/sources/#{u2s1}",
          %{
            "source" => %{
              "name" => "it's mine now!"
            }
          }
        )

      s1_new = Sources.get_by(id: s1.id)

      refute s1_new.name === "it's mine now!"
      assert conn.halted === true
      assert html_response(conn, 404) =~ "not found"
    end
  end

  describe "create" do
    setup [:create_plan, :old_setup]

    test "returns 200 with valid params", %{conn: conn, users: [u1 | _]} do
      name = TestUtils.random_string()

      conn =
        conn
        |> login_user(u1)
        |> post(~p"/sources", %{
          "source" => %{
            "name" => name
          }
        })

      source = Sources.get_by(name: name)

      refute conn.assigns[:changeset]
      assert redirected_to(conn, 302) === source_path(conn, :show, source.id) <> "?new=true"
    end

    test "renders error flash and redirects for missing name", %{conn: conn, users: [u1 | _]} do
      conn =
        conn
        |> login_user(u1)
        |> post(~p"/sources", %{
          "source" => %{
            "name" => ""
          }
        })

      assert conn.assigns[:changeset].errors === [
               name: {"can't be blank", [validation: :required]}
             ]

      assert Phoenix.Flash.get(conn.assigns.flash, :error) === "Something went wrong!"
    end

    test "renders error flash for source with empty name", %{conn: conn, users: [u1 | _]} do
      conn =
        conn
        |> login_user(u1)
        |> post(~p"/sources", %{
          "source" => %{
            "name" => ""
          }
        })

      assert conn.assigns[:changeset].errors === [
               name: {"can't be blank", [validation: :required]}
             ]

      assert Phoenix.Flash.get(conn.assigns.flash, :error) === "Something went wrong!"
    end
  end

  describe "public" do
    setup [:create_plan, :old_setup]

    test "shows a source page", %{conn: conn, sources: [s1 | _]} do
      conn
      |> start_app_session()
      |> visit(~p"/sources/public/#{s1.public_token}")
      |> expect(Expect.visible(by_text(by_css("h5 > a"), s1.name, [])))
      |> expect(Expect.visible(by_text(by_css("span#source-id"), to_string(s1.token), [])))
    end
  end

  describe "delete" do
    setup [:create_plan, :old_setup]

    test "deletes a source", %{conn: conn, sources: [s1 | _], users: [u1 | _]} do
      conn
      |> login_user(u1)
      |> start_app_session()
      |> visit(~p"/dashboard")
      |> expect(
        Expect.visible(
          by_css("a[href^='#{~p"/sources/#{s1}"}']")
          |> filter(has_text: s1.name)
          |> first()
        )
      )

      assert conn
             |> login_user(u1)
             |> delete(~p"/sources/#{s1}/force-delete")
             |> redirected_to(302) =~ "/dashboard"

      refute Sources.get(s1.id)

      conn
      |> login_user(u1)
      |> start_app_session()
      |> visit(~p"/dashboard")
      |> expect(
        Expect.count(
          by_css("a[href^='#{~p"/sources/#{s1}"}']") |> filter(has_text: s1.name),
          0
        )
      )
    end
  end

  describe "update pipeline" do
    setup :create_plan

    setup do
      Logflare.Google.BigQuery
      |> stub(:init_table!, fn _, _, _, _, _, _ -> :ok end)

      on_exit(fn ->
        for {_id, child, _, _} <- DynamicSupervisor.which_children(Backends.SourcesSup) do
          DynamicSupervisor.terminate_child(Backends.SourcesSup, child)
        end
      end)

      [user: insert(:user)]
    end
  end

  describe "team context links" do
    setup %{conn: conn} do
      user = insert(:user)
      insert(:plan, name: "Free")
      team = insert(:team, user: user)
      team_user = insert(:team_user, team: team, email: user.email)
      source = insert(:source, user: user)

      [
        conn: login_user(conn, user, team_user),
        user: user,
        team: team,
        team_user: team_user,
        source: source
      ]
    end

    test "source show page links include team query param", %{
      conn: conn,
      source: source,
      team_user: team_user
    } do
      html =
        conn
        |> get(~p"/sources/#{source}?t=#{team_user.team_id}")
        |> html_response(200)

      for path <- ~w(explore rules clear edit) do
        assert html =~
                 ~r/href="[^"]*\/sources\/#{source.id}\/#{path}[^"]*[?&]t=#{team_user.team_id}/
      end
    end

    test "source search form includes team query param", %{
      conn: conn,
      source: source,
      team_user: team_user
    } do
      html =
        conn
        |> get(~p"/sources/#{source}?t=#{team_user.team_id}")
        |> html_response(200)

      # Check search form has hidden input with team param
      assert html =~ ~r/<input[^>]*name="t"/
    end

    test "source edit page has Rules link with team query param", %{
      conn: conn,
      source: source,
      team_user: team_user
    } do
      html =
        conn
        |> get(~p"/sources/#{source}/edit?t=#{team_user.team_id}")
        |> html_response(200)

      assert html =~ ~r/sources\/#{source.id}\/rules/ or html =~ ~r/RulesLive/
      assert html =~ "?t=#{team_user.team_id}" or html =~ "&amp;t=#{team_user.team_id}"
    end
  end

  describe "test_alerts" do
    setup [:create_plan]

    setup %{conn: conn} do
      user = insert(:user)
      insert(:team, user: user)
      source = insert(:source, user: user, webhook_notification_url: "https://example.com/hook")

      [conn: login_user(conn, user), user: user, source: source]
    end

    test "success", %{conn: conn, source: source} do
      expect(WebhookNotificationServer, :test_post, fn %{id: id} ->
        assert id == source.id
        {:ok, %Tesla.Env{status: 200}}
      end)

      conn = get(conn, ~p"/sources/#{source}/test-alerts")

      assert redirected_to(conn, 302) =~ ~p"/sources/#{source}/edit"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Webhook test successful!"
    end

    test "error with Tesla.Env response", %{conn: conn, source: source} do
      expect(WebhookNotificationServer, :test_post, fn _ -> {:error, %Tesla.Env{status: 500}} end)

      conn = get(conn, ~p"/sources/#{source}/test-alerts")

      assert redirected_to(conn, 302) =~ ~p"/sources/#{source}/edit"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "status code was 500"
    end

    test "error with non-Tesla response", %{conn: conn, source: source} do
      expect(WebhookNotificationServer, :test_post, fn _ -> {:error, "connection refused"} end)

      conn = get(conn, ~p"/sources/#{source}/test-alerts")

      assert redirected_to(conn, 302) =~ ~p"/sources/#{source}/edit"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "connection refused"
    end
  end

  describe "test_slack_hook" do
    setup [:create_plan]

    setup %{conn: conn} do
      user = insert(:user)
      insert(:team, user: user)
      source = insert(:source, user: user, slack_hook_url: "https://hooks.slack.com/test")

      [conn: login_user(conn, user), user: user, source: source]
    end

    test "success", %{conn: conn, source: source} do
      expect(SlackHookServer, :test_post, fn %{id: id} ->
        assert id == source.id
        {:ok, %Tesla.Env{status: 200}}
      end)

      conn = get(conn, ~p"/sources/#{source}/test-slack-hook")

      assert redirected_to(conn, 302) =~ ~p"/sources/#{source}/edit"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Slack hook test successful!"
    end

    test "error with Tesla.Env response", %{conn: conn, source: source} do
      expect(SlackHookServer, :test_post, fn _ -> {:error, %Tesla.Env{status: 403}} end)

      conn = get(conn, ~p"/sources/#{source}/test-slack-hook")

      assert redirected_to(conn, 302) =~ ~p"/sources/#{source}/edit"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "status code was 403"
    end
  end

  describe "delete_slack_hook" do
    setup [:create_plan]

    setup %{conn: conn} do
      user = insert(:user)
      insert(:team, user: user)
      source = insert(:source, user: user, slack_hook_url: "https://hooks.slack.com/test")

      [conn: login_user(conn, user), user: user, source: source]
    end

    test "success", %{conn: conn, source: source} do
      conn = get(conn, ~p"/sources/#{source}/delete-slack-hook")

      assert redirected_to(conn, 302) =~ ~p"/sources/#{source}/edit"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Slack hook deleted!"

      updated = Sources.get_by(id: source.id)
      assert updated.slack_hook_url == nil
    end

    test "does not delete a victim's slack hook when source_id query param points to an attacker-owned source",
         %{conn: conn, source: attacker_source} do
      victim = insert(:user)
      insert(:team, user: victim)

      victim_source =
        insert(:source, user: victim, slack_hook_url: "https://hooks.slack.com/victim")

      conn =
        get(
          conn,
          ~p"/sources/#{attacker_source}/delete-slack-hook?source_id=#{victim_source.id}"
        )

      assert redirected_to(conn, 302) =~ ~p"/sources/#{attacker_source}/edit"

      assert Sources.get_by(id: victim_source.id).slack_hook_url ==
               "https://hooks.slack.com/victim"
    end
  end

  describe "delete with recent events check" do
    setup [:create_plan]

    setup %{conn: conn} do
      user = insert(:user)
      insert(:team, user: user)
      source = insert(:source, user: user)

      [conn: login_user(conn, user), user: user, source: source]
    end

    test "redirects with error when events are less than 24h old", %{conn: conn, source: source} do
      recent_timestamp = DateTime.utc_now() |> DateTime.to_unix(:microsecond)
      Counters.create(source.token)
      Counters.increment_source_changed_at_unix_ts(source.token, recent_timestamp)

      conn = delete(conn, ~p"/sources/#{source}")

      assert redirected_to(conn, 302) =~ "/dashboard"
      flash = Phoenix.Flash.get(conn.assigns.flash, :error)
      assert is_list(flash)
      assert Enum.any?(flash, &(is_binary(&1) and &1 =~ "less than 24 hours"))
    end

    test "deletes source when events are older than 24h", %{conn: conn, source: source} do
      Counters.create(source.token)
      expect(SourceSupervisor, :delete_source, fn _ -> {:ok, source.token} end)

      conn = delete(conn, ~p"/sources/#{source}")

      assert redirected_to(conn, 302) =~ "/dashboard"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Source deleted!"
      refute Sources.get(source.id)
    end
  end

  describe "clear_logs" do
    setup [:create_plan]

    setup %{conn: conn} do
      user = insert(:user)
      insert(:team, user: user)
      source = insert(:source, user: user)

      [conn: login_user(conn, user), user: user, source: source]
    end

    test "clears logs and redirects", %{conn: conn, source: source} do
      expect(SourceSupervisor, :reset_source, fn _ -> {:ok, source.token} end)

      conn = get(conn, ~p"/sources/#{source}/clear")

      assert redirected_to(conn, 302) =~ ~p"/sources/#{source}"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Logs cleared!"
    end
  end

  describe "rejected_logs" do
    setup [:create_plan]

    setup %{conn: conn} do
      user = insert(:user)
      insert(:team, user: user)
      source = insert(:source, user: user)

      [conn: login_user(conn, user), user: user, source: source]
    end

    test "renders rejected logs page", %{conn: conn, source: source} do
      conn = get(conn, ~p"/sources/#{source}/rejected")

      html = html_response(conn, 200)
      assert html =~ source.name
      assert html =~ "clear cache"
    end
  end

  describe "explore" do
    setup [:create_plan]

    setup %{conn: conn} do
      user = insert(:user, provider: "email")
      insert(:team, user: user)
      source = insert(:source, user: user)

      [conn: login_user(conn, user), user: user, source: source]
    end

    test "free plan user gets upgrade message", %{conn: conn, source: source} do
      conn = get(conn, ~p"/sources/#{source}/explore")

      assert redirected_to(conn, 302) =~ ~p"/sources/#{source}"
      flash = Phoenix.Flash.get(conn.assigns.flash, :error)
      assert is_list(flash)
      flash_text = flash |> HTML.Safe.to_iodata() |> IO.iodata_to_binary()
      assert flash_text =~ "upgrade to explore"
    end

    test "non-google provider user gets sign-in message", %{conn: conn, user: user} do
      plan = insert(:plan, name: "Paid", stripe_id: "stripe-paid")
      insert(:billing_account, user: user, stripe_plan_id: plan.stripe_id)
      source = insert(:source, user: user)

      conn = get(conn, ~p"/sources/#{source}/explore")

      assert redirected_to(conn, 302) =~ ~p"/sources/#{source}"
      flash = Phoenix.Flash.get(conn.assigns.flash, :error)
      assert is_list(flash)
      flash_text = flash |> HTML.Safe.to_iodata() |> IO.iodata_to_binary()
      assert flash_text =~ "Sign in with Google"
    end
  end

  describe "update with notifications_every" do
    setup [:create_plan]

    setup %{conn: conn} do
      user = insert(:user)
      insert(:team, user: user)
      source = insert(:source, user: user)

      [conn: login_user(conn, user), user: user, source: source]
    end

    test "updates notification frequency", %{conn: conn, source: source} do
      conn =
        patch(conn, ~p"/sources/#{source}", %{"source" => %{"notifications_every" => "3600000"}})

      assert redirected_to(conn, 302) =~ ~p"/sources/#{source}/edit"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Source updated!"
    end

    test "returns upgrade error when frequency exceeds plan limit", %{conn: conn, source: source} do
      conn =
        patch(conn, ~p"/sources/#{source}", %{"source" => %{"notifications_every" => "1000"}})

      assert redirected_to(conn, 302) =~ ~p"/sources/#{source}/edit"
      flash = Phoenix.Flash.get(conn.assigns.flash, :error)
      assert is_list(flash)
      flash_text = flash |> HTML.Safe.to_iodata() |> IO.iodata_to_binary()
      assert flash_text =~ "upgrade"
    end
  end

  describe "update with drop_lql_string" do
    setup [:create_plan]

    setup %{conn: conn} do
      user = insert(:user)
      insert(:team, user: user)
      source = insert(:source, user: user)
      insert(:source_schema, source: source)

      [conn: login_user(conn, user), user: user, source: source]
    end

    test "updates drop LQL filters successfully", %{conn: conn, source: source} do
      conn =
        patch(conn, ~p"/sources/#{source}", %{
          "source" => %{"drop_lql_string" => "event_message:~\"test\""}
        })

      assert redirected_to(conn, 302) =~ ~p"/sources/#{source}/edit"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Source updated!"
    end

    test "shows error for unknown field in LQL", %{conn: conn, source: source} do
      conn =
        patch(conn, ~p"/sources/#{source}", %{
          "source" => %{"drop_lql_string" => "nonexistent_field:value"}
        })

      assert redirected_to(conn, 302) =~ ~p"/sources/#{source}/edit"
      assert Phoenix.Flash.get(conn.assigns.flash, :error)
    end
  end

  describe "default_search_lql" do
    setup [:create_plan]

    setup %{conn: conn} do
      user = insert(:user)
      insert(:team, user: user)
      source = insert(:source, user: user)
      insert(:source_schema, source: source)

      [conn: login_user(conn, user), user: user, source: source]
    end

    test "updates default search LQL successfully", %{conn: conn, source: source} do
      conn =
        patch(conn, ~p"/sources/#{source}", %{
          "source" => %{"default_search_lql" => "s:m.level"}
        })

      assert redirected_to(conn, 302) =~ ~p"/sources/#{source}/edit"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Source updated!"
      assert Repo.reload(source).default_search_lql == "s:m.level"
    end

    test "shows error for unknown field in default search LQL", %{conn: conn, source: source} do
      conn =
        patch(conn, ~p"/sources/#{source}", %{
          "source" => %{"default_search_lql" => "nonexistent_field:value"}
        })

      assert redirected_to(conn, 302) =~ ~p"/sources/#{source}/edit"

      [flash | _] = Phoenix.Flash.get(conn.assigns.flash, :error)

      assert flash =~ "LQL parser error: path `nonexistent_field`"
    end
  end

  describe "create with session params" do
    setup [:create_plan]

    setup %{conn: conn} do
      user = insert(:user)
      insert(:team, user: user)

      [conn: login_user(conn, user), user: user]
    end

    test "redirects for oauth when oauth_params in session", %{conn: conn, user: _user} do
      conn =
        conn
        |> Plug.Conn.put_session(:oauth_params, %{some: "params"})
        |> post(~p"/sources", %{"source" => %{"name" => "OAuth Source"}})

      assert redirected_to(conn, 302)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Source created!"
      assert Sources.get_by(name: "OAuth Source")
    end
  end

  defp create_plan(_) do
    insert(:plan, name: "Free")

    :ok
  end

  defp old_setup(_) do
    u1 = insert(:user)
    u2 = insert(:user)
    Teams.create_team(u1, %{name: "u1 team"})
    Teams.create_team(u2, %{name: "u2 team"})

    s1 = insert(:source, public_token: TestUtils.random_string(), user_id: u1.id)
    s2 = insert(:source, user_id: u1.id)
    s3 = insert(:source, user_id: u2.id)

    users = [u1, u2]
    sources = [s1, s2, s3]

    {:ok, users: users, sources: sources}
  end
end
