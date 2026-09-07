defmodule E2e.Features.RegistrationTest do
  use Logflare.CerberusFeatureCase, async: false

  setup do
    start_supervised!(Logflare.SystemMetricsSup)

    :ok
  end

  describe "single tenant ui" do
    TestUtils.setup_single_tenant(seed_user: true)

    test "redirect to dashboard" do
      start_browser_session()
      |> visit(~p"/")
      |> expect(Expect.url(~r|/dashboard(?:\?t=\d+)?$|))
    end
  end
end
