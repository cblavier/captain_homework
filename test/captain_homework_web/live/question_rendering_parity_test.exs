defmodule CaptainHomeworkWeb.QuestionRenderingParityTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CaptainHomework.Fixtures
  alias CaptainHomework.{Repo, Study}
  alias CaptainHomeworkWeb.QuestionTypeComponents

  @formats [
    {"definition", "Définition", "short_text", "text"},
    {"mcq", "QCM", "single_choice", "text"},
    {"cloze", "Texte à trous", "cloze", "text"},
    {"reading", "Compréhension", "long_text", "document"},
    {"long", "Réponse rédigée", "long_text", "text"},
    {"diagram", "Schéma", "legends", "image"},
    {"ordering", "Classement chronologique", "ordering", "text"},
    {"listening", "Compréhension orale", "short_text", "audio"},
    {"photo", "Dessin en photo", "photo", "none"}
  ]

  for {format, label, response, content} <- @formats,
      mode <- if(format == "photo", do: ["classic"], else: ["classic", "flashcard"]) do
    @format format
    @label label
    @response response
    @content content
    @mode mode
    test "#{format} has matching preview and #{@mode} content and fields", %{conn: conn} do
      l = lesson(profile())

      example = %{
        "prompt" => "Observe et réponds.",
        "text" => "Premier élément\nDeuxième élément\nTroisième élément",
        "document" => "Le document à lire.",
        "options" => ["A", "B", "C"],
        "slots" => ["Repère 1", "Repère 2", "Repère 3"]
      }

      type = %Study.QuestionDefinition{
        name: @label,
        subjects: ["svt"],
        modes: [@mode],
        response_kind: @response,
        content_kind: @content,
        content_presence: if(@content == "none", do: "none", else: "required"),
        instruction_kind: "dynamic",
        help_classic: "Une aide commune.",
        help_flashcard: "Une aide commune.",
        example: %{"audio" => "english"}
      }

      q =
        question("q1", @format)
        |> Map.merge(%{
          "points" => 1,
          "prompt" => example["prompt"],
          "help" => "Une aide commune.",
          "text" =>
            cond do
              @format == "ordering" -> ""
              @content == "document" -> example["document"]
              @content == "text" -> example["text"]
              true -> ""
            end,
          "options" =>
            if(@format == "ordering",
              do: String.split(example["text"], "\n"),
              else: example["options"]
            ),
          "slots" => example["slots"],
          "images" =>
            if(@content == "image",
              do: [%{"id" => "sample", "storage_key" => "sample.svg"}],
              else: []
            )
        })

      q = if @format == "listening", do: Map.put(q, "audio", %{"id" => "sample"}), else: q
      control = exam(l, [q]) |> Ecto.Changeset.change(format: @mode) |> Repo.update!()
      {:ok, view, _} = live(conn, "/alice/controles/#{control.id}")

      preview =
        render_component(&QuestionTypeComponents.question_preview/1,
          type: type,
          mode: @mode,
          subject: "svt",
          example: example
        )

      actual = render(view)

      assert signature(preview, ".question-content") == signature(actual, ".question-content")

      assert signature(
               preview,
               ".question-response input:not([type=hidden]):not([type=file]), .question-response textarea"
             ) ==
               signature(
                 actual,
                 ".question-response input:not([type=hidden]):not([type=file]), .question-response textarea"
               )

      for selector <- [
            ".question-response .options",
            ".question-response .slot-inputs",
            ".photo-response-empty"
          ] do
        assert signature(preview, selector) == signature(actual, selector)
      end
    end
  end

  test "preview selections and drafts survive switching modes", %{conn: conn} do
    profile()
    {:ok, _} = CaptainHomework.QuestionDefinitions.seed!()

    for {kind, params, selector} <- [
          {"single_choice", %{"choice" => "Lascaux et Chauvet"},
           ".option.selected input[checked]"},
          {"short_text", %{"text" => "Mon brouillon"}, "input[value='Mon brouillon']"}
        ] do
      type =
        Enum.find(
          CaptainHomework.QuestionDefinitions.list(),
          &(&1.response_kind == kind and "classic" in &1.modes and "flashcard" in &1.modes)
        )

      {:ok, view, _} = live(conn, "/alice/parametres/types/#{type.id}")
      view |> form("#preview-response-form", answer: params) |> render_change()
      assert has_element?(view, "#preview-response-form #{selector}")
      view |> form("#type-preview-mode", mode: "classic") |> render_change()
      assert has_element?(view, "#preview-response-form #{selector}")
    end
  end

  # Ignore transport-specific identifiers and URLs; compare visible structure,
  # content, classes and the complete field configuration instead.
  defp signature(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.filter(selector)
    |> LazyHTML.to_tree(skip_whitespace_nodes: true)
    |> Enum.map(&normalize/1)
  end

  defp normalize({tag, attrs, children}) do
    attrs =
      Enum.reject(attrs, fn {key, _} ->
        key in ~w(id name for src alt data-phx-id data-phx-component phx-hook phx-update data-phx-upload-ref data-phx-active-refs data-phx-done-refs data-phx-preflighted-refs)
      end)
      |> Enum.sort()

    {tag, attrs, Enum.map(children, &normalize/1)}
  end

  defp normalize(text) when is_binary(text), do: String.trim(text)
  defp normalize(other), do: other
end
