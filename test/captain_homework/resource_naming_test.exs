defmodule CaptainHomework.ResourceNamingTest do
  use ExUnit.Case, async: true
  alias CaptainHomework.Resources.Naming

  test "prefers the decoded social title over the generic page title" do
    assert Naming.html_title(
             ~s(<title>Generic</title><meta property="og:title" content="Tom &amp; his family">)
           ) == "Tom & his family"
  end

  test "uses the page title and keeps punctuation" do
    assert Naming.html_title("<title>Chapter 1. Introduction</title>") ==
             "Chapter 1. Introduction"

    assert Naming.html_title("<html></html>") == nil
  end

  test "removes only the last filename extension" do
    assert Naming.filename_title("My lesson.v2.pdf") == "My lesson.v2"
  end

  test "preserves a manually chosen title" do
    assert Naming.title(%{title: "Mon titre"}) == "Mon titre"
  end
end
