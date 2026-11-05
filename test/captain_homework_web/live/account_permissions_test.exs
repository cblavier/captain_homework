defmodule CaptainHomeworkWeb.AccountPermissionsTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CaptainHomework.Fixtures
  alias CaptainHomework.{Auth, Repo, Study}

  test "children and family cannot open home settings or either subpage" do
    for account <- ["child-1", "family"] do
      conn = build_conn() |> init_test_session(Auth.session(account))
      {:ok, view, _} = live(conn, "/alice")
      refute has_element?(view, "#subjects-settings-button")

      for prefix <- ["", "/alice", "/enfants/alice"] do
        for path <- [
              "/matieres/parametres",
              "/parametres/matieres",
              "/parametres/types",
              "/parametres/types/nouveau",
              "/parametres/types/#{Ecto.UUID.generate()}"
            ] do
          assert get(conn, prefix <> path).status == 404
        end
      end

      render_patch(view, "/alice/matieres/parametres")
      assert_redirect(view, "/connexion")
      {:ok, view, _} = live(conn, "/alice")
      render_click(view, "save_subjects", %{"subjects" => %{"enabled_ids" => ["anglais"]}})
      assert_redirect(view, "/connexion")
      assert length(Study.enabled_subjects(profile())) > 1
    end
  end

  test "children and family cannot delete ongoing or completed exams, including forged events" do
    for account <- ["child-1", "family"], status <- ["in_progress", "completed"] do
      e =
        exam(lesson(profile()))
        |> Ecto.Changeset.change(
          status: status,
          score: 0.0,
          corrections: %{"q1" => %{"points" => 0, "fraction" => 0.0, "feedback" => "À revoir"}}
        )
        |> Repo.update!()

      conn = build_conn() |> init_test_session(Auth.session(account))
      {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")
      refute has_element?(view, "#delete-exam")
      render_click(view, "delete_exam")
      assert Repo.get!(Study.Exam, e.id)
    end
  end

  test "deletion checks current database status when a generation failure page is stale" do
    for account <- ["child-1", "family"] do
      e =
        exam(lesson(profile()))
        |> Ecto.Changeset.change(status: "generation_failed")
        |> Repo.update!()

      conn = build_conn() |> init_test_session(Auth.session(account))
      {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")
      assert has_element?(view, "#delete-exam")
      e |> Ecto.Changeset.change(status: "in_progress") |> Repo.update!()
      view |> element("#delete-exam") |> render_click()
      assert Repo.get!(Study.Exam, e.id).status == "in_progress"
    end
  end

  test "both parents retain home settings and deletion rights" do
    for account <- ["parent-1", "parent-2"] do
      conn = build_conn() |> init_test_session(Auth.session(account))
      {:ok, home, _} = live(conn, "/alice")
      assert has_element?(home, "#subjects-settings-button")

      for path <- ["/matieres/parametres", "/parametres/matieres", "/parametres/types"] do
        assert {:ok, _, _} = live(conn, "/alice" <> path)
      end

      e =
        exam(lesson(profile()))
        |> Ecto.Changeset.change(
          status: "completed",
          score: 0.0,
          corrections: %{"q1" => %{"points" => 0, "fraction" => 0.0, "feedback" => "À revoir"}}
        )
        |> Repo.update!()

      {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")
      view |> element("#delete-exam") |> render_click()
      refute Repo.get(Study.Exam, e.id)
    end
  end
end
