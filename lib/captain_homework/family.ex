defmodule CaptainHomework.Family do
  @moduledoc "Family members configured with numbered HOMEWORK_CHILD environment variables."

  def members do
    Application.get_env(:captain_homework, :family_env, %{}) |> from_env()
  end

  def from_env(env) do
    env
    |> Enum.flat_map(fn {key, value} ->
      case Regex.run(~r/^HOMEWORK_CHILD_([1-9][0-9]*)_FIRST_NAME$/, key) do
        [_, index] ->
          name = value |> String.trim() |> String.normalize(:nfc)
          prefix = "HOMEWORK_CHILD_#{index}"

          cond do
            name == "" ->
              []

            String.length(name) > 40 ->
              raise ArgumentError, "#{key} must be at most 40 characters"

            true ->
              [
                %{
                  key: prefix,
                  index: String.to_integer(index),
                  name: name,
                  avatar: avatar(env[prefix <> "_AVATAR_BASE64"]),
                  theme: env["PRONOTE_CHILD_#{index}_THEME"]
                }
              ]
          end

        _ ->
          []
      end
    end)
    |> Enum.sort_by(& &1.index)
    |> Enum.with_index()
    |> Enum.map(fn {member, index} ->
      theme =
        if member.theme in ["blue", "green"],
          do: member.theme,
          else: if(rem(index, 2) == 0, do: "blue", else: "green")

      %{member | theme: theme}
    end)
  end

  def normalize(name), do: name |> String.trim() |> String.downcase() |> String.normalize(:nfc)

  defp avatar(encoded) when is_binary(encoded) and byte_size(encoded) <= 262_144 do
    with {:ok, bytes} <- Base.decode64(encoded, ignore: :whitespace),
         type when not is_nil(type) <- image_type(bytes) do
      "data:#{type};base64,#{Base.encode64(bytes)}"
    else
      _ -> nil
    end
  end

  defp avatar(_), do: nil
  defp image_type(<<137, 80, 78, 71, 13, 10, 26, 10, _::binary>>), do: "image/png"
  defp image_type(<<255, 216, 255, _::binary>>), do: "image/jpeg"
  defp image_type(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: "image/webp"
  defp image_type(_), do: nil
end
