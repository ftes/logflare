defmodule E2e.Features.RegistrationTest do
  use Logflare.FluffyFeatureCase, async: false

  setup do
    start_supervised!(Logflare.SystemMetricsSup)

    :ok
  end

  describe "single tenant ui" do
    TestUtils.setup_single_tenant(seed_user: true)

    test "redirect to dashboard" do
      start_browser_session()
      |> visit(~p"/")
      |> expect(Fluffy.Page.to_have_url(~r|/dashboard(?:\?t=\d+)?$|))
    end
  end
end
