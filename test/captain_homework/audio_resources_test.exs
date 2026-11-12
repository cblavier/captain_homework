defmodule CaptainHomework.AudioResourcesTest do
  use CaptainHomework.DataCase, async: false
  import CaptainHomework.Fixtures
  alias CaptainHomework.{Repo, Resources, Study, Uploads}
  alias CaptainHomework.Resources.Audio

  setup do
    old = Application.fetch_env!(:captain_homework, :ai_provider)
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.TestAI)
    dir = Path.join(System.tmp_dir!(), "audio-test-#{Ecto.UUID.generate()}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      Application.put_env(:captain_homework, :ai_provider, old)
      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  test "MP3 and MP4 retain only transcript pages usable as question sources", %{dir: dir} do
    for extension <- ["mp3", "mp4"] do
      input = media(dir, extension)
      l = lesson(profile())

      assert {:ok, resource} =
               Resources.create_upload(l.profile_id, l.id, input, "cours.#{extension}")

      original = Uploads.path(resource.storage_key)
      assert {:ok, ready} = Resources.process(resource.id)
      assert ready.status == "ready", inspect(ready.error)
      assert ready.content_type == "text/plain"
      assert ready.filename == "cours.txt"
      refute File.exists?(original)
      assert Uploads.read(ready) == "Texte reconnu sur la photo."
      updated = Study.get_lesson!(l.profile_id, l.id)
      assert [page] = updated.pages
      assert page.kind == "resource"
      assert page.content_type == "text/plain"
      assert page.text == Uploads.read(ready)
      assert page in CaptainHomework.Exams.Illustrations.content_pages(updated)
      assert CaptainHomework.Exams.Illustrations.sources(updated) == []
      Resources.delete(l.profile_id, resource.id)
      refute File.exists?(Uploads.path(page.storage_key))
    end
  end

  test "failed transcription keeps input for retry, then removes it", %{dir: dir} do
    l = lesson(profile())
    {:ok, resource} = Resources.create_upload(l.profile_id, l.id, media(dir, "mp3"), "cours.mp3")
    key = Application.get_env(:captain_homework, :openai_api_key)
    on_exit(fn -> Application.put_env(:captain_homework, :openai_api_key, key) end)
    Application.put_env(:captain_homework, :openai_api_key, nil)
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.AI.OpenAI)
    assert {:ok, %{status: "error"}} = Resources.process(resource.id)
    assert File.exists?(Uploads.path(resource.storage_key))
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.TestAI)
    assert {:ok, _} = Resources.retry(l.profile_id, resource.id)
    assert {:ok, %{status: "ready"}} = Resources.process(resource.id)
    refute File.exists?(Uploads.path(resource.storage_key))
    assert length(Study.get_lesson!(l.profile_id, l.id).pages) == 1
    Resources.delete(l.profile_id, resource.id)
  end

  test "video without audio fails instead of importing images", %{dir: dir} do
    path = Path.join(dir, "silent.mp4")

    {_, 0} =
      System.cmd("ffmpeg", [
        "-v",
        "error",
        "-f",
        "lavfi",
        "-i",
        "color=c=blue:s=16x16:d=0.2",
        "-an",
        "-y",
        path
      ])

    l = lesson(profile())
    {:ok, resource} = Resources.create_upload(l.profile_id, l.id, path, "silent.mp4")
    assert {:ok, %{status: "error", error: message}} = Resources.process(resource.id)
    assert message =~ "audio"
    assert Study.get_lesson!(l.profile_id, l.id).pages == []
    Resources.delete(l.profile_id, resource.id)
  end

  test "YouTube links use canonical individual video URLs" do
    l = lesson(profile())

    for url <- [
          "https://youtu.be/abcdefghijk?t=3",
          "https://www.youtube.com/watch?v=abcdefghijk&list=ignored",
          "https://m.youtube.com/shorts/abcdefghijk"
        ] do
      assert {:ok, r} = Resources.create_url(l.profile_id, l.id, url)
      assert r.content_type == "application/x-youtube"
      assert r.source_url == "https://www.youtube.com/watch?v=abcdefghijk"
      assert r.storage_key == nil
    end

    assert {:error, _} =
             Resources.create_url(l.profile_id, l.id, "https://youtube.com/playlist?list=abc")

    assert :not_youtube =
             Audio.youtube_url(URI.parse("https://youtube.com.evil.test/watch?v=abcdefghijk"))

    assert {:error, _} =
             Resources.create_url(
               l.profile_id,
               l.id,
               "https://user:pass@youtube.com/watch?v=abcdefghijk"
             )
  end

  test "retry after transcription does not transcribe the stored text again", %{dir: dir} do
    l = lesson(profile())
    {:ok, resource} = Resources.create_upload(l.profile_id, l.id, media(dir, "mp3"), "cours.mp3")
    assert {:ok, transcript} = Audio.transcribe(resource)
    transcript |> Ecto.Changeset.change(status: "error") |> Repo.update!()
    {:ok, _} = Resources.retry(l.profile_id, resource.id)
    assert {:ok, %{status: "ready"}} = Resources.process(resource.id)
    assert [page] = Study.get_lesson!(l.profile_id, l.id).pages
    assert page.text == Uploads.read(transcript)
    Resources.delete(l.profile_id, resource.id)
  end

  defp media(dir, extension) do
    path = Path.join(dir, "input.#{extension}")

    {_, 0} =
      System.cmd("ffmpeg", [
        "-v",
        "error",
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=440:duration=0.2",
        "-y",
        path
      ])

    path
  end
end
