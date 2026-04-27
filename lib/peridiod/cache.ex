defmodule Peridiod.Cache do
  use GenServer

  import Bitwise, only: [band: 2]
  import Peridiod.Crypto

  alias Peridiod.Cache.Encryption

  require Logger

  @hash_algorithm :sha256
  @stream_chunk_size 4096

  def start_link(opts, genserver_opts \\ [name: __MODULE__]) do
    GenServer.start_link(__MODULE__, opts, genserver_opts)
  end

  def stop(pid_or_name \\ __MODULE__) do
    GenServer.stop(pid_or_name)
  end

  def exists?(pid_or_name \\ __MODULE__, file) do
    GenServer.call(pid_or_name, {:exists?, file})
  end

  def read(pid_or_name \\ __MODULE__, file) do
    GenServer.call(pid_or_name, {:read, file})
  end

  def read_stream(pid_or_name \\ __MODULE__, file) do
    GenServer.call(pid_or_name, {:read_stream, file})
  end

  def write(pid_or_name \\ __MODULE__, file, content) do
    GenServer.call(pid_or_name, {:write, file, content})
  end

  def write_stream_update(pid_or_name \\ __MODULE__, file, data) do
    GenServer.call(pid_or_name, {:write_stream_update, file, data})
  end

  def write_stream_finish(pid_or_name \\ __MODULE__, file, signature, public_key) do
    GenServer.call(pid_or_name, {:write_stream_finish, file, signature, public_key})
  end

  def write_stream_finish_local(pid_or_name \\ __MODULE__, file) do
    GenServer.call(pid_or_name, {:write_stream_finish_local, file})
  end

  def ln_s(pid_or_name \\ __MODULE__, target, link) do
    GenServer.call(pid_or_name, {:ln_s, target, link})
  end

  def ls(pid_or_name \\ __MODULE__, path) do
    GenServer.call(pid_or_name, {:ls, path})
  end

  def abs_path(pid_or_name \\ __MODULE__, file) do
    GenServer.call(pid_or_name, {:abs_path, file})
  end

  @doc """
  Returns the decrypted content of a cache file as a temporary file on disk.

  When encryption is enabled, decrypts the file to a temp path under
  `cache_dir/.tmp/` and returns `{:ok, temp_path}`. When encryption is
  disabled, returns `{:ok, original_path}` (no copy is made).

  The caller is responsible for removing the temp file when done; use
  `cleanup_tempfile/2` to do so safely.
  """
  def decrypt_to_tempfile(pid_or_name \\ __MODULE__, file) do
    GenServer.call(pid_or_name, {:decrypt_to_tempfile, file})
  end

  @doc """
  Removes a temporary file previously returned by `decrypt_to_tempfile/2`.

  Only removes files that live under `cache_dir/.tmp/`; silently succeeds for
  any other path (e.g., the original cache path returned when encryption is off).
  """
  def cleanup_tempfile(pid_or_name \\ __MODULE__, path) when is_binary(path) do
    GenServer.call(pid_or_name, {:cleanup_tempfile, path})
  end

  def rm(pid_or_name \\ __MODULE__, file) do
    GenServer.call(pid_or_name, {:rm, file})
  end

  def rm_rf(pid_or_name \\ __MODULE__, dir) do
    GenServer.call(pid_or_name, {:rm_rf, dir})
  end

  def init(config) do
    private_key = config.cache_private_key
    public_key = config.cache_public_key
    cache_dir = config.cache_dir
    hash_algorithm = Map.get(config, :cache_hash_algorithm, @hash_algorithm)
    encryption_enabled = Map.get(config, :cache_encryption_enabled, true)

    init_cache_dir(cache_dir)

    dek_result =
      if encryption_enabled do
        Encryption.load_or_create_dek(cache_dir, private_key, public_key)
      else
        {:ok, nil}
      end

    state = %{
      path: cache_dir,
      hash_algorithm: hash_algorithm,
      private_key: private_key,
      public_key: public_key,
      dek: nil
    }

    case dek_result do
      {:ok, dek} ->
        if dek != nil, do: cleanup_orphaned_plaintext(cache_dir)
        {:ok, %{state | dek: dek}}

      {:error, :dek_signature_invalid} ->
        Logger.warning(
          "[Cache] DEK signature invalid — device key may have been rotated. " <>
            "Regenerating DEK; previously cached encrypted files will require re-download. " <>
            "If key rotation was not expected, investigate for potential tampering."
        )

        case Encryption.regenerate_dek(cache_dir, private_key) do
          {:ok, dek} ->
            purge_stale_encrypted_files(cache_dir)
            cleanup_orphaned_plaintext(cache_dir)
            {:ok, %{state | dek: dek}}

          {:error, reason} ->
            Logger.error("[Cache] Failed to regenerate DEK: #{inspect(reason)}")
            {:stop, reason}
        end

      {:error, reason} ->
        Logger.error("[Cache] Failed to load or create DEK: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  def handle_call({:exists?, file}, _from, state) do
    {:reply, do_exists?(file, state), state}
  end

  def handle_call({:read, file}, _from, state) do
    {:reply, do_read(file, state), state}
  end

  def handle_call({:read_stream, file}, _from, state) do
    file_path = Path.join([state.path, file])
    file_sig_path = file_path <> ".sig"

    reply =
      with true <- File.exists?(file_path),
           {:ok, signature_hex} <- File.read(file_sig_path),
           {:ok, signature} <- Base.decode16(signature_hex, case: :mixed) do
        case state.dek do
          nil ->
            do_read_stream(file_path, state.hash_algorithm, signature, state.public_key)

          dek ->
            Encryption.decrypt_stream(
              file_path,
              state.hash_algorithm,
              signature,
              state.public_key,
              dek
            )
        end
      else
        false ->
          {:error, :enoent}

        _error ->
          {:error, :invalid_signature}
      end

    {:reply, reply, state}
  end

  def handle_call({:write, file, content}, _from, state) do
    {:reply, do_write(file, content, state), state}
  end

  def handle_call({:write_stream_update, file, data}, _from, state) do
    file_path = Path.join([state.path, file])
    dir = Path.dirname(file_path)

    # Chunks land as plaintext during streaming; write_stream_finish[_local] encrypts
    # the completed file in one pass. cleanup_orphaned_plaintext/1 removes remnants
    # if the process is interrupted before finish is called.
    reply =
      with :ok <- File.mkdir_p(dir),
           :ok <- File.write(file_path, data, [:append, :binary]) do
        :ok
      else
        error -> error
      end

    {:reply, reply, state}
  end

  def handle_call({:write_stream_finish, file, signature, public_key}, _from, state) do
    file_path = Path.join([state.path, file])
    file_sig_path = file_path <> ".sig"

    reply =
      with plaintext_hash <- hash(file_path, state.hash_algorithm),
           true <- Peridiod.Binary.valid_signature?(plaintext_hash, signature, public_key),
           :ok <- maybe_encrypt_file(file_path, state),
           hash <- hash(file_path, state.hash_algorithm),
           signature <- sign(hash, state.hash_algorithm, state.private_key),
           :ok <- File.write(file_sig_path, signature) do
        :ok
      else
        false ->
          File.rm(file_path)
          File.rm(file_sig_path)
          {:error, :invalid_signature}

        error ->
          error
      end

    {:reply, reply, state}
  end

  def handle_call({:write_stream_finish_local, file}, _from, state) do
    file_path = Path.join([state.path, file])
    file_sig_path = file_path <> ".sig"

    reply =
      with :ok <- maybe_encrypt_file(file_path, state),
           hash <- hash(file_path, state.hash_algorithm),
           signature <- sign(hash, state.hash_algorithm, state.private_key),
           :ok <- File.write(file_sig_path, signature) do
        :ok
      else
        error -> error
      end

    {:reply, reply, state}
  end

  def handle_call({:ln_s, target, link}, _from, state) do
    target_path = Path.join([state.path, target])
    link_file = Path.join([state.path, link])
    link_dir = Path.dirname(link_file)
    File.mkdir_p(link_dir)
    target_file = Path.relative_to(target_path, link_dir)

    case File.exists?(target_path) do
      true ->
        {:reply, File.ln_s(target_file, link_file), state}

      false ->
        {:reply, {:error, :enoent}, state}
    end
  end

  def handle_call({:ls, path}, _from, state) do
    path = Path.join([state.path, path])
    {:reply, File.ls(path), state}
  end

  def handle_call({:abs_path, file}, _from, state) do
    path = Path.join([state.path, file])
    {:reply, path, state}
  end

  def handle_call({:decrypt_to_tempfile, file}, _from, state) do
    {:reply, do_decrypt_to_tempfile(file, state), state}
  end

  def handle_call({:cleanup_tempfile, path}, _from, state) do
    tmp_dir = Path.expand(Path.join(state.path, ".tmp"))
    expanded = Path.expand(path)

    reply =
      if String.starts_with?(expanded, tmp_dir <> "/") do
        File.rm(expanded)
      else
        :ok
      end

    {:reply, reply, state}
  end

  def handle_call({:rm, file}, _from, state) do
    path = Path.join([state.path, file])
    file_sig_path = path <> ".sig"
    File.rm(file_sig_path)
    {:reply, File.rm(path), state}
  end

  def handle_call({:rm_rf, dir}, _from, state) do
    path = Path.join([state.path, dir])
    {:reply, File.rm_rf(path), state}
  end

  defp do_write(file, content, state) do
    file_path = Path.join([state.path, file])
    file_sig_path = file_path <> ".sig"
    dir = Path.dirname(file_path)

    stored_content =
      case state.dek do
        nil -> content
        dek -> Encryption.encrypt(content, dek)
      end

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(file_path, stored_content),
         hash <- hash(file_path, state.hash_algorithm),
         signature <- sign(hash, state.hash_algorithm, state.private_key),
         :ok <- File.write(file_sig_path, signature) do
      :ok
    end
  end

  defp do_read(file, state) do
    file_path = Path.join([state.path, file])
    file_sig_path = file_path <> ".sig"

    with {:ok, signature_hex} <- File.read(file_sig_path),
         {:ok, signature} <- Base.decode16(signature_hex, case: :mixed),
         true <- File.exists?(file_path) do
      current_hash = hash(file_path, state.hash_algorithm)

      case verified?(current_hash, state.hash_algorithm, signature, state.public_key) do
        true ->
          with {:ok, raw} <- File.read(file_path) do
            case state.dek do
              nil ->
                {:ok, raw}

              dek ->
                case Encryption.decrypt(raw, dek) do
                  # Backward compat: file predates encryption or encryption was disabled
                  {:error, :invalid_format} -> {:ok, raw}
                  result -> result
                end
            end
          end

        false ->
          {:error, :invalid_signature}
      end
    else
      false -> {:error, :enoent}
      :error -> {:error, :invalid_signature}
      error -> error
    end
  end

  defp do_read_stream(file_path, algorithm, signature, public_key) do
    File.stream!(file_path, @stream_chunk_size)
    |> Stream.transform(
      fn -> hash_init(algorithm) end,
      fn chunk, hash -> {[{:stream, chunk}], hash_update(hash, chunk)} end,
      fn hash ->
        hash = hash_final(hash)
        hash_encoded = Base.encode16(hash, case: :lower)

        case verified?(hash_encoded, algorithm, signature, public_key) do
          true -> {[{:eof, :valid_signature, hash_encoded}], hash}
          false -> {[{:eof, :invalid_signature, hash_encoded}], hash}
        end
      end,
      fn _hash -> :ok end
    )
  end

  defp do_decrypt_to_tempfile(file, state) do
    file_path = Path.join([state.path, file])
    file_sig_path = file_path <> ".sig"

    with {:ok, signature_hex} <- File.read(file_sig_path),
         {:ok, signature} <- Base.decode16(signature_hex, case: :mixed),
         true <- File.exists?(file_path) do
      current_hash = hash(file_path, state.hash_algorithm)

      case verified?(current_hash, state.hash_algorithm, signature, state.public_key) do
        true ->
          case state.dek do
            nil ->
              {:ok, file_path}

            dek ->
              temp_dir = Path.join(state.path, ".tmp")
              Encryption.decrypt_to_tempfile(file_path, temp_dir, dek)
          end

        false ->
          {:error, :invalid_signature}
      end
    else
      false -> {:error, :enoent}
      :error -> {:error, :invalid_signature}
      error -> error
    end
  end

  defp maybe_encrypt_file(_file_path, %{dek: nil}), do: :ok

  defp maybe_encrypt_file(file_path, %{dek: dek}) do
    tmp_path = file_path <> ".enc"
    sig_path = file_path <> ".sig"

    case Encryption.encrypt_file(file_path, tmp_path, dek) do
      :ok ->
        case File.rename(tmp_path, file_path) do
          :ok ->
            :ok

          error ->
            File.rm(tmp_path)
            File.rm(file_path)
            File.rm(sig_path)

            Logger.error(
              "[Cache] Failed to replace #{file_path} with encrypted copy: #{inspect(error)}. Plaintext removed to preserve at-rest encryption guarantee; content will be re-downloaded."
            )

            error
        end

      error ->
        File.rm(tmp_path)
        File.rm(file_path)
        File.rm(sig_path)

        Logger.error(
          "[Cache] Failed to encrypt #{file_path}: #{inspect(error)}. Plaintext removed to preserve at-rest encryption guarantee; content will be re-downloaded."
        )

        error
    end
  end

  # Remove leftover plaintext artifacts from previous interrupted operations.
  # Called on startup when encryption is enabled.
  defp cleanup_orphaned_plaintext(cache_dir) do
    # Decrypted temp files from interrupted decrypt_to_tempfile calls
    cleanup_tmp_dir(Path.join(cache_dir, ".tmp"))
    # Stray .enc files from interrupted maybe_encrypt_file calls
    cleanup_enc_files(cache_dir)
  end

  defp cleanup_tmp_dir(tmp_dir) do
    case File.ls(tmp_dir) do
      {:ok, entries} ->
        Enum.each(entries, fn entry ->
          path = Path.join(tmp_dir, entry)

          case File.lstat(path) do
            {:ok, %File.Stat{type: :regular}} ->
              Logger.debug("[Cache] Removing leftover temp file: #{path}")
              File.rm(path)

            _ ->
              :ok
          end
        end)

      {:error, :enoent} ->
        :ok

      _ ->
        :ok
    end
  end

  defp cleanup_enc_files(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.each(entries, fn entry ->
          path = Path.join(dir, entry)

          case File.lstat(path) do
            {:ok, %File.Stat{type: :directory}} when entry != ".tmp" ->
              cleanup_enc_files(path)

            {:ok, %File.Stat{type: :regular}} ->
              if String.ends_with?(entry, ".enc") do
                Logger.debug("[Cache] Removing stray .enc file: #{path}")
                File.rm(path)
              end

            _ ->
              :ok
          end
        end)

      _ ->
        :ok
    end
  end

  defp do_exists?(file, state) do
    file_path = Path.join([state.path, file])
    file_sig_path = file_path <> ".sig"

    with {:ok, sig_hex} <- File.read(file_sig_path),
         {:ok, sig} <- Base.decode16(sig_hex, case: :mixed),
         true <- File.exists?(file_path) do
      current_hash = hash(file_path, state.hash_algorithm)
      verified?(current_hash, state.hash_algorithm, sig, state.public_key)
    else
      _ -> false
    end
  end

  # After DEK rotation, purge files that were encrypted with the old DEK — they can
  # no longer be decrypted and will be re-downloaded on the next update.
  defp purge_stale_encrypted_files(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.each(entries, fn entry ->
          path = Path.join(dir, entry)

          case File.lstat(path) do
            {:ok, %File.Stat{type: :directory}} when entry not in [".tmp"] ->
              purge_stale_encrypted_files(path)

            {:ok, %File.Stat{type: :regular}} ->
              if entry not in [".dek", ".dek.sig"] and
                   not String.ends_with?(entry, ".sig") and
                   Encryption.encrypted?(path) do
                Logger.debug("[Cache] Purging encrypted file (stale DEK): #{path}")
                File.rm(path)
                File.rm(path <> ".sig")
              end

            _ ->
              :ok
          end
        end)

      _ ->
        :ok
    end
  end

  defp init_cache_dir(cache_dir) do
    euid = process_euid()
    check_dir(cache_dir, euid)
    check_dir(Path.join(cache_dir, "log"), euid)
  end

  defp process_euid do
    case System.find_executable("id") do
      nil ->
        Logger.warning("[Cache] Cannot determine effective uid: `id` executable not found")
        nil

      id_path ->
        try do
          case System.cmd(id_path, ["-u"]) do
            {uid_str, 0} -> uid_str |> String.trim() |> String.to_integer()
            _ -> nil
          end
        rescue
          error ->
            Logger.warning("[Cache] Cannot determine effective uid: #{Exception.message(error)}")

            nil
        end
    end
  end

  defp check_dir(path, euid) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        # Inspect the symlink target's mode/uid for warnings, but refuse to
        # chmod through the symlink to avoid modifying unintended targets.
        case File.stat(path) do
          {:ok, %File.Stat{mode: mode, uid: uid}} ->
            perm = band(mode, 0o777)

            if perm != 0o700 do
              Logger.warning(
                "[Cache] #{path} is a symlink; target has mode 0#{Integer.to_string(perm, 8)}, " <>
                  "expected 0700. Skipping chmod — ensure the target directory has mode 0700."
              )
            end

            if not is_nil(euid) and uid != euid do
              Logger.warning(
                "[Cache] #{path} is a symlink; target is owned by uid #{uid}, expected #{euid}. " <>
                  "Ensure the target directory is owned by the daemon user."
              )
            end

          {:error, reason} ->
            Logger.warning(
              "[Cache] #{path} is a symlink but cannot stat target: #{inspect(reason)}"
            )
        end

      {:ok, %File.Stat{type: type}} when type != :directory ->
        Logger.warning(
          "[Cache] #{path} is not a directory (type: #{type}). " <>
            "Skipping permission check to avoid operating on unintended targets."
        )

      {:ok, %File.Stat{mode: mode, uid: uid}} ->
        perm = band(mode, 0o777)

        if perm != 0o700 do
          Logger.warning(
            "[Cache] #{path} has mode 0#{Integer.to_string(perm, 8)}, " <>
              "expected 0700. Cached data may be readable by other users."
          )

          case File.chmod(path, 0o700) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "[Cache] Failed to correct permissions on #{path}: #{inspect(reason)}"
              )
          end
        end

        if not is_nil(euid) and uid != euid do
          Logger.warning(
            "[Cache] #{path} is owned by uid #{uid}, expected #{euid}. " <>
              "Ensure #{path} is owned by the daemon user."
          )
        end

      {:error, :enoent} ->
        :ok = File.mkdir_p(path)

        case File.chmod(path, 0o700) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("[Cache] Failed to set permissions on #{path}: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.warning("[Cache] Cannot stat #{path}: #{inspect(reason)}")
    end
  end
end
