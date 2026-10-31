defmodule CaptainHomework.Study.JSONList do
  use Ecto.Type
  def type, do: :string
  def cast(value) when is_list(value), do: {:ok, value}
  def cast(_), do: :error
  def load(value), do: Jason.decode(value)
  def dump(value) when is_list(value), do: Jason.encode(value)
  def dump(_), do: :error
end
