defmodule LogflareWeb.FluffyConnCase do
  use ExUnit.CaseTemplate

  using opts do
    quote do
      use LogflareWeb.ConnCase, unquote(opts)

      use Fluffy.Assert

      import Fluffy
      import Fluffy.Locator

      setup context do
        Fluffy.Test.setup(context, repos: [Logflare.Repo])
      end

      defp start_app_session(conn) do
        start_session(:phoenix, conn: conn)
      end
    end
  end
end
