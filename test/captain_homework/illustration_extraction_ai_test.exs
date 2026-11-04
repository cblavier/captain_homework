defmodule CaptainHomework.IllustrationExtractionAITest do
  use CaptainHomework.DataCase, async: false
  alias CaptainHomework.AI.OpenAI

  setup :verify_requests

  defp verify_requests(context), do: Req.Test.verify_on_exit!(context)

  setup do
    keys = [:openai_api_key, :openai_request_options, :openai_illustration_model, :openai_model]
    previous = Map.new(keys, &{&1, Application.fetch_env(:captain_homework, &1)})
    Application.put_env(:captain_homework, :openai_api_key, "test-only-key")
    Application.put_env(:captain_homework, :openai_illustration_model, "gpt-6-astra")
    Application.put_env(:captain_homework, :openai_model, "regular-model")
    Application.put_env(:captain_homework, :openai_request_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:captain_homework, key, value)
        {key, :error} -> Application.delete_env(:captain_homework, key)
      end)
    end)
  end

  test "the vision request includes the source, the exact count and the extraction instructions" do
    expected = [
      %{"x" => 0, "y" => 0, "width" => 1000, "height" => 500},
      %{"x" => 0, "y" => 500, "width" => 1000, "height" => 500}
    ]

    Req.Test.expect(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(raw)
      schema = get_in(request, ["text", "format", "schema", "properties", "regions"])
      assert schema["minItems"] == 2
      assert schema["maxItems"] == 2
      assert Enum.sort(schema["items"]["required"]) == ~w(bottom left right top)
      [text, image] = hd(request["input"])["content"]
      assert text["text"] =~ "Chaque exercice commence par son numéro en orange."
      assert text["text"] =~ "pixels originaux"
      assert image["image_url"] == "data:image/png;base64," <> Base.encode64("image-test")
      assert image["detail"] == "original"
      assert request["model"] == "gpt-6-astra"
      assert request["reasoning"]["effort"] == "medium"
      assert request["store"] == false

      respond(conn, regions())
    end)

    assert {:ok, ^expected} =
             OpenAI.extract_illustrations(
               "image-test",
               "image/png",
               2,
               "Chaque exercice commence par son numéro en orange."
             )
  end

  test "the extraction model can be configured independently of OCR" do
    Application.put_env(:captain_homework, :openai_illustration_model, "extraction-model")

    Req.Test.expect(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw)["model"] == "extraction-model"
      respond(conn, regions())
    end)

    assert {:ok, _} = OpenAI.extract_illustrations("image-test", "image/png", 2, "")

    Req.Test.expect(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(raw)
      assert request["model"] == "regular-model"
      [_, image] = hd(request["input"])["content"]
      assert image["detail"] == "high"

      Req.Test.json(conn, %{
        "status" => "completed",
        "output" => [%{"content" => [%{"type" => "output_text", "text" => ~s({"text":"OCR"})}]}]
      })
    end)

    assert {:ok, "OCR"} = OpenAI.transcribe("image-test", "image/png")
  end

  test "invalid coordinates trigger one fresh detection before returning crops" do
    for invalid <- [
          [],
          [%{}, nil],
          [hd(regions()), hd(regions())],
          [hd(regions()), %{"left" => 0, "top" => 500, "right" => 1000, "bottom" => 1500}],
          [hd(regions()), %{"left" => 800, "top" => 500, "right" => 200, "bottom" => 1000}],
          [hd(regions()), %{"left" => 0, "top" => 500, "right" => 1000, "bottom" => 500}]
        ] do
      Req.Test.expect(__MODULE__, &respond(&1, invalid))

      Req.Test.expect(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(raw)
        [text, image] = hd(request["input"])["content"]
        assert text["text"] =~ "La première détection a été rejetée"
        assert text["text"] =~ "Exercices 11 et 12"
        assert image["image_url"] == "data:image/png;base64," <> Base.encode64("image-test")
        respond(conn, regions())
      end)

      assert {:ok, crops} =
               OpenAI.extract_illustrations("image-test", "image/png", 2, "Exercices 11 et 12")

      assert Enum.at(crops, 1) == %{"x" => 0, "y" => 500, "width" => 1000, "height" => 500}
      Req.Test.verify!(__MODULE__)
    end
  end

  test "two invalid detections stop without returning invalid crops" do
    Req.Test.expect(__MODULE__, 2, &respond(&1, [hd(regions()), hd(regions())]))

    assert {:error, message} = OpenAI.extract_illustrations("image-test", "image/png", 2, "")
    assert message =~ "L’IA n’a pas réussi"
  end

  test "an API error is returned without a second paid request" do
    Req.Test.expect(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{"error" => %{}})
    end)

    assert {:error, message} = OpenAI.extract_illustrations("image-test", "image/png", 2, "")
    assert message =~ "quota"
  end

  defp regions do
    [
      %{"left" => 0, "top" => 0, "right" => 1000, "bottom" => 500},
      %{"left" => 0, "top" => 500, "right" => 1000, "bottom" => 1000}
    ]
  end

  defp respond(conn, regions) do
    Req.Test.json(conn, %{
      "status" => "completed",
      "output" => [
        %{
          "content" => [
            %{"type" => "output_text", "text" => Jason.encode!(%{"regions" => regions})}
          ]
        }
      ]
    })
  end
end
