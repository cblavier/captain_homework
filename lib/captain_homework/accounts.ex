defmodule CaptainHomework.Accounts do
  @moduledoc "PIN accounts shared with Captain Notes; no Pronote credentials are needed."

  def all do
    specs()
    |> Enum.filter(fn account ->
      is_binary(account.pin) and Regex.match?(~r/\A[0-9]{8}\z/, account.pin) and
        account.label not in [nil, ""]
    end)
    |> Enum.map(&Map.take(&1, [:id, :role, :label, :profile_key]))
  end

  def get(id), do: Enum.find(all(), &(&1.id == id))
  def pin(id), do: case_spec(id, & &1.pin)
  def fingerprint(id), do: case_spec(id, &:crypto.hash(:sha256, :erlang.term_to_binary(&1)))

  def parent?(%{role: :parent}), do: true
  def parent?(_), do: false

  def profiles(account) do
    Enum.filter(CaptainHomework.Study.profiles(), &profile_allowed?(account, &1))
  end

  def profile_allowed?(%{role: :child, profile_key: key}, profile),
    do: profile != nil and profile.environment_key == key

  def profile_allowed?(%{role: role}, profile) when role in [:family, :parent],
    do: profile != nil

  def profile_allowed?(_, _), do: false

  defp case_spec(id, fun) do
    case Enum.find(specs(), &(&1.id == id)) do
      nil -> nil
      spec -> fun.(spec)
    end
  end

  defp specs, do: Application.get_env(:captain_homework, :accounts) || from_env(System.get_env())

  def from_env(env) do
    numbered =
      env
      |> Map.keys()
      |> Enum.flat_map(fn key ->
        case Regex.run(~r/^PRONOTE_(PARENT|CHILD)_([1-9][0-9]*)_PIN_CODE$/, key) do
          [_, role, number] -> [{role, String.to_integer(number)}]
          _ -> []
        end
      end)
      |> Enum.sort_by(fn {role, number} -> {if(role == "CHILD", do: 0, else: 1), number} end)
      |> Enum.map(fn {role, number} ->
        prefix = "PRONOTE_#{role}_#{number}"

        %{
          id: String.downcase(role) <> "-#{number}",
          role: if(role == "CHILD", do: :child, else: :parent),
          label: env[prefix <> "_FIRST_NAME"],
          pin: env[prefix <> "_PIN_CODE"],
          profile_key: if(role == "CHILD", do: "HOMEWORK_CHILD_#{number}")
        }
      end)

    [
      %{
        id: "family",
        role: :family,
        label: "Famille",
        pin: env["PRONOTE_FAMILY_PIN_CODE"],
        profile_key: nil
      }
      | numbered
    ]
  end
end
