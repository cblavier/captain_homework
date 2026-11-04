defmodule CaptainHomework.AITraceTest do
  use CaptainHomework.DataCase, async: false
  alias CaptainHomework.AI.{Call, Trace}

  test "records usage and request identity, with scoped generation context" do
    exam_id = Ecto.UUID.generate()

    result =
      {:ok,
       Req.Response.new(
         status: 200,
         headers: %{"x-request-id" => ["req_test"]},
         body: %{
           "status" => "completed",
           "usage" => %{
             "input_tokens" => 100,
             "input_tokens_details" => %{"cached_tokens" => 60},
             "output_tokens" => 40,
             "output_tokens_details" => %{"reasoning_tokens" => 15},
             "total_tokens" => 140
           },
           "output" => [%{"text" => "private answer"}]
         }
       )}

    assert result ==
             Trace.with_exam(exam_id, fn ->
               Trace.with_stage("planning", fn -> Trace.request(body(), fn -> result end) end)
             end)

    call = Repo.one!(Call)
    assert call.exam_id == exam_id
    assert call.stage == "planning"
    assert call.model == "gpt-5.4"
    assert call.status == "completed"
    assert call.request_id == "req_test"
    assert call.duration_ms >= 0
    assert call.image_count == 1
    assert call.input_tokens == 100
    assert call.output_tokens == 40
    assert call.cached_tokens == 60
    assert call.reasoning_tokens == 15
    assert call.total_tokens == 140
    refute inspect(call) =~ "private"

    Trace.request(body(), fn -> {:error, :timeout} end)
    other = Repo.one!(from c in Call, where: c.id != ^call.id)
    assert is_nil(other.exam_id)
    assert other.stage == "audit"
    assert other.status == "transport_error"
  end

  test "records incomplete responses and exceptions without changing their result" do
    response =
      {:ok,
       Req.Response.new(
         status: 200,
         body: %{
           "status" => "incomplete",
           "incomplete_details" => %{"reason" => "max_output_tokens"}
         }
       )}

    assert Trace.request(body(), fn -> response end) == response
    assert Repo.one!(Call).incomplete_reason == "max_output_tokens"

    assert_raise RuntimeError, "private exception", fn ->
      Trace.with_stage("repair", fn ->
        Trace.request(body(), fn -> raise "private exception" end)
      end)
    end

    assert Repo.exists?(from c in Call, where: c.stage == "repair" and c.status == "exception")
    refute inspect(Repo.all(Call)) =~ "private"
  end

  test "handles the atom keys used by the provider request" do
    request = %{
      model: "gpt-5.4",
      max_output_tokens: 12000,
      input: [%{content: [%{type: "input_image", image_url: "private"}]}],
      text: %{format: %{schema: %{"properties" => %{"entries" => %{}}}}}
    }

    Trace.request(request, fn -> {:error, :timeout} end)
    call = Repo.one!(Call)
    assert call.model == "gpt-5.4"
    assert call.image_count == 1
    assert call.max_output_tokens == 12000
    assert call.stage == "catalogue"
  end

  test "reports the actual request stage before calling the provider and restores the callback" do
    request = %{
      text: %{
        format: %{schema: %{"properties" => %{"questions" => %{"properties" => %{"q2" => %{}}}}}}
      }
    }

    parent = self()

    Trace.with_progress(fn stage, count -> send(parent, {:started, stage, count}) end, fn ->
      Trace.with_stage("repair", fn ->
        Trace.request(request, fn ->
          assert_received {:started, "repair", 1}
          {:error, :timeout}
        end)
      end)
    end)

    Trace.request(request, fn -> {:error, :timeout} end)
    refute_received {:started, _, _}
  end

  defp body do
    %{
      "model" => "gpt-5.4",
      "max_output_tokens" => 8000,
      "text" => %{"format" => %{"schema" => %{"properties" => %{"reviews" => %{}}}}},
      "input" => [
        %{
          "content" => [
            %{"type" => "input_text", "text" => "private prompt"},
            %{"type" => "input_image", "image_url" => "data:image/png;base64,private"}
          ]
        }
      ]
    }
  end
end
