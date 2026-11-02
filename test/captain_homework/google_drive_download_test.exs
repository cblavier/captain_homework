defmodule CaptainHomework.GoogleDriveDownloadTest do
  use ExUnit.Case, async: true
  alias CaptainHomework.Resources.{Download, GoogleDrive}
  @id "1QZ8WSEHVxrcKiNeAoJxRGOMt1E-1-Kce"

  test "normalizes public file viewer and legacy share URLs" do
    for url <- [
          "https://drive.google.com/file/d/#{@id}/view?usp=sharing",
          "https://drive.google.com/file/d/#{@id}/preview",
          "https://drive.google.com/open?id=#{@id}",
          "https://drive.google.com/uc?id=#{@id}&export=download",
          "https://drive.usercontent.google.com/download?id=#{@id}&export=download"
        ] do
      assert {:ok, download, @id} = GoogleDrive.prepare(URI.parse(url))
      uri = URI.parse(download)
      assert uri.scheme == "https"
      assert uri.host == "drive.usercontent.google.com"
      assert uri.path == "/download"

      assert URI.decode_query(uri.query) == %{
               "id" => @id,
               "export" => "download",
               "confirm" => "t"
             }
    end
  end

  test "preserves the Google resource key but does not forward unrelated parameters" do
    assert {:ok, download, @id} =
             GoogleDrive.prepare(
               URI.parse(
                 "https://drive.google.com/file/d/#{@id}/view?resourcekey=key-123&redirect=https://evil.example"
               )
             )

    query = download |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert query["resourcekey"] == "key-123"
    refute Map.has_key?(query, "redirect")
  end

  test "Drive folders and malformed IDs are not imported as HTML" do
    for path <- ["/drive/folders/#{@id}", "/file/d/short/view", "/file/d/../../view", "/open"] do
      assert {:error, _} = GoogleDrive.prepare(URI.parse("https://drive.google.com#{path}"))
    end
  end

  test "unrelated hosts are never rewritten and credentials remain rejected" do
    assert :not_drive = GoogleDrive.prepare(URI.parse("https://example.com/file/d/#{@id}/view"))

    assert :not_drive =
             GoogleDrive.prepare(
               URI.parse("https://drive.google.com.evil.example/file/d/#{@id}/view")
             )

    assert {:error, _} =
             Download.fetch("https://user:password@drive.google.com/file/d/#{@id}/view")
  end

  test "bounded confirmation only downloads the same file from Google's fixed endpoint" do
    html = """
    <form id="download-form" action="https://drive.usercontent.google.com/download">
      <input type="hidden" name="id" value="#{@id}">
      <input type="hidden" name="export" value="download">
      <input type="hidden" name="confirm" value="t">
      <input type="hidden" name="uuid" value="confirmation-id">
      <input type="hidden" name="ignored" value="do-not-forward">
    </form>
    """

    assert {:ok, url} = GoogleDrive.confirmation(html, @id)
    assert URI.parse(url).host == "drive.usercontent.google.com"
    query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert query["uuid"] == "confirmation-id"
    refute Map.has_key?(query, "ignored")
    assert {:error, _} = GoogleDrive.confirmation(String.replace(html, @id, "another-file"), @id)

    assert {:error, _} =
             GoogleDrive.confirmation(
               String.replace(
                 html,
                 "https://drive.usercontent.google.com/download",
                 "http://127.0.0.1/admin"
               ),
               @id
             )

    assert {:error, _} = GoogleDrive.confirmation("<html>Sign in to Google</html>", @id)
    assert {:error, _} = GoogleDrive.confirmation(String.duplicate("x", 1_000_001), @id)
  end
end
