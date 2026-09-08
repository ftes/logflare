defmodule LogflareWeb.FluffyConnCase do
  use ExUnit.CaseTemplate

  using opts do
    quote do
      use LogflareWeb.ConnCase, unquote(opts)

      import Fluffy, except: [expect: 3]
      import Fluffy.Locator

      alias Fluffy.Expect

      setup context do
        Fluffy.Test.setup(context, repos: [Logflare.Repo])
      end

      defp start_app_session(conn) do
        start_session(:phoenix, conn: conn)
      end
    end
  end
end
