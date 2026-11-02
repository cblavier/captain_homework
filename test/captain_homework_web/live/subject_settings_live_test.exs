defmodule CaptainHomeworkWeb.SubjectSettingsLiveTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CaptainHomework.Fixtures
  alias CaptainHomework.SubjectQuestionTypes

  setup do
    previous = Application.fetch_env!(:captain_homework, :ai_provider)
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.TestAI)
    on_exit(fn -> Application.put_env(:captain_homework, :ai_provider, previous) end)
    :ok
  end

  test "subject page links to settings, custom types persist and feed the exam form", %{
    conn: conn
  } do
    p = profile()
    l = lesson(p)
    {:ok, subject, _} = live(conn, "/alice/matieres/svt")
    assert has_element?(subject, "#subject-settings-link[href='/alice/matieres/svt/parametres']")
    {:ok, view, _} = live(conn, "/alice/matieres/svt/parametres")
    assert has_element?(view, "#subject-settings-title-breadcrumb .icon-tile")
    refute has_element?(view, "#type-format")
    assert has_element?(view, "#configured-type-mcq")
    refute has_element?(view, "#no-question-types")
    refute has_element?(view, "#configured-type-mcq .muted")

    view
    |> form("#question-type-form",
      question_type: %{
        label: "Comparer",
        description: "Comparer deux éléments.",
        work_duration: "long"
      }
    )
    |> render_submit()

    type = List.last(SubjectQuestionTypes.list(p.id, "svt"))
    assert type["work_duration"] == "long"
    assert has_element?(view, "#type-duration-#{type["id"]} option[value=long][selected]")
    assert has_element?(view, "#configured-type-#{type["id"]}", "Comparer")
    view |> element("#delete-type-mcq") |> render_click()
    refute has_element?(view, "#configured-type-mcq")

    {:ok, reloaded, _} = live(conn, "/alice/matieres/svt/parametres")
    assert has_element?(reloaded, "#configured-type-#{type["id"]}")
    refute has_element?(reloaded, "#configured-type-mcq")

    {:ok, creation, _} = live(conn, "/alice/lecons/#{l.id}/controle")
    assert has_element?(creation, "#question-type-#{type["id"]}[checked]")
    refute has_element?(creation, "#question-type-mcq")
    creation |> form("#exam-setup") |> render_change(%{"question_types" => [type["id"]]})
    assert has_element?(creation, "#question-type-#{type["id"]}[checked]")
    refute has_element?(creation, "#question-type-long[checked]")

    {:ok, other, _} = live(conn, "/marius/matieres/svt/parametres")
    assert has_element?(other, "#configured-type-mcq")
    refute has_element?(other, "#configured-type-#{type["id"]}")
  end

  test "work duration updates persist per child and subject and reject invalid values", %{
    conn: conn
  } do
    p = profile()
    other = profile("Marius")
    {:ok, _} = SubjectQuestionTypes.seed_catalogue(p.id, "mathematiques")
    {:ok, view, _} = live(conn, "/alice/matieres/mathematiques/parametres")
    assert has_element?(view, "#configured-type-catalogue-calcul-direct")
    assert has_element?(view, "#type-duration-mcq option[value=quick][selected]")

    view |> form("#duration-form-mcq", duration: %{work_duration: "medium"}) |> render_change()
    assert has_element?(view, "#type-duration-mcq option[value=medium][selected]")

    assert Enum.find(SubjectQuestionTypes.list(p.id, "mathematiques"), &(&1["id"] == "mcq"))[
             "work_duration"
           ] == "medium"

    assert Enum.find(SubjectQuestionTypes.list(p.id, "svt"), &(&1["id"] == "mcq"))[
             "work_duration"
           ] == "quick"

    assert Enum.find(SubjectQuestionTypes.list(other.id, "mathematiques"), &(&1["id"] == "mcq"))[
             "work_duration"
           ] == "quick"

    {:ok, reloaded, _} = live(conn, "/alice/matieres/mathematiques/parametres")
    assert has_element?(reloaded, "#type-duration-mcq option[value=medium][selected]")

    render_change(reloaded, "update_question_duration", %{
      "duration" => %{"id" => "mcq", "work_duration" => "invalid"}
    })

    assert has_element?(reloaded, "#type-duration-mcq option[value=medium][selected]")

    assert {:error, :not_found} =
             SubjectQuestionTypes.update_duration(p.id, "mathematiques", "unknown", "long")
  end

  test "empty message follows deleting the last type and adding a new one", %{conn: conn} do
    p = profile()

    for type <- SubjectQuestionTypes.defaults(),
        type["id"] != "mcq",
        do: SubjectQuestionTypes.delete(p.id, "svt", type["id"])

    {:ok, view, _} = live(conn, "/alice/matieres/svt/parametres")
    refute has_element?(view, "#no-question-types")
    view |> element("#delete-type-mcq") |> render_click()
    assert has_element?(view, "#no-question-types")

    view
    |> form("#question-type-form",
      question_type: %{label: "Comparer", description: "Comparer deux éléments."}
    )
    |> render_submit()

    refute has_element?(view, "#no-question-types")
    assert has_element?(view, "#configured-question-types article", "Comparer")
  end

  test "removing all types disables generation and offers settings", %{conn: conn} do
    p = profile()
    l = lesson(p)

    for type <- SubjectQuestionTypes.defaults(),
        do: SubjectQuestionTypes.delete(p.id, "svt", type["id"])

    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}/controle")
    assert has_element?(view, "#generate-exam[disabled]")
    assert has_element?(view, "a[href='/alice/matieres/svt/parametres']")
    {:ok, settings, _} = live(conn, "/alice/matieres/svt/parametres")
    assert has_element?(settings, "#no-question-types")
  end
end
