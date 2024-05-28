defmodule Peridiod.Utils do
  def try_base64_decode(string) do
    case Base.decode64(string) do
      {:ok, decoded} -> decoded
      _error -> string
    end
  end
end
