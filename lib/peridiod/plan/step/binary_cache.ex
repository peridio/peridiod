defmodule Peridiod.Plan.Step.BinaryCache do
  use Peridiod.Plan.Step

  alias Peridiod.{Binary, Cache, Cloud}
  alias Peridiod.Binary.Downloader

  def id(%{binary_metadata: %{prn: prn}}) do
    Module.concat(__MODULE__, prn)
  end

  def init(%{binary_metadata: binary_metadata, cache_pid: cache_pid} = opts) do
    uri = opts[:uri] || binary_metadata.uri

    cache_file =
      opts[:cache_file] ||
        Binary.cache_file(binary_metadata)

    {:ok,
     %{
       binary_metadata: binary_metadata,
       cache_file: cache_file,
       cache_pid: cache_pid,
       uri: uri,
       byte_counter: 0,
       step_percent: 0.0,
       source_pid: nil
     }}
  end

  def execute(%{binary_metadata: binary_metadata, uri: uri} = state) do
    Cache.rm(state.cache_pid, state.cache_file)
    {:ok, pid} = start_source_stream(binary_metadata, uri)
    {:noreply, %{state | source_pid: pid}}
  end

  defp start_source_stream(binary_metadata, %URI{} = uri) do
    pid = self()
    fun = &send(pid, {:source, &1})

    Downloader.Supervisor.start_child(
      binary_metadata.prn,
      uri,
      fun
    )
  end

  def handle_info({:source, {:stream, bytes}}, state) do
    byte_counter = state.byte_counter + byte_size(bytes)
    step_percent = byte_counter / state.binary_metadata.size

    Cloud.Event.put_binary_progress(state.binary_metadata.prn, %{
      download_percent: step_percent
    })

    case Cache.write_stream_update(state.cache_pid, state.cache_file, bytes) do
      :ok ->
        {:noreply, %{state | step_percent: step_percent}}

      error ->
        {:error, error, %{state | step_percent: step_percent}}
    end
  end

  def handle_info({:source, :complete}, state) do
    Cloud.Event.put_binary_progress(state.binary_metadata.prn, %{download_percent: 1.0})
    [signature] = state.binary_metadata.signatures

    case Cache.write_stream_finish(
           state.cache_pid,
           state.cache_file,
           signature.signature,
           signature.signing_key.public_der
         ) do
      :ok ->
        Binary.stamp_cached(state.cache_pid, state.binary_metadata)
        {:stop, :normal, %{state | step_percent: 1.0}}

      {:error, error} ->
        Binary.cache_rm(state.cache_pid, state.binary_metadata)
        {:error, error, state}
    end
  end
end
