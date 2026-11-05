defmodule CaptainHomeworkWeb.HomeworkLiveTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CaptainHomework.Fixtures
  alias CaptainHomework.{Study, Repo}

  test "home counts all exams by subject for the current profile", %{conn: conn} do
    alice = profile()
    first = lesson(alice, "anglais")
    second = lesson(alice, "anglais")
    exam(first)
    exam(second) |> Ecto.Changeset.change(format: "flashcard") |> Repo.update!()
    exam(lesson(alice, "svt"))
    exam(lesson(profile("Marius"), "anglais"))

    {:ok, view, _} = live(conn, "/alice")
    assert has_element?(view, "#subject-anglais .subject-copy", "2 leçons · 2 contrôles")
    assert has_element?(view, "#subject-svt .subject-copy", "1 leçon · 1 contrôle")
    assert has_element?(view, "#subject-francais .subject-copy", "0 leçon · 0 contrôle")
  end

  test "settings offer the three device appearance preferences", %{conn: conn} do
    profile()
    {:ok, view, _} = live(conn, "/alice/parametres")
    assert has_element?(view, "#theme-settings[phx-hook='ThemeSettings'][phx-update='ignore']")
    assert has_element?(view, "#theme-light[value='light']")
    assert has_element?(view, "#theme-dark[value='dark']")
    assert has_element?(view, "#theme-system[value='system'][checked]")
  end

  test "shared reading documents appear once while answers remain separate", %{conn: conn} do
    text = String.duplicate("Les migrations se font lentement. ", 12)
    first = question("source", "reading") |> Map.put("text", text <> "Source : livre, 2016.")
    second = question("speed", "reading") |> Map.put("text", text)
    e = exam(lesson(profile()), [first, second])
    {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")
    assert has_element?(view, ".shared-question-support .reading-text", "Source : livre, 2016.")
    refute has_element?(view, "#question-source .reading-text")
    refute has_element?(view, "#question-speed .reading-text")
    assert has_element?(view, "#answer-source")
    assert has_element?(view, "#answer-speed")
  end

  test "exam footer displays its stored generation duration", %{conn: conn} do
    l = lesson(profile())
    e = exam(l) |> Ecto.Changeset.change(generation_duration_ms: 83_000) |> Repo.update!()
    {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")

    assert has_element?(
             view,
             "#generation-duration.generation-duration",
             "Généré en 1mn 23 sec"
           )

    assert has_element?(view, "#exam-footer #delete-exam", "Supprimer")
    e |> Ecto.Changeset.change(generation_duration_ms: nil) |> Repo.update!()
    {:ok, reloaded, _} = live(conn, "/alice/controles/#{e.id}")
    refute has_element?(reloaded, "#generation-duration")
  end

  test "a shared document does not hide the individual tasks", %{conn: conn} do
    questions =
      for {id, task} <- [
            {"authors", "Qui sont les auteurs ?"},
            {"speed", "Les migrations sont-elles rapides ?"}
          ] do
        question(id, "reading")
        |> Map.merge(%{
          "prompt" => "Analyse le document.",
          "text" => task,
          "support_id" => "doc",
          "support_text" => "Les migrations sont lentes. Source : livre, 2016."
        })
      end

    e = exam(lesson(profile()), questions)
    {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")

    assert has_element?(
             view,
             "#question-group-authors .shared-question-support .reading-text",
             "Source : livre, 2016."
           )

    refute has_element?(view, "#question-group-speed")
    assert has_element?(view, "#question-authors .reading-text", "Qui sont les auteurs ?")

    assert has_element?(
             view,
             "#question-speed .reading-text",
             "Les migrations sont-elles rapides ?"
           )

    assert has_element?(view, "#answer-authors")
    assert has_element?(view, "#answer-speed")
  end

  test "question type checkboxes default to all and require a selection", %{conn: conn} do
    l = lesson(profile())
    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}/controle")

    for type <- CaptainHomework.QuestionDefinitions.available(l.subject) do
      assert has_element?(view, "#question-type-#{type.id}[checked]")
    end

    [mcq, long] = question_type_ids(["mcq", "long"])
    view |> form("#exam-setup") |> render_change(%{"question_types" => ["", mcq]})
    assert has_element?(view, "#question-type-#{mcq}[checked]")
    refute has_element?(view, "#question-type-#{long}[checked]")
    view |> element("button[phx-click=change_count][phx-value-delta='1']") |> render_click()
    assert has_element?(view, "#question-type-#{mcq}[checked]")
    refute has_element?(view, "#question-type-#{long}[checked]")
    view |> form("#exam-setup") |> render_change(%{"question_types" => [""]})
    assert has_element?(view, "#question-types-error")
    assert has_element?(view, "#generate-exam[disabled]")
  end

  test "example pages are numbered and reorder independently from course pages", %{conn: conn} do
    l = lesson(profile())
    course = page(l)

    attrs = %{
      kind: "example",
      filename: "example.png",
      storage_key: "example.png",
      content_type: "image/png"
    }

    {:ok, first} = Study.add_page(l, attrs)
    {:ok, second} = Study.add_page(l, attrs)
    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}")
    assert has_element?(view, "#example-#{first.id} strong", "Page 1")
    assert has_element?(view, "#example-previous-#{first.id}[disabled]")
    assert has_element?(view, "#example-next-#{second.id}[disabled]")
    view |> element("#example-next-#{first.id}") |> render_click()
    assert has_element?(view, "#example-#{second.id} + #example-#{first.id}")
    assert has_element?(view, "#example-#{first.id} strong", "Page 2")
    assert Study.get_page!(l.profile_id, course.id).position == course.position
    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}")
    assert has_element?(view, "#example-#{second.id} + #example-#{first.id}")
    view |> element("#example-previous-#{first.id}") |> render_click()
    assert has_element?(view, "#example-#{first.id} + #example-#{second.id}")
  end

  test "all subject hierarchy pages share the discrete breadcrumb", %{conn: conn} do
    l = lesson(profile())
    e = exam(l)

    for {path, id} <- [
          {"/alice", "subjects-title"},
          {"/alice/matieres/svt", "subject-title"},
          {"/alice/lecons/#{l.id}?onglet=controles", "lesson-title"},
          {"/alice/lecons/#{l.id}?onglet=cours", "lesson-title"},
          {"/alice/lecons/#{l.id}?onglet=ressources", "lesson-title"},
          {"/alice/lecons/#{l.id}/controle", "new-exam-title"},
          {"/alice/controles/#{e.id}", "exam-title"}
        ] do
      {:ok, view, _} = live(conn, path)

      assert has_element?(
               view,
               "##{id}-breadcrumb > .breadcrumb-path > .breadcrumb-title[aria-current=page] ##{id}"
             )

      refute has_element?(view, ".back-link")

      if id == "subjects-title" do
        refute has_element?(view, "##{id}-breadcrumb nav")
      else
        assert has_element?(
                 view,
                 "##{id}-breadcrumb > .breadcrumb-path > nav + .breadcrumb-title .icon-tile"
               )

        assert has_element?(view, "##{id}-breadcrumb nav a[href='/alice']")
      end
    end
  end

  test "page headings contain breadcrumb links to their ancestors", %{conn: conn} do
    l = lesson(profile())
    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}")
    assert has_element?(view, "#lesson-title-breadcrumb a[href='/alice']")
    assert has_element?(view, "#lesson-title-breadcrumb a[href='/alice/matieres/svt']")
    assert has_element?(view, "#lesson-title-breadcrumb [aria-current=page] #lesson-title")
    refute has_element?(view, ".back-link")
    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}/controle")

    view
    |> element("#new-exam-title-breadcrumb a[href='/alice/lecons/#{l.id}']")
    |> render_click()

    assert_redirect(view, "/alice/lecons/#{l.id}")
  end

  test "lesson pages can be reordered and new pages are appended", %{conn: conn} do
    l = lesson(profile())
    first = page(l)
    second = page(l)

    {:ok, example} =
      Study.add_page(l, %{
        kind: "example",
        filename: "example.png",
        storage_key: "example.png",
        content_type: "image/png"
      })

    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}?onglet=cours")
    assert has_element?(view, "#page-previous-#{first.id}[disabled]")
    assert has_element?(view, "#page-next-#{second.id}[disabled]")
    view |> element("#page-next-#{first.id}") |> render_click()
    assert has_element?(view, "#lesson-page-#{second.id} + #lesson-page-#{first.id}")
    assert has_element?(view, "#page-previous-#{second.id}[disabled]")
    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}?onglet=cours")
    assert has_element?(view, "#lesson-page-#{second.id} + #lesson-page-#{first.id}")
    third = page(l)
    pages = Study.get_lesson!(l.profile_id, l.id).pages |> Enum.filter(&(&1.kind == "lesson"))
    assert Enum.map(pages, & &1.id) == [second.id, first.id, third.id]
    assert Study.get_page!(l.profile_id, example.id).position == example.position
    view |> element("#page-previous-#{first.id}") |> render_click()
    assert has_element?(view, "#lesson-page-#{first.id} + #lesson-page-#{second.id}")
  end

  test "page moves respect lesson boundaries and list boundaries" do
    p = profile()
    l = lesson(p)
    first = page(l)
    other_lesson = lesson(p)
    other_page = page(other_lesson)
    assert {:ok, _} = Study.move_page(p.id, l.id, first.id, "previous")
    assert {:ok, _} = Study.move_page(p.id, l.id, first.id, "next")
    assert {:error, :not_found} = Study.move_page(p.id, l.id, other_page.id, "previous")

    assert_raise Ecto.NoResultsError, fn ->
      Study.move_page(profile("Marius").id, l.id, first.id, "next")
    end

    assert Study.get_page!(p.id, first.id).position == 0
  end

  test "an unsubmitted exam can be deleted from its page", %{conn: conn} do
    l = lesson(profile())
    e = exam(l)
    {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")
    assert has_element?(view, "#delete-exam[data-confirm]")
    view |> element("#delete-exam") |> render_click()
    assert_redirect(view, "/alice/lecons/#{l.id}")
    refute Repo.get(Study.Exam, e.id)
    assert Repo.get(Study.Lesson, l.id)
  end

  test "completed classic and flashcard exams can be deleted with their results", %{conn: conn} do
    l = lesson(profile())

    for format <- ["classic", "flashcard"] do
      e =
        exam(l)
        |> Ecto.Changeset.change(
          format: format,
          status: "completed",
          submitted_at: DateTime.utc_now(),
          score: 20.0,
          answers: %{"q1" => "Une limite"},
          corrections: %{"q1" => %{"points" => 4, "fraction" => 1.0, "feedback" => "Correct"}}
        )
        |> Repo.update!()

      assert Study.exam_deletable?(e)
      {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")
      assert has_element?(view, "#exam-footer #delete-exam[data-confirm*='résultats']")
      view |> element("#delete-exam") |> render_click()
      assert_redirect(view, "/alice/lecons/#{l.id}")
      refute Repo.get(Study.Exam, e.id)
      assert Repo.get(Study.Lesson, l.id)
    end
  end

  test "grading exams cannot be deleted even with a stale page", %{conn: conn} do
    l = lesson(profile())
    e = exam(l)
    {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")

    grading =
      e
      |> Ecto.Changeset.change(status: "grading", grading_started_at: DateTime.utc_now())
      |> Repo.update!()

    refute Study.exam_deletable?(grading)
    view |> element("#delete-exam") |> render_click()
    assert Repo.get!(Study.Exam, e.id).status == "grading"
    assert {:error, :already_submitted} = Study.delete_exam(l.profile_id, e.id)
    {:ok, refreshed, _} = live(conn, "/alice/controles/#{e.id}")
    refute has_element?(refreshed, "#delete-exam")
  end

  test "only empty lessons can be deleted", %{conn: conn} do
    l = lesson(profile())
    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}")
    assert has_element?(view, "#delete-lesson:not([disabled])")
    view |> element("#delete-lesson") |> render_click()
    assert_redirect(view, "/alice/matieres/svt")
    refute Repo.get(Study.Lesson, l.id)
  end

  test "each content kind prevents deletion, including from a stale page", %{conn: conn} do
    child = profile()

    for kind <- [:page, :exam, :resource] do
      l = lesson(child)
      {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}")

      content =
        case kind do
          :page -> page(l)
          :exam -> exam(l)
          :resource -> Repo.insert!(%Study.Resource{lesson_id: l.id, filename: "document.pdf"})
        end

      view |> element("#delete-lesson") |> render_click()
      assert {:error, :not_empty} = Study.delete_lesson(child.id, l.id)
      assert Repo.get(Study.Lesson, l.id)
      assert Repo.get(content.__struct__, content.id)
      {:ok, fresh, _} = live(conn, "/alice/lecons/#{l.id}")
      assert has_element?(fresh, "#delete-lesson[disabled]")
      refute has_element?(fresh, "#delete-lesson-tooltip[title]")
      assert has_element?(fresh, "#delete-lesson-help[role=tooltip]")
    end
  end

  test "deletions are scoped to the child" do
    l = lesson(profile())
    e = exam(l)
    other = profile("Marius")
    assert_raise Ecto.NoResultsError, fn -> Study.delete_lesson(other.id, l.id) end
    assert_raise Ecto.NoResultsError, fn -> Study.delete_exam(other.id, e.id) end
    assert Repo.get(Study.Lesson, l.id)
    assert Repo.get(Study.Exam, e.id)

    e
    |> Ecto.Changeset.change(status: "completed", submitted_at: DateTime.utc_now())
    |> Repo.update!()

    assert_raise Ecto.NoResultsError, fn -> Study.delete_exam(other.id, e.id) end
    assert Repo.get(Study.Exam, e.id)
  end

  test "browser titles use the child and current page like Captain Notes", %{conn: conn} do
    l = lesson(profile())
    e = exam(l)

    for {path, title} <- [
          {"/alice", "Alice - Accueil"},
          {"/alice/parametres", "Alice - Paramètres"},
          {"/alice/matieres/anglais", "Alice - Anglais"},
          {"/alice/lecons/#{l.id}", "Alice - Contrôles"},
          {"/alice/lecons/#{l.id}?onglet=cours", "Alice - Cours"},
          {"/alice/lecons/#{l.id}?onglet=ressources", "Alice - Ressources"},
          {"/alice/lecons/#{l.id}/controle", "Alice - Nouveau contrôle"},
          {"/alice/controles/#{e.id}", "Alice - Contrôle"},
          {"/marius", "Marius - Accueil"}
        ] do
      {:ok, view, _} = live(conn, path)
      assert page_title(view) == title
    end

    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}")
    view |> element("#lesson-tab-cours") |> render_click()
    assert page_title(view) == "Alice - Cours"
  end

  test "first visit uses configured members without profile management", %{conn: conn} do
    {:ok, view, _} = live(conn, "/alice")
    assert has_element?(view, "#child-picker-toggle #child-name", "Alice")
    assert has_element?(view, "#child-picker-panel .child-picker-option", "Marius")
    refute has_element?(view, "#child-picker-panel .child-picker-option", "Alice")
    assert has_element?(view, "#profile-switch[action='/profil'][method='post']")
    refute has_element?(view, "#profile-select")
    assert has_element?(view, "#subject-svt")
    refute has_element?(view, "#first-profile")
    refute has_element?(view, "a[href='/profils']")
    refute has_element?(view, "#new-profile")
  end

  test "no configured members offers no creation form", %{conn: conn} do
    old = Application.fetch_env!(:captain_homework, :family_env)
    Application.put_env(:captain_homework, :family_env, %{})
    on_exit(fn -> Application.put_env(:captain_homework, :family_env, old) end)
    {:ok, view, _} = live(conn, "/")
    assert has_element?(view, "#no-profiles")
    refute has_element?(view, "#first-profile")
    refute has_element?(view, "#profile-switch")
  end

  test "configured avatar is displayed", %{conn: conn} do
    old = Application.fetch_env!(:captain_homework, :family_env)
    avatar = Base.encode64(<<137, 80, 78, 71, 13, 10, 26, 10>>)

    Application.put_env(
      :captain_homework,
      :family_env,
      Map.put(old, "HOMEWORK_CHILD_1_AVATAR_BASE64", avatar)
    )

    on_exit(fn -> Application.put_env(:captain_homework, :family_env, old) end)
    {:ok, view, _} = live(conn, "/alice")
    assert has_element?(view, "#profile-avatar[src='data:image/png;base64,#{avatar}']")
    refute has_element?(view, "#profile-initial")
  end

  test "unconfigured profile cannot be selected", %{conn: conn} do
    hidden = Repo.insert!(%Study.Profile{name: "Hidden"})
    conn = post(conn, "/profil", %{profile_id: hidden.id})
    assert conn.status == 404
    refute get_session(conn, :profile_id)
  end

  test "home presents the five subjects and the brand footer", %{conn: conn} do
    profile()
    {:ok, view, _} = live(conn, "/alice")
    for id <- Study.subject_ids(), do: assert(has_element?(view, "#subject-#{id}"))
    refute has_element?(view, "header")
    assert has_element?(view, "footer #footer-logo[aria-label='Captain Homework']")
  end

  test "creates a lesson with its date", %{conn: conn} do
    p = profile()
    {:ok, view, _} = live(conn, "/alice/matieres/francais")
    view |> element("#new-lesson") |> render_click()
    view |> form("#lesson-form", %{lesson: %{title: "Le présent"}}) |> render_submit()
    [lesson] = Study.lessons(p.id, "francais")
    assert_redirect(view, "/alice/lecons/#{lesson.id}")
    assert lesson.date == Study.today()
  end

  test "new exams only ask for additional instructions", %{conn: conn} do
    l = lesson(profile())
    exam(l)
    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}/controle")

    assert has_element?(
             view,
             "#instructions[placeholder][autocorrect=on][spellcheck=true][writingsuggestions=true]"
           )

    refute has_element?(view, "#instructions", "Instructions SVT")
    refute has_element?(view, "#reset-instructions")
    assert has_element?(view, "#settings-link[href='/alice/parametres']")
  end

  test "subject settings persist, filter the home page and allow reactivation", %{conn: conn} do
    {:ok, settings, _} = live(conn, "/alice/parametres/matieres")

    for id <- Study.subject_ids(),
        do: assert(has_element?(settings, "#enable-subject-#{id}[checked]"))

    settings
    |> form("#subjects-settings-form", subjects: %{enabled_ids: ["anglais", "latin"]})
    |> render_submit()

    {:ok, home, _} = live(conn, "/alice")
    assert has_element?(home, "#subject-anglais")
    assert has_element?(home, "#subject-latin")
    refute has_element?(home, "#subject-svt")
    {:ok, other, _} = live(conn, "/marius")
    assert has_element?(other, "#subject-svt")
    {:ok, reopened, _} = live(conn, "/alice/parametres/matieres")
    refute has_element?(reopened, "#enable-subject-svt[checked]")
    reopened |> form("#subjects-settings-form", subjects: %{enabled_ids: [""]}) |> render_submit()
    {:ok, empty, _} = live(conn, "/alice")
    assert has_element?(empty, "#no-enabled-subjects")
    {:ok, settings, _} = live(conn, "/alice/parametres/matieres")

    settings
    |> form("#subjects-settings-form", subjects: %{enabled_ids: Study.subject_ids()})
    |> render_submit()

    {:ok, home, _} = live(conn, "/alice")
    assert has_element?(home, "#subject-svt")
  end

  test "settings no longer expose a general prompt and exam additions remain available", %{
    conn: conn
  } do
    l = lesson(profile())
    {:ok, view, _} = live(conn, "/alice/parametres")
    refute has_element?(view, "#default-instructions")
    refute has_element?(view, "#settings-form")
    assert has_element?(view, "#settings-title-breadcrumb a[href='/alice']", "Retour à l’accueil")
    assert has_element?(view, "#theme-settings")
    refute has_element?(view, "#manage-student-subjects")

    {:ok, creation, _} = live(conn, "/alice/lecons/#{l.id}/controle")
    assert has_element?(creation, "#instructions")
    refute has_element?(creation, "#exam-setup a[href='/alice/parametres']")
  end

  test "partial generation can resume without exposing answers or losing saved questions", %{
    conn: conn
  } do
    old = Application.fetch_env!(:captain_homework, :ai_provider)
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.TestAI)
    on_exit(fn -> Application.put_env(:captain_homework, :ai_provider, old) end)
    l = lesson(profile())
    page(l)

    e =
      exam(l)
      |> Ecto.Changeset.change(
        status: "generation_partial",
        generation_target: 2,
        generation_errors: ["QCM : réponse absente des choix."]
      )
      |> Repo.update!()

    {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")
    assert has_element?(view, "#generation-status", "1 question prête sur 2")
    assert has_element?(view, "#generation-errors", "QCM")
    refute has_element?(view, "#exam-answers")
    Phoenix.PubSub.subscribe(CaptainHomework.PubSub, "exam:#{e.id}")
    view |> element("#resume-generation") |> render_click()
    saved = await_generation(e.id)
    assert saved.status == "in_progress"
    assert hd(saved.questions) == hd(e.questions)
    assert length(saved.questions) == 2
  end

  test "question stepper starts at ten and is bounded", %{conn: conn} do
    l = lesson(profile())
    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}/controle")
    assert has_element?(view, "#question-count", "10")
    view |> element("button[phx-value-delta='1']") |> render_click()
    assert has_element?(view, "#question-count", "11")
    for _ <- 1..10, do: render_click(view, "change_count", %{"delta" => "-1"})
    assert has_element?(view, "#question-count", "1")
    assert has_element?(view, "button[phx-value-delta='-1'][disabled]")
  end

  test "generation uses the AI adapter and redirects to the created exam", %{conn: conn} do
    old = Application.fetch_env!(:captain_homework, :ai_provider)
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.TestAI)
    on_exit(fn -> Application.put_env(:captain_homework, :ai_provider, old) end)
    p = profile()
    l = lesson(p)
    page(l)
    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}/controle")
    view |> form("#exam-setup", %{instructions: "Varier les questions"}) |> render_submit()
    {path, _flash} = assert_redirect(view, 5000)
    [exam] = Study.get_lesson!(p.id, l.id).exams
    Phoenix.PubSub.subscribe(CaptainHomework.PubSub, "exam:#{exam.id}")
    exam = await_generation(exam.id)
    assert length(exam.questions) == 10
    assert path == "/alice/controles/#{exam.id}"
  end

  test "completed exam shows appreciation and exact raw points", %{conn: conn} do
    e = exam(lesson(profile()), [question("q")])

    e =
      e
      |> Ecto.Changeset.change(
        status: "completed",
        score: 16.71,
        appreciation: "Des connaissances solides ; précise tes justifications.",
        corrections: %{
          "q" => %{
            "points" => 3.25,
            "fraction" => 0.75,
            "feedback" => "Bien",
            "expected" => "Réponse"
          }
        }
      )
      |> Repo.update!()

    {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")
    assert has_element?(view, ".total-score.score-good", "16,75")
    assert has_element?(view, "#exam-score-tooltip[role=tooltip]", "3,25/4")
    refute has_element?(view, ".total-score[title]")
    assert has_element?(view, "#exam-appreciation.score-good", e.appreciation)
  end

  test "answers autosave and correction remains hidden during the exam", %{conn: conn} do
    p = profile()
    e = exam(lesson(p))
    {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")
    view |> form("#exam-answers", answers: %{"q1" => "Une limite"}) |> render_change()
    assert Study.get_exam!(p.id, e.id).answers["q1"] == "Une limite"
    refute has_element?(view, ".correction")
    refute has_element?(view, "#exam-answers", "Elle délimite la cellule.")
    view |> form("#exam-answers", answers: %{"q1" => "Une limite"}) |> render_submit()
    assert has_element?(view, "#submit-confirm")
    assert Study.get_exam!(p.id, e.id).status == "in_progress"
  end

  test "a completed exam shows total and per-question correction", %{conn: conn} do
    p = profile()
    e = exam(lesson(p))

    e
    |> Ecto.Changeset.change(
      status: "completed",
      score: 10.0,
      submitted_at: DateTime.utc_now(),
      answers: %{"q1" => "Une limite"},
      corrections: %{
        "q1" => %{
          "fraction" => 0.5,
          "points" => 2,
          "feedback" => "À compléter",
          "expected" => "Elle délimite la cellule."
        }
      }
    )
    |> Repo.update!()

    {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")
    assert has_element?(view, ".total-score.score-average", "10")
    assert has_element?(view, ".correction", "2 / 4")
    refute has_element?(view, ".correction-correct")
    refute has_element?(view, "#finish-exam")
  end

  test "profile selection persists and hides another child's lessons", %{conn: conn} do
    a = profile()
    b = profile("Marius")
    lesson(a)
    conn = post(conn, "/profil", %{profile_id: b.id})
    assert get_session(conn, :profile_id) == b.id
    {:ok, view, _} = live(recycle(conn), "/marius/matieres/svt")
    refute has_element?(view, ".lesson-row")
  end

  test "URL selects the child independently of the session", %{conn: conn} do
    alice = profile()
    marius = profile("Marius")
    conn = init_test_session(conn, %{profile_id: marius.id})
    {:ok, view, _} = live(conn, "/alice/matieres/svt")
    assert has_element?(view, "#child-name", "Alice")
    refute has_element?(view, ".identity-row .brand")
    assert has_element?(view, "#settings-link[href='/alice/parametres']")
    assert {:error, {:live_redirect, %{to: "/marius"}}} = live(conn, "/")
    l = lesson(alice)

    assert_raise Ecto.NoResultsError, fn ->
      live(conn, "/marius/lecons/#{l.id}")
    end
  end

  test "each child URL applies its configured colour palette", %{conn: conn} do
    old = Application.fetch_env!(:captain_homework, :family_env)

    Application.put_env(
      :captain_homework,
      :family_env,
      Map.merge(old, %{
        "PRONOTE_CHILD_1_THEME" => "green",
        "PRONOTE_CHILD_2_THEME" => "blue"
      })
    )

    on_exit(fn -> Application.put_env(:captain_homework, :family_env, old) end)
    {:ok, alice, _} = live(conn, "/alice")
    assert has_element?(alice, ".page-shell[data-child-theme=green]")
    assert has_element?(alice, ".child-option-avatar[data-child-theme=blue]")
    {:ok, marius, _} = live(conn, "/marius")
    assert has_element?(marius, ".page-shell[data-child-theme=blue]")
  end

  test "old child URLs redirect to the simplified path", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/marius/matieres/anglais"}}} =
             live(conn, "/enfants/marius-2/matieres/anglais")
  end

  test "a page URL cannot read another child's photo", %{conn: conn} do
    p = profile() |> lesson() |> page()
    assert_error_sent 404, fn -> get(conn, "/marius/pages/#{p.id}") end
  end

  test "lesson tabs separate content and keep their selection in the URL", %{conn: conn} do
    l = lesson(profile())
    page(l)
    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}")
    assert has_element?(view, "#lesson-tab-controles[aria-current=page]")
    assert has_element?(view, "#lesson-count-controles", "0")
    assert has_element?(view, "#lesson-count-cours", "1")
    assert has_element?(view, "#lesson-count-ressources", "0")
    assert has_element?(view, "#lesson-controls #lesson-examples")
    refute has_element?(view, "#lesson-course")
    view |> element("#lesson-tab-cours") |> render_click()
    assert_patch(view, "/alice/lecons/#{l.id}?onglet=cours")
    assert has_element?(view, "#lesson-course button[phx-click=edit_page]")
    refute has_element?(view, "#lesson-controls")
    view |> element("#lesson-tab-ressources") |> render_click()
    assert has_element?(view, "#lesson-resources")
    refute has_element?(view, "#lesson-course")
    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}?onglet=cours")
    assert has_element?(view, "#lesson-tab-cours[aria-current=page]")
  end

  test "example photos are managed from the controls tab", %{conn: conn} do
    p = profile()
    l = lesson(p)
    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}")

    image =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aLioAAAAASUVORK5CYII="
      )

    upload =
      file_input(view, "#upload-examples", :examples, [
        %{name: "exemple.png", content: image, type: "image/png"}
      ])

    assert has_element?(view, "#upload-examples input[data-phx-auto-upload]")
    render_upload(upload, "exemple.png", 50)
    assert has_element?(view, "#save-examples[disabled]")
    render_upload(upload, "exemple.png", 50)
    refute has_element?(view, "#save-examples[disabled]")
    view |> form("#upload-examples") |> render_submit()
    [pg] = Study.get_lesson!(p.id, l.id).pages
    on_exit(fn -> File.rm(CaptainHomework.Uploads.path(pg.storage_key)) end)
    assert pg.kind == "example"
    assert has_element?(view, "#example-#{pg.id}")
    {:ok, setup, _} = live(conn, "/alice/lecons/#{l.id}/controle")
    refute has_element?(setup, "input[name='example_ids[]']")
    refute has_element?(setup, "input[type=file]")
    view |> element("#delete-example-#{pg.id}") |> render_click()
    assert Study.get_lesson!(p.id, l.id).pages == []
    refute has_element?(view, "#example-#{pg.id}")
  end

  test "file uploads persist and can be corrected manually without AI", %{conn: conn} do
    old = Application.get_env(:captain_homework, :openai_api_key)
    Application.put_env(:captain_homework, :openai_api_key, nil)
    on_exit(fn -> Application.put_env(:captain_homework, :openai_api_key, old) end)
    p = profile()
    l = lesson(p)
    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}?onglet=cours")
    assert has_element?(view, "#lesson-course #upload-pages input[type=file]")
    refute has_element?(view, "#save-pages")

    image =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aLioAAAAASUVORK5CYII="
      )

    upload =
      file_input(view, "#upload-pages", :pages, [
        %{name: "cours.png", content: image, type: "image/png"}
      ])

    render_upload(upload, "cours.png")
    view |> form("#upload-pages") |> render_submit()
    [pg] = Study.get_lesson!(p.id, l.id).pages
    assert File.exists?(CaptainHomework.Uploads.path(pg.storage_key))
    on_exit(fn -> File.rm(CaptainHomework.Uploads.path(pg.storage_key)) end)
    view |> element("button[phx-click=edit_page]") |> render_click()
    view |> form("#page-text-form", %{text: "Un noyau dans la cellule."}) |> render_submit()
    assert Study.get_page!(p.id, pg.id).text == "Un noyau dans la cellule."
  end

  test "rereading replaces an emptied draft without reopening the modal", %{conn: conn} do
    old = Application.fetch_env!(:captain_homework, :ai_provider)
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.TestAI)
    on_exit(fn -> Application.put_env(:captain_homework, :ai_provider, old) end)
    l = lesson(profile())
    pg = page(l)
    key = "#{Ecto.UUID.generate()}.png"
    pg |> Ecto.Changeset.change(storage_key: key) |> Repo.update!()
    path = CaptainHomework.Uploads.path(key)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "test image")
    on_exit(fn -> File.rm(path) end)
    Phoenix.PubSub.subscribe(CaptainHomework.PubSub, "lesson:#{l.id}")

    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}?onglet=cours")
    view |> element("button[phx-click=edit_page]") |> render_click()
    view |> form("#page-text-form", %{text: ""}) |> render_change()
    view |> element("#page-modal button[phx-click=transcribe_page]") |> render_click()
    assert_receive :lesson_updated, 2000
    send(view.pid, :lesson_updated)
    assert has_element?(view, "#page-modal #page-text", "Texte reconnu sur la photo.")
    refute has_element?(view, "#page-modal button[phx-click=transcribe_page][disabled]")
  end

  test "OCR completion updates status while preserving edits made during reading", %{conn: conn} do
    l = lesson(profile())
    pg = page(l) |> Ecto.Changeset.change(status: "pending", text: "") |> Repo.update!()
    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}?onglet=cours")
    view |> element("button[phx-click=edit_page]") |> render_click()
    view |> form("#page-text-form", %{text: "Ma correction"}) |> render_change()
    pg |> Ecto.Changeset.change(status: "ready", text: "Résultat OCR") |> Repo.update!()
    send(view.pid, :lesson_updated)
    assert has_element?(view, "#page-text", "Ma correction")
    refute has_element?(view, "#page-modal button[phx-click=transcribe_page][disabled]")
  end

  test "photo transcription can be edited before it becomes an answer", %{conn: conn} do
    old = Application.fetch_env!(:captain_homework, :ai_provider)
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.TestAI)
    on_exit(fn -> Application.put_env(:captain_homework, :ai_provider, old) end)
    p = profile()
    e = exam(lesson(p))
    {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")
    view |> element("button[phx-click=open_ocr]") |> render_click()

    image =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aLioAAAAASUVORK5CYII="
      )

    upload =
      file_input(view, "#answer-photo-form", :answer_photo, [
        %{name: "copie.png", content: image, type: "image/png"}
      ])

    render_upload(upload, "copie.png")
    view |> form("#answer-photo-form") |> render_submit()
    render_async(view)
    assert has_element?(view, "#transcription", "Texte reconnu sur la photo.")
    assert Study.get_exam!(p.id, e.id).answers == %{}
    view |> form("#transcription-form", %{text: "Texte corrigé par l’élève"}) |> render_submit()
    assert Study.get_exam!(p.id, e.id).answers["q1"] == "Texte corrigé par l’élève"
    assert has_element?(view, "#answer-q1", "Texte corrigé par l’élève")
  end

  defp await_generation(id) do
    exam = Repo.get!(Study.Exam, id)

    if exam.status == "generating" do
      assert_receive :exam_updated, 5000
      await_generation(id)
    else
      jobs = :sys.get_state(CaptainHomework.Exams.GenerationJobs)

      if entry = Enum.find(jobs, fn {_, job} -> job.exam.id == id end) do
        {_, job} = entry
        ref = Process.monitor(job.task.pid)
        assert_receive {:DOWN, ^ref, :process, _, _}, 2000
      end

      exam
    end
  end
end
