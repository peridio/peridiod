defmodule Peridiod.Cache.Encryption do
  @moduledoc """
  AES-256-GCM encryption for the Peridiod file cache.

  Files are stored on disk in a chunked encrypted format:

    [1 byte version][8 byte file nonce][4 byte chunk size as uint32-be]
    [4 byte chunk len | ciphertext | 16-byte GCM tag] per chunk

  Each chunk uses a nonce derived from the per-file nonce and chunk index,
  preventing chunk-reordering attacks. The GCM tag authenticates each chunk
  independently, so corruption is detected at the chunk boundary rather than
  requiring the entire file to be read before verification.

  The Data Encryption Key (DEK) is a random 256-bit symmetric key stored at
  `cache_dir/.dek`, with its signature at `cache_dir/.dek.sig`. The DEK is
  signed with the device's existing asymmetric key so that tampering is
  detectable on startup.
  """

  import Peridiod.Crypto, only: [sign: 3, verified?: 4]

  require Logger

  @version 1
  @chunk_size 65_536
  @tag_size 16
  @header_size 13
  @aad "peridiod-cache-v1"

  # ---------------------------------------------------------------------------
  # DEK lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Load the DEK from disk, or generate and persist a new one if it does not exist.
  Returns `{:ok, dek}` on success or `{:error, reason}` on failure.
  """
  def load_or_create_dek(cache_dir, private_key, public_key) do
    with :ok <- File.mkdir_p(cache_dir) do
      dek_path = dek_path(cache_dir)
      dek_sig_path = dek_sig_path(cache_dir)

      if File.exists?(dek_path) and File.exists?(dek_sig_path) do
        load_dek(dek_path, dek_sig_path, public_key)
      else
        generate_and_save_dek(dek_path, dek_sig_path, private_key)
      end
    end
  end

  defp load_dek(dek_path, dek_sig_path, public_key) do
    with {:ok, dek} <- File.read(dek_path),
         :ok <- (if byte_size(dek) == 32, do: :ok, else: {:error, :invalid_dek_size}),
         {:ok, sig_hex} <- File.read(dek_sig_path),
         {:ok, sig} <- decode_sig_hex(sig_hex) do
      hash = :crypto.hash(:sha256, dek) |> Base.encode16(case: :lower)

      if verified?(hash, :sha256, sig, public_key) do
        {:ok, dek}
      else
        Logger.error("[Cache.Encryption] DEK signature verification failed — possible tampering")
        {:error, :dek_signature_invalid}
      end
    end
  end

  defp decode_sig_hex(sig_hex) do
    case Base.decode16(String.trim(sig_hex), case: :mixed) do
      :error -> {:error, :invalid_dek_signature_format}
      result -> result
    end
  end

  defp generate_and_save_dek(dek_path, dek_sig_path, private_key) do
    dek = :crypto.strong_rand_bytes(32)
    hash = :crypto.hash(:sha256, dek) |> Base.encode16(case: :lower)
    sig_hex = sign(hash, :sha256, private_key)

    with :ok <- File.write(dek_path, dek),
         :ok <- File.chmod(dek_path, 0o600),
         :ok <- File.write(dek_sig_path, sig_hex),
         :ok <- File.chmod(dek_sig_path, 0o600) do
      {:ok, dek}
    end
  end

  defp dek_path(cache_dir), do: Path.join(cache_dir, ".dek")
  defp dek_sig_path(cache_dir), do: Path.join(cache_dir, ".dek.sig")

  # ---------------------------------------------------------------------------
  # One-shot encrypt / decrypt (for small files: manifests, stamps)
  # ---------------------------------------------------------------------------

  @doc """
  Encrypt `plaintext` with `dek`. Returns the encrypted binary.
  """
  def encrypt(plaintext, dek) when is_binary(plaintext) and byte_size(dek) == 32 do
    file_nonce = :crypto.strong_rand_bytes(8)
    header = <<@version::8, file_nonce::binary-8, @chunk_size::32>>
    chunks = encrypt_chunks_binary(plaintext, file_nonce, dek, 0, [])
    IO.iodata_to_binary([header | Enum.reverse(chunks)])
  end

  defp encrypt_chunks_binary(<<>>, _nonce, _dek, _idx, acc), do: acc

  defp encrypt_chunks_binary(data, file_nonce, dek, idx, acc) do
    take = min(byte_size(data), @chunk_size)
    <<chunk::binary-size(take), rest::binary>> = data
    nonce = <<idx::32, file_nonce::binary>>

    {ct, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, dek, nonce, chunk, @aad, @tag_size, true)

    len = byte_size(ct) + @tag_size

    encrypt_chunks_binary(rest, file_nonce, dek, idx + 1, [
      <<len::32, ct::binary, tag::binary>> | acc
    ])
  end

  @doc """
  Decrypt an encrypted binary produced by `encrypt/2`.
  Returns `{:ok, plaintext}` or `{:error, reason}`.
  """
  def decrypt(data, dek) when is_binary(data) and byte_size(dek) == 32 do
    case data do
      <<@version::8, file_nonce::binary-8, _chunk_size::32, rest::binary>> ->
        decrypt_chunks_binary(rest, file_nonce, dek, 0, [])

      _ ->
        {:error, :invalid_format}
    end
  end

  defp decrypt_chunks_binary(<<>>, _file_nonce, _dek, _idx, acc) do
    {:ok, IO.iodata_to_binary(Enum.reverse(acc))}
  end

  defp decrypt_chunks_binary(<<len::32, rest::binary>>, file_nonce, dek, idx, acc) do
    if len < @tag_size do
      {:error, :invalid_chunk_length}
    else
      case rest do
        <<chunk_data::binary-size(len), remaining::binary>> ->
          ct = binary_part(chunk_data, 0, len - @tag_size)
          tag = binary_part(chunk_data, len - @tag_size, @tag_size)
          nonce = <<idx::32, file_nonce::binary>>

          case :crypto.crypto_one_time_aead(:aes_256_gcm, dek, nonce, ct, @aad, tag, false) do
            plaintext when is_binary(plaintext) ->
              decrypt_chunks_binary(remaining, file_nonce, dek, idx + 1, [plaintext | acc])

            :error ->
              {:error, :authentication_failed}
          end

        _ ->
          {:error, :truncated_chunk}
      end
    end
  end

  defp decrypt_chunks_binary(_, _, _, _, _), do: {:error, :invalid_chunk_header}

  # ---------------------------------------------------------------------------
  # File-level encrypt / decrypt (for streaming write finish)
  # ---------------------------------------------------------------------------

  @doc """
  Encrypt the file at `plaintext_path`, writing the result to `encrypted_path`.
  Reads plaintext in `@chunk_size` blocks so memory usage is bounded.
  """
  def encrypt_file(plaintext_path, encrypted_path, dek) when byte_size(dek) == 32 do
    file_nonce = :crypto.strong_rand_bytes(8)
    header = <<@version::8, file_nonce::binary-8, @chunk_size::32>>

    with {:ok, in_file} <- File.open(plaintext_path, [:read, :binary]),
         {:ok, out_file} <- File.open(encrypted_path, [:write, :binary]) do
      IO.binwrite(out_file, header)
      result = encrypt_file_chunks(in_file, out_file, file_nonce, dek, 0)
      File.close(in_file)
      File.close(out_file)
      result
    end
  end

  defp encrypt_file_chunks(in_file, out_file, file_nonce, dek, idx) do
    case IO.binread(in_file, @chunk_size) do
      :eof ->
        :ok

      data when is_binary(data) ->
        nonce = <<idx::32, file_nonce::binary>>

        {ct, tag} =
          :crypto.crypto_one_time_aead(:aes_256_gcm, dek, nonce, data, @aad, @tag_size, true)

        len = byte_size(ct) + @tag_size
        IO.binwrite(out_file, <<len::32, ct::binary, tag::binary>>)
        encrypt_file_chunks(in_file, out_file, file_nonce, dek, idx + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Decrypt the file at `encrypted_path` to a temporary file under `temp_dir`.
  Returns `{:ok, temp_path}` on success; the caller is responsible for removing
  the temp file when done.
  """
  def decrypt_to_tempfile(encrypted_path, temp_dir, dek) when byte_size(dek) == 32 do
    rand_suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    temp_path = Path.join(temp_dir, ".tmp_#{rand_suffix}")

    with :ok <- File.mkdir_p(temp_dir),
         {:ok, in_file} <- File.open(encrypted_path, [:read, :binary]) do
      case IO.binread(in_file, @header_size) do
        <<@version::8, file_nonce::binary-8, _chunk_size::32>> ->
          case File.open(temp_path, [:write, :binary, :exclusive]) do
            {:ok, out_file} ->
              result = decrypt_file_chunks(in_file, out_file, file_nonce, dek, 0)
              File.close(in_file)
              File.close(out_file)

              case result do
                :ok ->
                  File.chmod(temp_path, 0o600)
                  {:ok, temp_path}

                error ->
                  File.rm(temp_path)
                  error
              end

            {:error, reason} ->
              File.close(in_file)
              {:error, reason}
          end

        _ ->
          File.close(in_file)
          {:error, :invalid_format}
      end
    end
  end

  defp decrypt_file_chunks(in_file, out_file, file_nonce, dek, idx) do
    case IO.binread(in_file, 4) do
      :eof ->
        :ok

      <<len::32>> ->
        if len < @tag_size do
          {:error, :invalid_chunk_length}
        else
          case IO.binread(in_file, len) do
            chunk_data when is_binary(chunk_data) and byte_size(chunk_data) == len ->
              ct = binary_part(chunk_data, 0, len - @tag_size)
              tag = binary_part(chunk_data, len - @tag_size, @tag_size)
              nonce = <<idx::32, file_nonce::binary>>

              case :crypto.crypto_one_time_aead(:aes_256_gcm, dek, nonce, ct, @aad, tag, false) do
                plaintext when is_binary(plaintext) ->
                  IO.binwrite(out_file, plaintext)
                  decrypt_file_chunks(in_file, out_file, file_nonce, dek, idx + 1)

                :error ->
                  {:error, :authentication_failed}
              end

            _ ->
              {:error, :truncated_chunk}
          end
        end

      _ ->
        {:error, :invalid_chunk_header}
    end
  end

  # ---------------------------------------------------------------------------
  # Streaming decryption (for Cache.read_stream)
  # ---------------------------------------------------------------------------

  @doc """
  Returns a lazy `Stream` that decrypts an encrypted cache file chunk by chunk.

  The stream emits:
  - `{:stream, plaintext_chunk}` — decrypted data, safe to pass to installers
  - `{:eof, :valid_signature | :invalid_signature, ciphertext_hash}` — end of stream

  The ciphertext is hashed as it is read and the hash is verified against
  `signature` using `public_key` before emitting the final `:eof` event.
  """
  def decrypt_stream(file_path, algorithm, signature, public_key, dek)
      when byte_size(dek) == 32 do
    Stream.resource(
      fn ->
        case File.open(file_path, [:read, :binary]) do
          {:ok, file} ->
            case IO.binread(file, @header_size) do
              <<@version::8, file_nonce::binary-8, _::32>> = header ->
                hash_acc = :crypto.hash_init(algorithm) |> :crypto.hash_update(header)
                {:reading, file, file_nonce, 0, hash_acc}

              _ ->
                File.close(file)
                {:invalid, nil}
            end

          {:error, _reason} ->
            {:invalid, nil}
        end
      end,
      fn
        {:done, _file} = acc ->
          {:halt, acc}

        {:invalid, _} ->
          {[{:eof, :invalid_signature, ""}], {:done, nil}}

        {:reading, file, file_nonce, idx, hash_acc} ->
          case IO.binread(file, 4) do
            :eof ->
              hash = :crypto.hash_final(hash_acc)
              hash_encoded = Base.encode16(hash, case: :lower)

              eof_event =
                if verified?(hash_encoded, algorithm, signature, public_key) do
                  {:eof, :valid_signature, hash_encoded}
                else
                  {:eof, :invalid_signature, hash_encoded}
                end

              {[eof_event], {:done, file}}

            <<len::32>> = len_bytes when len >= @tag_size ->
              case IO.binread(file, len) do
                chunk_data when is_binary(chunk_data) and byte_size(chunk_data) == len ->
                  hash_acc =
                    hash_acc
                    |> :crypto.hash_update(len_bytes)
                    |> :crypto.hash_update(chunk_data)

                  ct = binary_part(chunk_data, 0, len - @tag_size)
                  tag = binary_part(chunk_data, len - @tag_size, @tag_size)
                  nonce = <<idx::32, file_nonce::binary>>

                  case :crypto.crypto_one_time_aead(
                         :aes_256_gcm,
                         dek,
                         nonce,
                         ct,
                         @aad,
                         tag,
                         false
                       ) do
                    plaintext when is_binary(plaintext) ->
                      {[{:stream, plaintext}], {:reading, file, file_nonce, idx + 1, hash_acc}}

                    :error ->
                      {[{:eof, :invalid_signature, ""}], {:done, file}}
                  end

                _ ->
                  {[{:eof, :invalid_signature, ""}], {:done, file}}
              end

            _ ->
              # Short chunk length (< @tag_size) or unexpected read result
              {[{:eof, :invalid_signature, ""}], {:done, file}}
          end
      end,
      fn
        {:done, file} when not is_nil(file) -> File.close(file)
        {:reading, file, _, _, _} -> File.close(file)
        _ -> :ok
      end
    )
  end

  # ---------------------------------------------------------------------------
  # Format detection
  # ---------------------------------------------------------------------------

  @doc """
  Returns `true` if the file at `file_path` starts with the encryption version byte.
  """
  def encrypted?(file_path) do
    case File.open(file_path, [:read, :binary]) do
      {:ok, file} ->
        result = IO.binread(file, 1) == <<@version::8>>
        File.close(file)
        result

      _ ->
        false
    end
  end
end
