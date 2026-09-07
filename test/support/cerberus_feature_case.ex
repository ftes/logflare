defmodule Logflare.CerberusFeatureCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      use Mimic
      use LogflareWeb, :routes

      import Cerberus
      import Cerberus.Locator
      import Logflare.Factory

      alias Cerberus.Expect
      alias Logflare.Backends.IngestEventQueue
      alias Logflare.PubSubRates
      alias Logflare.TestUtils

      require Logflare.TestUtils

      @moduletag :feature

      setup context do
        Mimic.verify_on_exit!(context)

        on_exit(fn ->
          IngestEventQueue.delete_all_mappings()
          PubSubRates.Cache.clear()
        end)

        :ok
      end

      def start_browser_session(options \\ []) do
        defaults = [base_url: LogflareWeb.Endpoint.url(), timeout: :timer.seconds(40)]
        Cerberus.start_session(:playwright, Keyword.merge(defaults, options))
      end
    end
  end

  setup context do
    Logflare.DataCase.setup_sandbox(context)
    Logflare.DataCase.setup_mocking(context)

    Cerberus.Test.setup(context, repos: [Logflare.Repo], timeout: :timer.seconds(40))
  end
end
