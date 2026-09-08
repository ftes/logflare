defmodule LogflareWeb.TeamUserControllerTest do
  use LogflareWeb.FluffyConnCase

  alias Logflare.TeamUsers

  setup do
    insert(:plan)
    :ok
  end

  test "user can edit their profile", %{conn: conn} do
    owner = insert(:user)
    member_user = insert(:user)
    team = insert(:team, user: owner)
    team_user = insert(:team_user, team: team, email: member_user.email)

    new_name = "Avengers"
    new_email = "tony.stark@avengers.com"
    new_phone = "+1 (555) 123-4567"

    conn
    |> login_user(member_user, team_user)
    |> start_app_session()
    |> visit(~p"/profile/edit?t=#{team.id}")
    |> expect(Expect.visible(by_text(by_css("h5"), "Profile Preferences", exact: true)))
    |> fill(by_label("Name", exact: true), new_name)
    |> fill(by_label("Preferred email", exact: true), new_email)
    |> fill(by_label("Phone number", exact: true), new_phone)
    |> click(by_role(:button, name: "Update preferences"))
    |> expect(Expect.visible(by_text(by_css("#flash-info"), "Profile updated!", [])))
    |> expect(Expect.value(by_css("input#team_user_name"), new_name))
    |> expect(Expect.value(by_css("input#team_user_email_preferred"), new_email))
    |> expect(Expect.value(by_css("input#team_user_phone"), new_phone))
    |> expect(Fluffy.Page.to_have_url(~r|/profile/edit(?:\?.*)?$|))

    team_user = Logflare.Repo.reload!(team_user)
    assert team_user.name == new_name
    assert team_user.email_preferred == new_email
    assert team_user.phone == new_phone
  end

  test "not authenticated user is redirected to login page", %{conn: conn} do
    conn
    |> start_app_session()
    |> visit(~p"/profile/edit")
    |> expect(Fluffy.Page.to_have_url(~p"/auth/login"))
  end

  test "user can leave their team", %{conn: conn} do
    owner = insert(:user)
    team = insert(:team, user: owner)
    team_user = insert(:team_user, team: team)

    expect(
      GoogleApi.CloudResourceManager.V1.Api.Projects,
      :cloudresourcemanager_projects_set_iam_policy,
      fn _, _project_number, [body: _body] -> {:ok, ""} end
    )

    conn
    |> login_user(owner, team_user)
    |> start_app_session()
    |> visit(~p"/profile/edit?t=#{team.id}")
    |> expect(Expect.visible(by_text(by_css("h5"), "Profile Preferences", exact: true)))
    |> click(by_role(:link, name: "Leave now"))
    |> expect(Fluffy.Page.to_have_url(~r|/auth/login\?team_user_deleted=true$|))

    refute TeamUsers.get_team_user(team_user.id)
  end

  test "owner can delete a team member", %{conn: conn} do
    owner = insert(:user)
    team = insert(:team, user: owner)
    member_user = insert(:user)
    member_team_user = insert(:team_user, team: team, email: member_user.email)

    expect(
      GoogleApi.CloudResourceManager.V1.Api.Projects,
      :cloudresourcemanager_projects_set_iam_policy,
      fn _, _project_number, [body: _body] -> {:ok, ""} end
    )

    conn =
      conn
      |> login_user(owner)
      |> delete(~p"/profile/#{member_team_user.id}")

    assert redirected_to(conn, 302) == "/account/edit"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Member profile deleted!"
    refute TeamUsers.get_team_user(member_team_user.id)
  end

  test "not authenticated user cannot see delete a team member", %{conn: conn} do
    team_user = insert(:team_user)

    assert conn
           |> delete(~p"/profile/#{team_user.id}")
           |> redirected_to(302) == ~p"/auth/login"
  end

  test "owner cannot delete team member from another team", %{conn: conn} do
    owner_a = insert(:user)
    _team_a = insert(:team, user: owner_a)

    owner_b = insert(:user)
    team_b = insert(:team, user: owner_b)
    victim_team_user = insert(:team_user, team: team_b, email: "victim@example.com")

    conn =
      conn
      |> login_user(owner_a)
      |> delete(~p"/profile/#{victim_team_user.id}")

    assert redirected_to(conn, 302) == "/account/edit"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
             "Not authorized to delete this team member"

    assert TeamUsers.get_team_user!(victim_team_user.id)
  end

  test "team member cannot delete another team member (not owner)", %{conn: conn} do
    owner = insert(:user)
    team = insert(:team, user: owner)
    member1_user = insert(:user)
    member1_team_user = insert(:team_user, team: team, email: member1_user.email)
    member2_user = insert(:user)
    member2_team_user = insert(:team_user, team: team, email: member2_user.email)

    conn =
      conn
      |> login_user(member1_user, member1_team_user)
      |> delete(~p"/profile/#{member2_team_user.id}")

    assert redirected_to(conn, 302) == ~p"/dashboard"

    assert Enum.any?(Phoenix.Flash.get(conn.assigns.flash, :error), fn
             text when is_binary(text) -> text =~ "You're not the account owner"
             _ -> false
           end)

    assert Logflare.TeamUsers.get_team_user!(member2_team_user.id)
  end

  test "update re-renders edit form with submitted values when context returns error",
       %{conn: conn} do
    owner = insert(:user)
    team = insert(:team, user: owner)
    team_user = insert(:team_user, team: team)

    expect(TeamUsers, :update_team_user, fn tu, params ->
      changeset =
        tu
        |> TeamUsers.TeamUser.changeset(params)
        |> Ecto.Changeset.add_error(:email_preferred, "is invalid")

      {:error, changeset}
    end)

    conn
    |> login_user(owner, team_user)
    |> start_app_session()
    |> visit(~p"/profile/edit?t=#{team.id}")
    |> fill(by_label("Name", exact: true), "Bruce Banner")
    |> fill(by_label("Preferred email", exact: true), "hulk@avengers.com")
    |> click(by_role(:button, name: "Update preferences"))
    |> expect(Expect.visible(by_text(by_css("#flash-error"), "Something went wrong!", [])))
    |> expect(Expect.value(by_css("input#team_user_name"), "Bruce Banner"))
    |> expect(Expect.value(by_css("input#team_user_email_preferred"), "hulk@avengers.com"))
  end

  test "delete_self re-renders edit form when context returns error", %{conn: conn} do
    owner = insert(:user)
    team = insert(:team, user: owner)
    team_user = insert(:team_user, team: team)

    expect(TeamUsers, :delete_team_user, fn tu ->
      changeset =
        tu
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.add_error(:base, "cannot delete")

      {:error, changeset}
    end)

    conn
    |> login_user(owner, team_user)
    |> start_app_session()
    |> visit(~p"/profile/edit?t=#{team.id}")
    |> click(by_role(:link, name: "Leave now"))
    |> expect(Expect.visible(by_text(by_css("#flash-error"), "Something went wrong!", [])))
    |> expect(Expect.visible(by_text(by_css("h5"), "Profile Preferences", exact: true)))

    assert TeamUsers.get_team_user(team_user.id)
  end

  test "edit page shows GitHub-specific section for github provider", %{conn: conn} do
    owner = insert(:user)
    team = insert(:team, user: owner)
    team_user = insert(:team_user, team: team, provider: "github")

    conn
    |> login_user(owner, team_user)
    |> start_app_session()
    |> visit(~p"/profile/edit?t=#{team.id}")
    |> expect(Expect.visible(by_text(by_css("h5"), "Signed In with Github", [])))
    |> expect(
      Expect.visible(
        by_text(
          by_css("a[href='https://github.com/settings/applications']"),
          "Visit Github",
          []
        )
      )
    )
    |> expect(Expect.count(by_text(by_css("a"), "Visit Google", []), 0))
  end

  test "edit page shows Google-specific section for google provider", %{conn: conn} do
    owner = insert(:user)
    team = insert(:team, user: owner)
    team_user = insert(:team_user, team: team, provider: "google")

    conn
    |> login_user(owner, team_user)
    |> start_app_session()
    |> visit(~p"/profile/edit?t=#{team.id}")
    |> expect(Expect.visible(by_text(by_css("h5"), "Signed In with Google", [])))
    |> expect(Expect.visible(by_text(by_css("a"), "Visit Google", []) |> first()))
    |> expect(Expect.count(by_text(by_css("a"), "Visit Github", []), 0))
  end

  test "user can toggle email_me_product preference off", %{conn: conn} do
    owner = insert(:user)
    team = insert(:team, user: owner)
    team_user = insert(:team_user, team: team, email_me_product: true)

    conn
    |> login_user(owner, team_user)
    |> start_app_session()
    |> visit(~p"/profile/edit?t=#{team.id}")
    |> uncheck(by_label("Email me product updates", exact: true))
    |> click(by_role(:button, name: "Update preferences"))
    |> expect(Expect.visible(by_text(by_css("#flash-info"), "Profile updated!", [])))

    assert Logflare.Repo.reload!(team_user).email_me_product == false
  end
end
