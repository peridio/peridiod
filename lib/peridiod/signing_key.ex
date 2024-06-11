defmodule Peridiod.SigningKey do
  defstruct type: :ed25519,
            public_der: nil

  @type t() :: %__MODULE__{
          type: :ed25519,
          public_der: ed25519_public_key()
        }

  @type ed25519_public_key :: binary

  @ed25519_prefix <<0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00>>

  def new(:ed25519, "-----BEGIN PUBLIC KEY-----" <> _ = public_pem) do
    case ed25519_public_pem_to_der(public_pem) do
      {:ok, key} -> {:ok, %__MODULE__{public_der: key}}
      error -> error
    end
  end

  def new(:ed25519, public_raw) do
    case ed25519_public_raw_to_der(public_raw) do
      {:ok, key} -> {:ok, %__MODULE__{public_der: key}}
      error -> error
    end
  end

  def from_pem_file(pem_file) do
    case File.read(pem_file) do
      {:ok, public_pem} -> ed25519_public_pem_to_der(public_pem)
      error -> error
    end
  end

  def from_raw_file(raw_file) do
    case File.read(raw_file) do
      {:ok, public_raw} -> {:ok, ed25519_public_raw_to_der(public_raw)}
      error -> error
    end
  end

  def ed25519_public_pem_to_der(public_pem) when is_binary(public_pem) do
    case :public_key.pem_decode(public_pem) do
      [{:SubjectPublicKeyInfo, der_encoded, _}] ->
        @ed25519_prefix <> key = der_encoded
        {:ok, key}

      error ->
        error
    end
  end

  def ed25519_public_raw_to_der(raw_base_64) do
    Base.decode64(raw_base_64)
  end

  def ed25519_public_der_to_pem(der_decoded) do
    der_encoded = @ed25519_prefix <> der_decoded
    pem_entry = {:SubjectPublicKeyInfo, der_encoded, :not_encrypted}
    :public_key.pem_encode([pem_entry])
  end
end
