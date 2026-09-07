defmodule LogflareWeb.CerberusConnCase do
  use ExUnit.CaseTemplate

  using opts do
    quote do
      use LogflareWeb.ConnCase, unquote(opts)

      import Cerberus, except: [expect: 3]
      import Cerberus.Locator

      alias Cerberus.Expect

      setup context do
        Cerberus.Test.setup(context, repos: [Logflare.Repo])
      end

      defp start_app_session(conn) do
        start_session(:phoenix, conn: conn)
      end
    end
  end
end
