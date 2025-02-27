defmodule Peridiod.Crypto do
  @stream_chunk_size 4096

  def hash(file_path, algorithm) do
    File.stream!(file_path, [], @stream_chunk_size)
    |> Enum.reduce(hash_init(algorithm), &hash_update(&2, &1))
    |> hash_final()
    |> Base.encode16(case: :lower)
  end

  def hash_init(algorithm) do
    :crypto.hash_init(algorithm)
  end

  def hash_update(hash_acc, binary) do
    :crypto.hash_update(hash_acc, binary)
  end

  def hash_final(hash_acc) do
    :crypto.hash_final(hash_acc)
  end

  def sign(hash, algorithm, private_key) do
    :public_key.sign(hash, algorithm, private_key)
    |> Base.encode16(case: :upper)
  end

  def verified?(hash, algorithm, signature, public_key) do
    :public_key.verify(hash, algorithm, signature, public_key)
  end
end
