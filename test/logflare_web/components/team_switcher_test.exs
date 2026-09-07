defmodule LogflareWeb.TeamSwitcherTest do
  @moduledoc false
  use LogflareWeb.CerberusConnCase

  setup %{conn: conn} do
    insert(:plan)
    user = insert(:user)
    team = insert(:team, user: user)
    user = %{user | team: team}
    conn = conn |> login_user(user)

    {:ok, user: user, conn: conn}
  end

  describe "team_switcher/1" do
    test "renders dropdown when user has multiple teams", %{conn: conn, user: user} do
      team2 = insert(:team, %{name: "Team B"})
      _team_user2 = insert(:team_user, team: team2, email: user.email)

      conn
      |> start_app_session()
      |> visit("/account/edit")
      |> expect(
        Expect.visible(by_text(by_css("#team-switcher a"), user.team.name, []) |> first())
      )
      |> expect(
        Expect.visible(
          by_text(by_css("#team-switcher a"), user.team.name <> " " <> "home team", [])
        )
      )
      |> expect(Expect.visible(by_text(by_css("#team-switcher a"), team2.name, [])))
    end

    test "renders current team name bold", %{conn: conn, user: user} do
      team2 = insert(:team, %{name: "Team B"})
      _team_user2 = insert(:team_user, team: team2, email: user.email)

      conn
      |> start_app_session()
      |> visit("/account/edit")
      |> expect(
        Expect.visible(
          by_text(by_css(~s|#team-switcher a[class~=tw-font-bold]|), user.team.name, [])
        )
      )
    end

    test "renders team name when user has single team", %{conn: conn, user: user} do
      conn
      |> start_app_session()
      |> visit("/account/edit")
      |> expect(Expect.visible(by_text(by_css("#team-switcher span"), user.team.name, [])))
    end

    test "preserves query params in team switcher links", %{conn: conn, user: user} do
      team2 = insert(:team)
      _team_user2 = insert(:team_user, team: team2, email: user.email)

      conn
      |> start_app_session()
      |> visit("/account/edit?key=test")
      |> expect(
        Expect.visible(
          by_css(
            ~s|#team-switcher a[href="/teams/switch?team_id=#{team2.id}&redirect_to=%2Faccount%2Fedit%3Fkey%3Dtest"]|
          )
        )
      )
    end
  end
end
