defmodule Peridiod.Utils do
  def try_base64_decode(string) do
    case Base.decode64(string) do
      {:ok, decoded} -> decoded
      _error -> string
    end
  end

  def private_key_from_pem_file(private_pem) do
    with {:ok, private_pem} <- File.read(private_pem) do
      X509.PrivateKey.from_pem(private_pem)
    end
  end

  def public_key_from_pem_file(public_pem) do
    with {:ok, public_pem} <- File.read(public_pem),
         {:ok, certificate} <- X509.Certificate.from_pem(public_pem) do
      {:ok, X509.Certificate.public_key(certificate)}
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
