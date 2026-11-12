defmodule CaptainHomework.ProviderErrorTest do
  use ExUnit.Case, async: true
  alias CaptainHomework.AI.ProviderError

  test "retains the schema rejection and request identifier without the response body" do
    response =
      Req.Response.new(
        status: 400,
        headers: [{"x-request-id", "req_test"}],
        body: %{
          "error" => %{
            "code" => "invalid_json_schema",
            "type" => "invalid_request_error",
            "param" => "text.format.schema",
            "message" => "Invalid schema: missing required property"
          },
          "input" => "private lesson"
        }
      )

    assert ProviderError.details(response) == %{
             "http_status" => 400,
             "request_id" => "req_test",
             "code" => "invalid_json_schema",
             "type" => "invalid_request_error",
             "param" => "text.format.schema",
             "message" => "Invalid schema: missing required property"
           }
  end

  test "omits arbitrary provider messages and redacts credentials in schema messages" do
    response =
      Req.Response.new(
        status: 401,
        body: %{
          "error" => %{
            "code" => "invalid_api_key",
            "message" => "Incorrect API key sk-secret",
            "param" => "private lesson"
          }
        }
      )

    refute Map.has_key?(ProviderError.details(response), "message")
    assert ProviderError.details(response)["param"] == nil

    response = %{
      response
      | body: %{
          "error" => %{
            "code" => "invalid_json_schema",
            "message" => "Invalid schema sk-secret Bearer secret"
          }
        }
    }

    assert ProviderError.details(response)["message"] ==
             "Invalid schema [REDACTED] Bearer [REDACTED]"
  end

  test "handles non-JSON and malformed errors" do
    for body <- ["unavailable", %{"error" => "unavailable"}, %{"error" => nil}] do
      assert ProviderError.details(Req.Response.new(status: 502, body: body))["http_status"] ==
               502
    end
  end
end
