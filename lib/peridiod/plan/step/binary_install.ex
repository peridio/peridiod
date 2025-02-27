defmodule Peridiod.Plan.Step.BinaryInstall do
  use Peridiod.Plan.Step

  alias Peridiod.{Binary, Cache, Cloud, Crypto}
  alias Peridiod.Binary.{Downloader, Installer}

  def id(%{binary_metadata: %{prn: prn}}) do
    Module.concat(__MODULE__, prn)
  end

  def init(
        %{
          binary_metadata: binary_metadata,
          installer_mod: installer_mod,
          installer_opts: installer_opts,
          source: source
        } = opts
      ) do
    cache_pid = opts[:cache_pid]
    installer_interfaces = installer_mod.interfaces()

    installer_opts =
      installer_opts
      |> Map.put_new(:cache_pid, opts[:cache_pid])
      |> Map.put_new(:kv_pid, opts[:kv_pid])

    case validate_source_interface(source, installer_interfaces, opts) do
      {:ok, source} ->
        {:ok, pid} =
          Installer.Supervisor.start_installer(
            binary_metadata,
            installer_mod,
            installer_opts
          )

        {:ok,
         %{
           binary_metadata: binary_metadata,
           installer: pid,
           cache_pid: cache_pid,
           source: source,
           byte_counter: nil,
           hash_accumulator: :crypto.hash_init(:sha256),
           step_percent: 0.0,
           source_pid: nil
         }}

      {:error, error} ->
        {:error, error, nil}
    end
  end

  def execute(%{source: source} = state) when is_binary(source) do
    [signature] = state.binary_metadata.signatures
    hash = Crypto.hash(source, :sha256) |> Base.decode16!(case: :mixed)
    expected_hash = state.binary_metadata.hash
    valid_hash? = expected_hash == hash

    valid_signature? =
      Binary.valid_signature?(
        Base.encode16(hash, case: :lower),
        signature.signature,
        signature.signing_key.public_der
      )

    case {valid_hash?, valid_signature?} do
      {true, true} ->
        Installer.path_install(state.installer, source)
        {:noreply, state}

      {false, _} ->
        {:error, :invalid_hash, state}

      {_, false} ->
        {:error, :invalid_signature, state}
    end
  end

  def execute(state) do
    case start_source_stream(state.source, state) do
      {:ok, pid} ->
        {:noreply, %{state | source_pid: pid}}

      error ->
        {:error, error, state}
    end
  end

  defp start_source_stream(%URI{} = uri, state) do
    pid = self()
    fun = &send(pid, {:source, &1})

    Downloader.Supervisor.start_child(
      state.binary_metadata.prn,
      uri,
      fun
    )
  end

  defp start_source_stream(:cache, state) do
    cache_file = Binary.cache_file(state.binary_metadata)
    pid = self()

    Task.start(fn ->
      Cache.read_stream(state.cache_pid, cache_file)
      |> Enum.map(&send(pid, {:source, &1}))
    end)
  end

  # Source Stream Callbacks
  def handle_info({:source, {:stream, bytes}}, %{byte_counter: nil} = state) do
    Installer.stream_init(state.installer)

    handle_info({:source, {:stream, bytes}}, %{
      state
      | byte_counter: 0,
        hash_accumulator: :crypto.hash_init(:sha256)
    })
  end

  def handle_info({:source, {:stream, bytes}}, state) do
    hash = :crypto.hash_update(state.hash_accumulator, bytes)
    byte_counter = state.byte_counter + byte_size(bytes)
    step_percent = byte_counter / state.binary_metadata.size

    Cloud.Event.put_binary_progress(state.binary_metadata.prn, %{
      install_percent: step_percent
    })

    Installer.stream_update(state.installer, bytes)

    {:noreply,
     %{state | hash_accumulator: hash, byte_counter: byte_counter, step_percent: step_percent}}
  end

  def handle_info({:source, {:eof, :invalid_signature, hash}}, state) do
    Installer.stream_finish(state.installer, :invalid_signature, hash)
    {:error, :invalid_signature, state}
  end

  def handle_info({:source, {:eof, _validity, _hash}}, state),
    do: handle_info({:source, :complete}, state)

  def handle_info({:source, :complete}, state) do
    Cloud.Event.put_binary_progress(state.binary_metadata.prn, %{install_percent: 1.0})
    hash = :crypto.hash_final(state.hash_accumulator)
    [signature] = state.binary_metadata.signatures

    expected_hash = state.binary_metadata.hash
    valid_hash? = expected_hash == hash

    valid_signature? =
      Binary.valid_signature?(
        Base.encode16(hash, case: :lower),
        signature.signature,
        signature.signing_key.public_der
      )

    validity =
      case {valid_hash?, valid_signature?} do
        {true, true} -> :valid_signature
        {true, false} -> :invalid_signature
        {false, _} -> :invalid_hash
      end

    Installer.stream_finish(state.installer, validity, hash)
    {:noreply, state}
  end

  # Installer Callbacks
  def handle_info({Installer, _binary_prn, :complete}, state) do
    {:stop, :normal, state}
  end

  def handle_info({Installer, _binary_prn, {:error, error}}, state) do
    {:error, error, state}
  end

  defp validate_source_interface(source, interfaces, _opts) when is_binary(source) do
    case Enum.any?(interfaces, &(&1 == :path)) do
      true ->
        {:ok, source}

      false ->
        {:error, :unsupported_interface}
    end
  end

  defp validate_source_interface(:cache, [:file], %{
         cache_pid: cache_pid,
         binary_metadata: binary_metadata
       }) do
    binary_cache_file = Binary.cache_file(binary_metadata)

    case Cache.exists?(cache_pid, binary_cache_file) do
      true ->
        source = Cache.abs_path(cache_pid, binary_cache_file)
        {:ok, source}

      false ->
        {:error, :cache_file_missing}
    end
  end

  defp validate_source_interface(:cache, [_ | _], _opts), do: {:ok, :cache}

  defp validate_source_interface(%URI{scheme: "file", path: path}, [:path], _opts),
    do: {:ok, path}

  defp validate_source_interface(%URI{}, [:path], _opts), do: {:error, :unsupported_interface}
  defp validate_source_interface(%URI{} = source, [_ | _], _opts), do: {:ok, source}
end
