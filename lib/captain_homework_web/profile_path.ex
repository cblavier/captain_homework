defmodule CaptainHomeworkWeb.ProfilePath do
  alias CaptainHomework.Study

  def slug(profile) do
    name =
      profile.name
      |> String.downcase()
      |> String.normalize(:nfd)
      |> String.replace(~r/\p{Mn}/u, "")
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")

    if name == "", do: "enfant", else: name
  end

  def matches?(profile, value) do
    index = String.replace_prefix(profile.environment_key, "HOMEWORK_CHILD_", "")
    value in [slug(profile), "#{slug(profile)}-#{index}"]
  end

  def find(slug), do: Enum.find(Study.profiles(), &matches?(&1, slug))

  def child_path(nil, path), do: path
  def child_path(profile, "/"), do: "/#{slug(profile)}"
  def child_path(profile, path), do: "/#{slug(profile)}#{path}"
end
