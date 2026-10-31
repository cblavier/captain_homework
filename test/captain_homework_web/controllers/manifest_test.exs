defmodule CaptainHomeworkWeb.ManifestTest do
  use CaptainHomeworkWeb.ConnCase, async: true

  test "manifest and installation icons are public", %{conn: conn} do
    response = get(conn, "/manifest.webmanifest")
    manifest = response |> response(200) |> Jason.decode!()
    assert manifest["name"] == "Captain Homework"
    assert manifest["display"] == "standalone"
    assert manifest["scope"] == "/"
    assert manifest["theme_color"] == "#2c4569"
    assert get_resp_header(response, "set-cookie") == []

    for icon <- manifest["icons"] do
      image = get(build_conn(), icon["src"])
      assert response(image, 200) =~ <<137, 80, 78, 71>>
    end
  end

  test "login declares standalone mode, icons and correctly sized launch images", %{conn: conn} do
    document = conn |> get("/connexion") |> html_response(200) |> LazyHTML.from_document()

    assert LazyHTML.attribute(
             LazyHTML.query(document, "meta[name=apple-mobile-web-app-capable]"),
             "content"
           ) == ["yes"]

    assert LazyHTML.attribute(LazyHTML.query(document, "link[rel=manifest]"), "href") == [
             "/manifest.webmanifest"
           ]

    links = LazyHTML.query(document, "link[rel=apple-touch-startup-image]")
    paths = LazyHTML.attribute(links, "href")
    assert length(paths) == 44

    for path <- paths do
      [_, w, h] = Regex.run(~r/launch-(\d+)x(\d+)\.png/, path)

      <<_signature::binary-size(16), width::32, height::32, _::binary>> =
        File.read!("priv/static" <> path)

      assert width == String.to_integer(w)
      assert height == String.to_integer(h)
    end

    assert get(build_conn(), "/images/brand/captain_homework-icon-180.png") |> response(200)
  end

  test "production manifest digest URLs bypass authentication" do
    body = File.read!("priv/static/manifest.webmanifest")
    filename = "manifest-test-#{System.unique_integer([:positive])}.webmanifest"
    path = Path.join("priv/static", filename)
    File.write!(path, body)
    on_exit(fn -> File.rm(path) end)
    conn = get(build_conn(), "/" <> filename)
    assert response(conn, 200) == body
    assert get_resp_header(conn, "set-cookie") == []
  end
end
