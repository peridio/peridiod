defmodule Peridiod.Utils do
  def try_base64_decode(string) do
    case Base.decode64(string) do
      {:ok, decoded} -> decoded
      _error -> string
    end
  end

  def stamp_utc_now() do
    DateTime.utc_now()
    |> DateTime.to_iso8601()
  end

  def exec_installed?(exec) do
    is_binary(System.find_executable(exec))
  end

  def pem_certificate_trim(pem) do
    Regex.replace(~r/\A.*?(?=-----BEGIN CERTIFICATE-----)/s, pem, "")
  end
end
