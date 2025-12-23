defmodule Peridiod.Cache do
  use GenServer

  import Peridiod.Crypto

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

    {:ok,
     %{
       path: cache_dir,
       hash_algorithm: hash_algorithm,
       private_key: private_key,
       public_key: public_key
     }}
  end

  def handle_call({:exists?, file}, _from, state) do
    resp =
      case do_read(file, state) do
        {:ok, _content} -> true
        _error -> false
      end

    {:reply, resp, state}
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
        do_read_stream(file_path, state.hash_algorithm, signature, state.public_key)
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
      with hash <- hash(file_path, state.hash_algorithm),
           true <- verify_signature(hash, signature, public_key),
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
      with hash <- hash(file_path, state.hash_algorithm),
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

  # Verify signature trying raw hash first (new format), then base16 encoded (legacy)
  defp verify_signature(hash, signature, public_key) when is_binary(hash) do
    raw_hash = if byte_size(hash) == 64, do: Base.decode16!(hash, case: :mixed), else: hash

    case :crypto.verify(:eddsa, :none, raw_hash, signature, [public_key, :ed25519]) do
      true -> true
      false -> :crypto.verify(:eddsa, :none, hash, signature, [public_key, :ed25519])
    end
  end

  defp do_write(file, content, %{
         hash_algorithm: hash_algorithm,
         private_key: private_key,
         path: path
       }) do
    file_path = Path.join([path, file])
    file_sig_path = file_path <> ".sig"
    dir = Path.dirname(file_path)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(file_path, content),
         hash <- hash(file_path, hash_algorithm),
         signature <- sign(hash, hash_algorithm, private_key),
         :ok <- File.write(file_sig_path, signature) do
      :ok
    end
  end

  defp do_read(file, %{
         hash_algorithm: hash_algorithm,
         public_key: public_key,
         path: path
       }) do
    file_path = Path.join([path, file])
    file_sig_path = file_path <> ".sig"

    with {:ok, signature_hex} <- File.read(file_sig_path),
         {:ok, signature} <- Base.decode16(signature_hex, case: :mixed),
         true <- File.exists?(file_path) do
      current_hash = hash(file_path, hash_algorithm)

      case verified?(current_hash, hash_algorithm, signature, public_key) do
        true -> File.read(file_path)
        false -> {:error, :invalid_signature}
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
end
