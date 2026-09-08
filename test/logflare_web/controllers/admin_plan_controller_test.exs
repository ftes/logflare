defmodule LogflareWeb.AdminPlanControllerTest do
  use LogflareWeb.CerberusConnCase, async: true

  alias Logflare.Billing

  setup do
    insert(:plan)

    :ok
  end

  describe "Listing Plans" do
    setup do
      admin = insert(:user, admin: true)
      {:ok, admin: admin}
    end

    test "displays list of plans for admin users", %{conn: conn, admin: admin} do
      _plan1 = insert(:plan, name: "Free Plan", price: 0, period: "month")
      _plan2 = insert(:plan, name: "Pro Plan", price: 2000, period: "month")

      conn
      |> login_user(admin)
      |> start_app_session()
      |> visit(~p"/admin/plans")
      |> expect(Expect.visible(by_text(by_css("h5"), "~/admin/plans", [])))
      |> expect(Expect.visible(by_text(by_css("h1"), "Plans", [])))
      |> expect(Expect.visible(by_css("table")))
      |> expect(
        Expect.visible(by_text(by_css("tbody tr:first-child td:nth-child(2)"), "Free", []))
      )
      |> expect(
        Expect.visible(by_text(by_css("tbody tr:nth-child(2) td:nth-child(2)"), "Free Plan", []))
      )
      |> expect(
        Expect.visible(by_text(by_css("tbody tr:nth-child(3) td:nth-child(2)"), "Pro Plan", []))
      )
      |> expect(Expect.visible(by_text(by_css("td"), "0", []) |> first()))
      |> expect(Expect.visible(by_text(by_css("td"), "2000", []) |> first()))
      |> expect(Expect.visible(by_text(by_css("a"), "New plan", []) |> first()))
      |> expect(Expect.visible(by_text(by_css("a"), "Edit", []) |> first()))
    end
  end

  describe "New Plan" do
    setup do
      admin = insert(:user, admin: true)

      {:ok, admin: admin}
    end

    test "creates new plan", %{conn: conn, admin: admin} do
      conn
      |> login_user(admin)
      |> start_app_session()
      |> visit(~p"/admin/plans")
      |> click(by_role(:link, name: "New plan"))
      |> expect(Cerberus.Page.to_have_url(~p"/admin/plans/new"))
      |> expect(Expect.visible(by_text(by_css("h5"), "~/admin/plans/new", [])))
      |> expect(Expect.visible(by_text(by_css("h1"), "New Plan", [])))
      |> expect(Expect.visible(by_css("button[type='submit']")))
      |> fill(by_label("Name", exact: true), "Test Plan")
      |> fill(by_label("Stripe", exact: true), "price_test123")
      |> fill(by_label("Period", exact: true), "month")
      |> fill(by_label("Price", exact: true), "1500")
      |> fill(by_label("Account Rate Limit (per second)", exact: true), "100")
      |> fill(by_label("Source Rate Limit (per second)", exact: true), "50")
      |> fill(by_label("Alerts Every (milliseconds)", exact: true), "60000")
      |> fill(by_label("Saved Searches (per source)", exact: true), "5")
      |> fill(by_label("Team Users", exact: true), "3")
      |> fill(by_label("Source Fields", exact: true), "300")
      |> fill(by_label("Source TTL", exact: true), "259200000")
      |> submit(by_css("form"))
      |> expect(Cerberus.Page.to_have_url(~p"/admin/plans"))
      |> expect(Expect.visible(by_text(by_css("#flash-info"), "Plan created!", [])))
      |> expect(
        Expect.visible(by_text(by_css("tbody tr:first-child td:nth-child(2)"), "Free", []))
      )
      |> expect(
        Expect.visible(by_text(by_css("tbody tr:nth-child(2) td:nth-child(2)"), "Test Plan", []))
      )

      assert plan = Billing.get_plan_by(name: "Test Plan")
      assert plan.name == "Test Plan"
      assert plan.stripe_id == "price_test123"
      assert plan.price == 1500
      assert plan.period == "month"
    end

    test "creates plan with default values when minimal params provided", %{
      conn: conn,
      admin: admin
    } do
      conn
      |> login_user(admin)
      |> start_app_session()
      |> visit(~p"/admin/plans/new")
      |> expect(Expect.visible(by_text(by_css("h1"), "New Plan", [])))
      |> expect(Expect.visible(by_css("button[type='submit']")))
      |> fill(by_label("Name", exact: true), "Minimal Plan")
      |> submit(by_css("form"))
      |> expect(Cerberus.Page.to_have_url(~p"/admin/plans"))
      |> expect(Expect.visible(by_text(by_css("#flash-info"), "Plan created!", [])))
      |> expect(
        Expect.visible(by_text(by_css("tbody tr:first-child td:nth-child(2)"), "Free", []))
      )
      |> expect(
        Expect.visible(
          by_text(by_css("tbody tr:nth-child(2) td:nth-child(2)"), "Minimal Plan", [])
        )
      )

      assert plan = Billing.get_plan_by(name: "Minimal Plan")
      assert plan.name == "Minimal Plan"
      assert plan.period == "month"
      assert plan.price == 0
    end
  end

  describe "Edit Plan" do
    setup do
      admin = insert(:user, admin: true)

      {:ok, admin: admin}
    end

    test "update existing plan in edit form", %{conn: conn, admin: admin} do
      plan =
        insert(:plan,
          name: "Existing Plan",
          stripe_id: "price_existing",
          price: 1000,
          period: "month",
          limit_sources: 25
        )

      conn
      |> login_user(admin)
      |> start_app_session()
      |> visit(~p"/admin/plans")
      |> click(by_text(by_css("a[href='#{~p"/admin/plans/#{plan}/edit"}']"), "Edit", []))
      |> expect(Cerberus.Page.to_have_url(~p"/admin/plans/#{plan}/edit"))
      |> expect(Expect.visible(by_text(by_css("h1"), "Edit Plan", [])))
      |> expect(Expect.visible(by_css("form")))
      |> expect(Expect.value(by_css("input[name='plan[name]']"), "Existing Plan"))
      |> expect(Expect.value(by_css("input[name='plan[stripe_id]']"), "price_existing"))
      |> expect(Expect.value(by_css("input[name='plan[price]']"), "1000"))
      |> expect(Expect.value(by_css("input[name='plan[period]']"), "month"))
      |> expect(Expect.value(by_css("input[name='plan[limit_sources]']"), "25"))
      |> expect(Expect.visible(by_css("button[type='submit']")))
      |> fill(by_label("Name", exact: true), "Updated Plan")
      |> fill(by_label("Price", exact: true), "1500")
      |> submit(by_css("form"))

      assert updated_plan = Billing.get_plan!(plan.id)
      assert updated_plan.name == "Updated Plan"
      assert updated_plan.price == 1500
    end

    test "raises error for non-existent plan", %{conn: conn, admin: admin} do
      assert_raise Ecto.NoResultsError, fn ->
        conn
        |> login_user(admin)
        |> get(~p"/admin/plans/999999/edit")
      end
    end

    test "returns 403 for non-admin users", %{conn: conn} do
      user = insert(:user, admin: false)
      plan = insert(:plan, name: "Test Plan for Edit")

      assert conn
             |> login_user(user)
             |> get(~p"/admin/plans/#{plan}/edit")
             |> html_response(403) =~ "Forbidden"

      assert conn
             |> login_user(user)
             |> put(~p"/admin/plans/#{plan}", %{plan: %{id: plan.id, name: "Updated"}})
             |> html_response(403) =~ "Forbidden"
    end

    test "redirects unauthenticated requests to login", %{conn: conn} do
      plan = insert(:plan, name: "Test Plan for Edit")

      assert conn
             |> get(~p"/admin/plans/#{plan}/edit")
             |> redirected_to(302) == "/auth/login"

      assert conn
             |> put(~p"/admin/plans/#{plan}", %{plan: %{id: plan.id, name: "Updated"}})
             |> redirected_to(302) == "/auth/login"
    end
  end

  test "returns 403 for non-admin users", %{conn: conn} do
    user = insert(:user)

    for path <- [~p"/admin/plans", ~p"/admin/plans/new"] do
      assert conn
             |> login_user(user)
             |> get(path)
             |> html_response(403) =~ "Forbidden"
    end
  end

  test "redirects unauthenticated requests to login", %{conn: conn} do
    for path <- [~p"/admin/plans", ~p"/admin/plans/new"] do
      assert conn
             |> get(path)
             |> redirected_to(302) == "/auth/login"
    end
  end
end
