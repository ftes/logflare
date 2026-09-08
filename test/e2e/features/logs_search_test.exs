defmodule E2e.Features.LogsSearchTest do
  use Logflare.CerberusFeatureCase, async: false

  alias Cerberus.Playwright.Handle
  alias Logflare.Backends
  alias Logflare.SingleTenant
  alias PlaywrightEx.Frame

  setup do
    start_supervised!(Logflare.SystemMetrics.AllLogsLogged)

    :ok
  end

  describe "logs search" do
    TestUtils.setup_single_tenant(seed_user: true, backend_type: :postgres)

    setup do
      user = SingleTenant.get_default_user()
      source = insert(:source, user: user)

      matching_message = "featuresearchmatch#{System.unique_integer([:positive])}"
      non_matching_message = "featuresearchmiss#{System.unique_integer([:positive])}"

      bq_schema =
        TestUtils.build_bq_schema(%{
          "event_message" => matching_message,
          "metadata" => %{"response" => %{"status_code" => 200}}
        })

      insert(:source_schema, source: source, bigquery_schema: bq_schema)

      :ok = Backends.ensure_source_sup_started(source)

      {:ok, 2} =
        [
          build(:log_event,
            source: source,
            message: matching_message,
            metadata: %{"response" => %{"status_code" => 200}}
          ),
          build(:log_event,
            source: source,
            message: non_matching_message,
            metadata: %{"response" => %{"status_code" => 200}}
          )
        ]
        |> Backends.ingest_logs(source)

      %{
        source: source,
        user: user,
        matching_message: matching_message,
        non_matching_message: non_matching_message
      }
    end

    test "searches logs from the search page", %{
      source: source,
      matching_message: matching_message,
      non_matching_message: non_matching_message
    } do
      logs = by_css("#logs-list-container")

      start_logged_in_session()
      |> visit(
        ~p"/sources/#{source.id}/search?#{%{querystring: "event_message:#{matching_message}"}}"
      )
      |> expect(Expect.visible(by_text(logs, matching_message, [])))
      |> expect(Expect.count(by_text(logs, non_matching_message, []), 0))
    end

    test "loads the remaining previous page of search results", %{
      source: source,
      user: user
    } do
      pagination_message = "featuresearchpagination#{System.unique_integer([:positive])}"

      log_events =
        for index <- 1..105 do
          build(:log_event, source: source, message: "#{pagination_message}-#{index}")
        end

      assert {:ok, 105} = Backends.ingest_logs(log_events, source)
      assert :ok = TestUtils.wait_for_postgres_events(source, user, pagination_message, 105)

      start_logged_in_session()
      |> visit(
        ~p"/sources/#{source.id}/search?#{%{querystring: ~s|event_message:~\"^#{pagination_message}-\"|, tailing?: false}}"
      )
      |> expect(Expect.count(by_css("#logs-list li[data-event-id]"), 100))
      |> click(by_css("#load-more-events-top"))
      |> expect(Expect.count(by_css("#logs-list li[data-event-id]"), 105))
      |> expect(Expect.disabled(by_css("#load-more-events-top")))
    end

    test "shows a missing field error from the search page", %{source: source} do
      message = by_css(".message .alert p")

      start_logged_in_session()
      |> visit(~p"/sources/#{source.id}/search?#{%{querystring: "s:nonexistent"}}")
      |> expect(Expect.visible(by_text(message, "nonexistent", []), timeout: 10_000))
      |> expect(Expect.visible(by_text(message, "does not exist", [])))
    end

    test "cancelling the datepicker resumes tailing", %{source: source} do
      pause = by_text(by_css(".live-pause"), "Pause", [])

      start_logged_in_session()
      |> visit(~p"/sources/#{source.id}/search")
      |> expect(Expect.visible(pause))
      |> click(by_css("#daterangepicker"))
      |> expect(Expect.count(by_css(".daterangepicker"), 1, timeout: 10_000))
      |> click_date_range_cancel()
      |> expect(Expect.visible(pause))
    end

    test "applying a preset date range updates the search query", %{source: source} do
      session =
        start_logged_in_session()
        |> visit(~p"/sources/#{source.id}/search")
        |> click(by_text(by_css("span"), "DateTime", []))
        |> click_date_range_preset("Last 15 Minutes")
        |> expect(Expect.visible(by_text(by_css(".live-pause"), "Live", [])))

      querystring = wait_for_editor_querystring(session, "t:last@15")

      assert querystring =~ "t:last@15"
    end

    test "changing chart period updates the search query", %{source: source} do
      session =
        start_logged_in_session()
        |> visit(~p"/sources/#{source.id}/search")
        |> expect(Expect.visible(by_css("#source-logs-search-list")))

      wait_for_editor_querystring(session, "")

      session
      |> select_option(by_css("#search_chart_period"), %{label: "hour"})
      |> then(fn session ->
        querystring = wait_for_editor_querystring(session, "t::hour")
        assert querystring =~ "c:group_by(t::hour)"
        session
      end)
    end

    test "clicking a rendered chart bar narrows the search datetime", %{
      source: source,
      user: user,
      matching_message: matching_message
    } do
      bar_selector = ~s|.recharts-bar-rectangle [height]:not([height="0"])|
      chart_selector = ".recharts-wrapper"

      assert :ok = TestUtils.wait_for_postgres_events(source, user, matching_message, 1)

      session =
        start_logged_in_session()
        |> visit(~p"/sources/#{source.id}/search")
        |> expect(Expect.visible(bar_selector |> by_css() |> first(), timeout: 10_000))

      %{"x" => x, "y" => y} =
        Cerberus.Playwright.evaluate(
          session,
          """
          ({ barSelector, chartSelector }) => {
            const bar = document.querySelector(barSelector).getBoundingClientRect()
            const chart = document.querySelector(chartSelector).getBoundingClientRect()

            return {
              x: bar.left - chart.left + bar.width / 2,
              y: bar.top - chart.top + bar.height / 2
            }
          }
          """,
          is_function: true,
          arg: %{barSelector: bar_selector, chartSelector: chart_selector},
          timeout: 5_000
        )

      session =
        unwrap(session, fn %Handle{} = handle ->
          {:ok, _} =
            Frame.click(handle.frame_id,
              selector: chart_selector,
              position: %{x: x, y: y},
              connection: handle.connection,
              timeout: 5_000
            )
        end)

      session =
        expect(
          session,
          Expect.count(by_css(~s|#lql-editor-hook[data-querystring*=".."]|), 1, timeout: 10_000)
        )

      querystring =
        Cerberus.Playwright.evaluate(
          session,
          ~S|document.querySelector("#lql-editor-hook")?.dataset.querystring ?? ""|,
          timeout: 5_000
        )

      assert querystring =~ ~r/t:\S+\.\.\S+/
    end
  end

  defp start_logged_in_session do
    start_browser_session()
    |> visit(~p"/auth/login/single_tenant")
    |> expect(Cerberus.Page.to_have_url(~r|/dashboard\?t=\d+$|))
  end

  defp click_date_range_preset(session, preset) do
    trigger_click_event(session, ~s|.daterangepicker .ranges li[data-range-key="#{preset}"]|)
  end

  defp click_date_range_cancel(session) do
    trigger_click_event(session, ".daterangepicker .cancelBtn")
  end

  defp trigger_click_event(session, selector) do
    unwrap(session, fn %Handle{} = handle ->
      {:ok, _event} =
        Frame.dispatch_event(handle.frame_id,
          selector: selector,
          type: "click",
          event_init: %{bubbles: true, cancelable: true},
          connection: handle.connection,
          timeout: 5_000
        )
    end)
  end

  defp wait_for_editor_querystring(session, expected_fragment, timeout_ms \\ 10_000) do
    selector =
      if expected_fragment == "" do
        ~s|#lql-editor-hook[data-querystring]:not([data-querystring=""])|
      else
        ~s|#lql-editor-hook[data-querystring*="#{expected_fragment}"]|
      end

    session
    |> expect(Expect.count(by_css(selector), 1, timeout: timeout_ms))
    |> then(fn session ->
      Cerberus.Playwright.evaluate(
        session,
        ~S|document.querySelector("#lql-editor-hook")?.dataset.querystring ?? ""|,
        timeout: 5_000
      )
    end)
  end
end
