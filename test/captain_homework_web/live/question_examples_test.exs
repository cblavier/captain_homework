defmodule CaptainHomeworkWeb.QuestionExamplesTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CaptainHomework.Fixtures
  alias CaptainHomework.{QuestionDefinitions, Uploads}

  defp example_type do
    profile()
    {:ok, _} = QuestionDefinitions.seed!()
    type = Enum.find(QuestionDefinitions.list(), &(&1.name == "Analyse de document"))
    key = "example-#{Ecto.UUID.generate()}.png"
    File.mkdir_p!(Uploads.directory())
    File.write!(Uploads.path(key), "example image")
    on_exit(fn -> File.rm(Uploads.path(key)) end)

    example = %{
      "prompt" => "Observe le village.",
      "document" => "",
      "images" => [%{"id" => "village", "storage_key" => key, "content_type" => "image/png"}],
      "options" => ["A", "B"],
      "slots" => ["1", "2"]
    }

    {:ok, type} = QuestionDefinitions.save(type, %{"example" => example})
    type
  end

  test "document image and example metadata survive editing and saving", %{conn: conn} do
    type = example_type()
    {:ok, view, _} = live(conn, "/alice/parametres/types/#{type.id}")

    assert has_element?(
             view,
             "#question-image-preview-village[src='/parametres/types/#{type.id}/exemples/village']"
           )

    refute has_element?(view, "#question-type-preview .reading-text")
    view |> form("#type-example", example: %{prompt: "Décris le village."}) |> render_change()
    view |> form("#type-editor") |> render_submit()
    saved = QuestionDefinitions.get!(type.id).example
    assert saved == Map.put(type.example, "prompt", "Décris le village.") |> Map.put("text", "")
  end

  test "example assets are served only when referenced by the type", %{conn: conn} do
    type = example_type()
    response = get(conn, "/parametres/types/#{type.id}/exemples/village")
    assert response(response, 200) == "example image"
    assert get_resp_header(response, "cache-control") == ["private, no-store"]
    assert get(conn, "/parametres/types/#{type.id}/exemples/unknown").status == 404
  end

  @tag :unauthenticated
  test "example assets require authentication", %{conn: conn} do
    type = example_type()

    assert get(conn, "/parametres/types/#{type.id}/exemples/village") |> redirected_to() ==
             "/connexion"
  end

  @tag account: "child-1"
  test "example assets require parent access", %{conn: conn} do
    type = example_type()
    assert get(conn, "/parametres/types/#{type.id}/exemples/village").status == 404
  end
end
