defmodule Peridiod.Certificate.ParseError do
  defexception [:message, :field, :source, :path, :reason]

  @impl true
  def exception(opts) do
    field = Keyword.fetch!(opts, :field)
    source = Keyword.get(opts, :source)
    path = Keyword.get(opts, :path)
    reason = Keyword.get(opts, :reason)

    %__MODULE__{
      message: compose_message(field, source, path, reason),
      field: field,
      source: source,
      path: path,
      reason: reason
    }
  end

  defp compose_message(field, source, _path, :identity_not_configured) do
    """
    Identity not configured for #{field} with key_pair_source=#{source}: :identity_not_configured.
    peridiod cannot start with an invalid identity.
    Check node.key_pair_source and node.key_pair_config in peridio-config.json.\
    """
  end

  defp compose_message(field, source, path, reason) do
    """
    Failed to parse #{field} from #{source}#{path_clause(source, path)}: #{inspect(reason)}.
    peridiod cannot start with an invalid identity.
    #{remediation_hint(source)}\
    """
  end

  defp path_clause(_, nil), do: ""
  defp path_clause("env", path), do: " (env var: #{path})"
  defp path_clause("file", path), do: " (file: #{path})"
  defp path_clause("uboot-env", path), do: " (KV key: #{path})"
  defp path_clause(_, path), do: " (#{path})"

  defp remediation_hint("file"), do: "Verify the PEM file exists and is readable."
  defp remediation_hint("env"), do: "Verify the env var value is a valid PEM."
  defp remediation_hint("uboot-env"), do: "Verify the KV entry contains a valid PEM value."

  defp remediation_hint("pkcs11"),
    do: "Verify p11tool can access the HSM and the cert ID or certificate path is correct."

  defp remediation_hint(_), do: ""
end

defmodule Peridiod.Certificate do
  alias Peridiod.Certificate.ParseError

  @spec certificate_from_pem(binary, keyword) ::
          {:ok, X509.Certificate.t()} | {:error, {:parse_error, term}}
  def certificate_from_pem(pem, _opts \\ []) when is_binary(pem) do
    case X509.Certificate.from_pem(pem) do
      {:ok, cert} -> {:ok, cert}
      {:error, reason} -> {:error, {:parse_error, reason}}
    end
  end

  @spec certificate_from_pem!(binary, keyword) :: X509.Certificate.t()
  def certificate_from_pem!(pem, opts \\ []) when is_binary(pem) do
    case X509.Certificate.from_pem(pem) do
      {:ok, cert} ->
        cert

      {:error, reason} ->
        raise ParseError,
          field: :certificate,
          source: opts[:source],
          path: opts[:path],
          reason: reason
    end
  end

  @spec private_key_from_pem(binary, keyword) ::
          {:ok, :public_key.private_key()} | {:error, {:parse_error, term}}
  def private_key_from_pem(pem, _opts \\ []) when is_binary(pem) do
    case X509.PrivateKey.from_pem(pem) do
      {:ok, key} -> {:ok, key}
      {:error, reason} -> {:error, {:parse_error, reason}}
    end
  end

  @spec private_key_from_pem!(binary, keyword) :: :public_key.private_key()
  def private_key_from_pem!(pem, opts \\ []) when is_binary(pem) do
    case X509.PrivateKey.from_pem(pem) do
      {:ok, key} ->
        key

      {:error, reason} ->
        raise ParseError,
          field: :private_key,
          source: opts[:source],
          path: opts[:path],
          reason: reason
    end
  end

  @spec certificate_from_pem_file!(Path.t(), keyword) :: X509.Certificate.t()
  def certificate_from_pem_file!(path, opts \\ []) do
    opts = Keyword.put_new(opts, :path, path)

    case File.read(path) do
      {:ok, pem} ->
        certificate_from_pem!(pem, opts)

      {:error, reason} ->
        raise ParseError,
          field: :certificate,
          source: opts[:source],
          path: opts[:path],
          reason: {:file_read_error, reason}
    end
  end

  @spec private_key_from_pem_file!(Path.t(), keyword) :: :public_key.private_key()
  def private_key_from_pem_file!(path, opts \\ []) do
    opts = Keyword.put_new(opts, :path, path)

    case File.read(path) do
      {:ok, pem} ->
        private_key_from_pem!(pem, opts)

      {:error, reason} ->
        raise ParseError,
          field: :private_key,
          source: opts[:source],
          path: opts[:path],
          reason: {:file_read_error, reason}
    end
  end
end
