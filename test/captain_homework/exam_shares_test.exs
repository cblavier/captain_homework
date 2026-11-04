defmodule CaptainHomework.ExamSharesTest do
  use CaptainHomework.DataCase, async: false
  import CaptainHomework.Fixtures
  alias CaptainHomework.{ExamShares, Exams, Study}
  alias CaptainHomework.Study.{Exam, ExamShare}

  setup do
    old = Application.fetch_env!(:captain_homework, :ai_provider)
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.TestAI)
    on_exit(fn -> Application.put_env(:captain_homework, :ai_provider, old) end)
    p = profile()
    l = lesson(p)
    %{profile: p, lesson: l, exam: exam(l)}
  end

  test "links use independent random capabilities and only completed corrections can be shared",
       %{profile: p, exam: e} do
    assert {:error, :unavailable} = ExamShares.create(p.id, e.id, "correction")
    assert {:error, :unavailable} = ExamShares.create(p.id, e.id, "unknown")
    assert_raise Ecto.NoResultsError, fn -> ExamShares.create(profile("Bob").id, e.id, "fill") end
    assert {:ok, share, token} = ExamShares.create(p.id, e.id, "fill")
    assert byte_size(Base.url_decode64!(token, padding: false)) == 32
    assert share.token_hash == :crypto.hash(:sha256, token)
    assert DateTime.diff(share.expires_at, share.inserted_at, :day) in [6, 7]
    assert {:ok, _, another} = ExamShares.create(p.id, e.id, "fill")
    refute token == another
    assert {:error, :unavailable} = ExamShares.fetch(e.id)
    assert {:error, :unavailable} = ExamShares.fetch(ExamShares.token())
  end

  test "each visitor gets a resumable blank copy isolated from the family and other visitors", %{
    profile: p,
    lesson: l,
    exam: e
  } do
    {:ok, _} = Exams.submit(p.id, e.id, %{"q1" => "réponse originale"}, sync: true)
    {:ok, _, token} = ExamShares.create(p.id, e.id, "fill")
    {:ok, _, first} = ExamShares.open(token, "first")
    {:ok, _, second} = ExamShares.open(token, "second")
    assert first.status == "in_progress"
    assert first.answers == %{}
    assert first.corrections == %{}
    assert first.score == nil
    assert first.id != second.id
    assert first.questions == e.questions
    assert {:ok, _, %{id: id}} = ExamShares.open(token, "first")
    assert id == first.id

    scope = {:shared, token, "first"}
    {:ok, _} = Study.save_answers(scope, first.id, %{"q1" => "quart"})
    assert_raise Ecto.NoResultsError, fn -> Study.get_exam!(scope, second.id) end
    assert_raise Ecto.NoResultsError, fn -> Study.get_exam!(scope, e.id) end
    assert_raise Ecto.NoResultsError, fn -> Study.get_exam!(p.id, first.id) end
    assert Study.get_exam!({:shared, token, "second"}, second.id).answers == %{}
    assert Study.exam_counts(p.id)[l.subject] == 1
    assert Enum.map(Study.get_lesson!(p.id, l.id).exams, & &1.id) == [e.id]
    assert Enum.map(hd(Study.lessons(p.id, l.subject)).exams, & &1.id) == [e.id]

    assert {:ok, %{status: "completed", score: 5.0}} =
             Exams.submit(scope, first.id, %{"q1" => "quart"}, sync: true)

    assert Study.get_exam!(p.id, e.id).answers == %{"q1" => "réponse originale"}
    assert Study.get_exam!(p.id, e.id).score == 20.0
  end

  test "expiry rejects reads and writes and deleting the original revokes all links", %{
    profile: p,
    exam: e
  } do
    {:ok, share, token} = ExamShares.create(p.id, e.id, "fill")
    {:ok, _, attempt} = ExamShares.open(token, "visitor")
    Repo.update!(Ecto.Changeset.change(share, expires_at: DateTime.add(DateTime.utc_now(), -1)))
    assert {:error, :unavailable} = ExamShares.open(token, "visitor")

    assert_raise Ecto.NoResultsError, fn ->
      Study.save_answers({:shared, token, "visitor"}, attempt.id, %{})
    end

    {:ok, _} = Study.delete_exam(p.id, e.id)
    assert Repo.get(ExamShare, share.id) == nil
    assert Repo.get(Exam, attempt.id) == nil
  end

  test "correction links show the current completed copy and cannot submit answers", %{
    profile: p,
    exam: e
  } do
    {:ok, _} = Exams.submit(p.id, e.id, %{"q1" => "quart"}, sync: true)
    {:ok, share, token} = ExamShares.create(p.id, e.id, "correction")
    assert share.expires_at == nil
    assert {:ok, _, copy} = ExamShares.open(token, "visitor")
    assert copy.id == e.id
    assert copy.score == 5.0

    assert {:error, :already_submitted} =
             Study.save_answers({:shared, token, "visitor"}, e.id, %{"q1" => "faux"})
  end

  test "deleting the source also removes photos belonging to its shared attempts", %{
    profile: p,
    lesson: l
  } do
    e = exam(l, [question("photo", "photo")])
    {:ok, _, token} = ExamShares.create(p.id, e.id, "fill")
    {:ok, _, attempt} = ExamShares.open(token, "visitor")
    key = "shared-photo-#{Ecto.UUID.generate()}.png"
    path = CaptainHomework.Uploads.path(key)
    File.mkdir_p!(CaptainHomework.Uploads.directory())
    File.write!(path, "photo")
    on_exit(fn -> File.rm(path) end)
    asset = %{"id" => Ecto.UUID.generate(), "storage_key" => key, "content_type" => "image/png"}
    Repo.update!(Ecto.Changeset.change(attempt, answers: %{"photo" => asset}))

    assert {:ok, _} = Study.delete_exam(p.id, e.id)
    refute File.exists?(path)
    assert Repo.get(Exam, attempt.id) == nil
  end
end
