defmodule E2e.Features.BackendsTest do
  use Logflare.CerberusFeatureCase, async: false

  alias Cerberus.Playwright.Handle
  alias Logflare.SingleTenant
  alias PlaywrightEx.Frame

  setup do
    start_supervised!(Logflare.SystemMetricsSup)

    :ok
  end

  describe "clickhouse backend form" do
    TestUtils.setup_single_tenant(seed_user: true)

    setup do
      backend =
        insert(:backend,
          user: SingleTenant.get_default_user(),
          type: :clickhouse,
          config: %{
            url: "https://ingest.example.com:8443",
            username: "default",
            password: "secret",
            database: "default",
            port: 8443,
            read_only_url: "https://reads.example.com:8443",
            read_only_urls: %{"reporting" => "https://reporting.example.com:8443"},
            default_read_cluster: "reporting"
          }
        )

      %{backend: backend}
    end

    test "edit renders the read cluster editor with existing clusters", %{
      backend: backend
    } do
      backend
      |> visit_backend_edit()
      |> expect(Expect.visible(by_text(by_css("label"), "Read-Only Cluster URLs (Optional)", [])))
      |> expect(Expect.visible(by_role(:button, name: "Add read cluster")))
      |> expect(Expect.visible(by_css("#read-cluster-row-0 input[value='reporting']")))
      |> expect(
        Expect.visible(
          by_css("#read-cluster-row-0 input[value='https://reporting.example.com:8443']")
        )
      )
      |> expect(
        Expect.visible(
          by_css("input[name='backend[config][default_read_cluster]'][value='reporting']")
        )
      )
    end

    test "edit can add and remove read cluster rows", %{backend: backend} do
      backend
      |> visit_backend_edit()
      |> expect(Expect.count(by_css("#read-cluster-row-1"), 0))
      |> click(by_role(:button, name: "Add read cluster"))
      |> expect(Expect.visible(by_css("#read-cluster-row-1")))
      |> click(by_css("#read-cluster-row-1 button[phx-click='remove_row']"))
      |> expect(Expect.count(by_css("#read-cluster-row-1"), 0))
      |> expect(Expect.visible(by_css("#read-cluster-row-0 input[value='reporting']")))
    end

    test "adding a row preserves unsaved cluster and default edits", %{backend: backend} do
      label =
        by_css("#read-cluster-row-0 input[name='backend[config][read_cluster_label_0]']")

      url =
        by_css("#read-cluster-row-0 input[name='backend[config][read_cluster_url_0]']")

      default_cluster = by_css("input[name='backend[config][default_read_cluster]']")

      backend
      |> visit_backend_edit()
      |> expect(Expect.visible(by_css("[data-phx-main].phx-connected")))
      |> fill(label, "reporting-edited")
      |> fill(url, "https://reporting-edited.example.com:8443")
      |> fill(default_cluster, "reporting-edited")
      |> click(by_role(:button, name: "Add read cluster"))
      |> expect(Expect.visible(by_css("#read-cluster-row-1")))
      |> expect(Expect.value(label, "reporting-edited"))
      |> expect(Expect.value(url, "https://reporting-edited.example.com:8443"))
      |> expect(Expect.value(default_cluster, "reporting-edited"))
      |> click(by_role(:button, name: "Save changes"))
      |> expect(Expect.visible(by_text("Successfully updated backend")))

      config = Logflare.Backends.get_backend(backend.id).config

      assert config.read_only_urls == %{
               "reporting-edited" => "https://reporting-edited.example.com:8443"
             }

      assert config.default_read_cluster == "reporting-edited"
    end

    test "typing into a read cluster field does not sync to the server until blurred", %{
      backend: backend
    } do
      url =
        by_css("#read-cluster-row-0 input[name='backend[config][read_cluster_url_0]']")

      session =
        backend
        |> visit_backend_edit()
        |> fill(url, "")

      true =
        Cerberus.Playwright.evaluate(
          session,
          """
          (() => {
            window.__sentFrames = [];
            const originalSend = WebSocket.prototype.send;
            WebSocket.prototype.send = function (data) {
              window.__sentFrames.push(data);
              return originalSend.apply(this, arguments);
            };
            return true;
          })()
          """,
          timeout: 5_000
        )

      session =
        unwrap(session, fn %Handle{} = handle ->
          {:ok, _} =
            Frame.type(handle.frame_id,
              selector: "#read-cluster-row-0 input[name='backend[config][read_cluster_url_0]']",
              text: "https://reader-b.example.com:8443",
              delay: 10,
              connection: handle.connection,
              timeout: 5_000
            )
        end)

      assert sent_sync_frame_count(session) == 0

      session = blur(session, url)

      session =
        unwrap(session, fn %Handle{} = handle ->
          {:ok, _} =
            Frame.wait_for_function(handle.frame_id,
              expression:
                "() => window.__sentFrames.some((f) => typeof f === 'string' && f.includes('\"sync\"'))",
              is_function: true,
              connection: handle.connection,
              timeout: 5_000
            )
        end)

      assert sent_sync_frame_count(session) == 1
      expect(session, Expect.value(url, "https://reader-b.example.com:8443"))
    end
  end

  describe "clickhouse read cluster row removal" do
    TestUtils.setup_single_tenant(seed_user: true)

    setup do
      backend =
        insert(:backend,
          user: SingleTenant.get_default_user(),
          type: :clickhouse,
          config: %{
            url: "https://ingest.example.com:8443",
            username: "default",
            password: "secret",
            database: "default",
            port: 8443,
            read_only_urls: %{
              "alpha" => "https://a.example.com:8443",
              "beta" => "https://b.example.com:8443",
              "gamma" => "https://c.example.com:8443"
            },
            default_read_cluster: "gamma"
          }
        )

      %{backend: backend}
    end

    test "removing a row removes that row, leaving the others addressable", %{
      backend: backend
    } do
      session = visit_backend_edit(backend)

      session
      |> expect(Expect.value(read_cluster_label(0), "alpha"))
      |> expect(Expect.value(read_cluster_label(1), "beta"))
      |> expect(Expect.value(read_cluster_label(2), "gamma"))

      session = click(session, by_css("#read-cluster-row-0 button[phx-click='remove_row']"))

      session
      |> expect(Expect.count(by_css("#read-cluster-row-0"), 0))
      |> expect(Expect.visible(by_css("#read-cluster-row-1 input[value='beta']")))
      |> expect(Expect.visible(by_css("#read-cluster-row-2 input[value='gamma']")))
      |> expect(Expect.value(read_cluster_label(1), "beta"))
      |> expect(Expect.value(read_cluster_label(2), "gamma"))
    end

    test "removing a row saves the remaining clusters", %{backend: backend} do
      backend
      |> visit_backend_edit()
      |> click(by_css("#read-cluster-row-0 button[phx-click='remove_row']"))
      |> click(by_role(:button, name: "Save changes"))
      |> expect(Expect.visible(by_text("Successfully updated backend")))

      assert Logflare.Backends.get_backend(backend.id).config.read_only_urls == %{
               "beta" => "https://b.example.com:8443",
               "gamma" => "https://c.example.com:8443"
             }
    end

    test "removing a row preserves unsaved edits in surviving rows and the default", %{
      backend: backend
    } do
      label =
        by_css("#read-cluster-row-2 input[name='backend[config][read_cluster_label_2]']")

      url =
        by_css("#read-cluster-row-2 input[name='backend[config][read_cluster_url_2]']")

      default_cluster = by_css("input[name='backend[config][default_read_cluster]']")

      backend
      |> visit_backend_edit()
      |> fill(label, "gamma-edited")
      |> fill(url, "https://gamma-edited.example.com:8443")
      |> fill(default_cluster, "gamma-edited")
      |> click(by_css("#read-cluster-row-0 button[phx-click='remove_row']"))
      |> expect(Expect.count(by_css("#read-cluster-row-0"), 0))
      |> expect(Expect.value(label, "gamma-edited"))
      |> expect(Expect.value(url, "https://gamma-edited.example.com:8443"))
      |> expect(Expect.value(default_cluster, "gamma-edited"))
      |> click(by_role(:button, name: "Save changes"))
      |> expect(Expect.visible(by_text("Successfully updated backend")))

      config = Logflare.Backends.get_backend(backend.id).config

      assert config.read_only_urls == %{
               "beta" => "https://b.example.com:8443",
               "gamma-edited" => "https://gamma-edited.example.com:8443"
             }

      assert config.default_read_cluster == "gamma-edited"
    end
  end

  defp visit_backend_edit(backend) do
    start_browser_session()
    |> visit(~p"/auth/login/single_tenant")
    |> expect(Expect.url(~r|/dashboard\?t=\d+$|))
    |> visit(~p"/backends/#{backend.id}/edit")
  end

  defp read_cluster_label(ref) do
    by_css("#read-cluster-row-#{ref} input[name='backend[config][read_cluster_label_#{ref}]']")
  end

  defp sent_sync_frame_count(session) do
    Cerberus.Playwright.evaluate(
      session,
      "window.__sentFrames.filter((f) => typeof f === 'string' && f.includes('\"sync\"')).length",
      timeout: 5_000
    )
  end
end
