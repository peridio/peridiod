defmodule Peridiod.Signature do
  alias Peridiod.{Signature, SigningKey}

  defstruct signature: nil,
            signing_key: nil

  @type t() :: %__MODULE__{
          signature: String.t(),
          signing_key: SigningKey.t()
        }

  defimpl Jason.Encoder, for: Signature do
    def encode(%Signature{signature: signature, signing_key: signing_key}, opts) do
      signature = Base.encode16(signature, case: :upper)
      signing_key = SigningKey.ed25519_public_der_to_pem(signing_key.public_der)
      Jason.Encode.map(%{signature: signature, signing_key: signing_key}, opts)
    end
  end

  def metadata_from_json(json) when is_binary(json) do
    with {:ok, map} <- Jason.decode(json) do
      {:ok, metadata_from_map(map)}
    else
      error -> error
    end
  end

  def metadata_from_map(%{"signature" => signature, "signing_key" => signing_key}) do
    {:ok, signing_key} = SigningKey.new(:ed25519, signing_key)

    %__MODULE__{
      signature: Base.decode16!(signature, case: :mixed),
      signing_key: signing_key
    }
  end

  def metadata_from_manifest(%{"signature" => signature, "public_value" => public_pem}) do
    metadata_from_map(%{"signature" => signature, "signing_key" => public_pem})
  end

  def valid?(binary_hash, %__MODULE__{
        signature: signature,
        signing_key: %SigningKey{public_der: public_der, type: :ed25519}
      }) do
    :crypto.verify(:eddsa, :none, binary_hash, signature, [public_der, :ed25519])
  end
end
