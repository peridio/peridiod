defmodule Peridiod.Binary.Installer do
  defmacro __using__(_opts) do
    quote do
      @behaviour Peridiod.Binary.Installer.Behaviour

      def execution_model(), do: :sequential

      def path_install(%Peridiod.Binary{}, _file_path, _opts) do
        {:error, :not_implemented}
      end

      def stream_init(%Peridiod.Binary{}, _opts) do
        {:error, :not_implemented}
      end

      def stream_update(%Peridiod.Binary{}, {:error, reason}, state) do
        {:error, reason, state}
      end

      def stream_update(%Peridiod.Binary{}, _data, state) do
        {:ok, state}
      end

      def stream_finish(%Peridiod.Binary{}, :invalid_signature, state) do
        {:error, :invalid_signature, state}
      end

      def stream_info(_msg, installer_state) do
        {:ok, installer_state}
      end

      def stream_error(%Peridiod.Binary{}, error, installer_state) do
        {:error, error, installer_state}
      end

      defoverridable execution_model: 0,
                     path_install: 3,
                     stream_init: 2,
                     stream_update: 3,
                     stream_finish: 3,
                     stream_info: 2,
                     stream_error: 3
    end
  end

  use GenServer

  require Logger

  alias PeridiodPersistence.KV
  alias Peridiod.{Binary, Cache}
  alias Peridiod.Binary.Installer

  defmodule State do
    defstruct cache_pid: Cache,
              cache_stream: nil,
              callback: nil,
              config: nil,
              binary_metadata: nil,
              hash_accumulator: nil,
              installer_mod: nil,
              installer_opts: %{},
              installer_state: nil,
              kv_pid: KV,
              source: nil
  end

  def child_spec(%Binary{prn: binary_prn} = binary_metadata, mod, opts) do
    opts = Map.put(opts, :callback, self())

    %{
      id: Module.concat(__MODULE__, binary_prn),
      start: {__MODULE__, :start_link, [binary_metadata, mod, opts]},
      restart: :temporary,
      shutdown: 5000,
      type: :worker,
      modules: [__MODULE__]
    }
  end

  def start_link(%Binary{} = binary_metadata, mod, opts) do
    GenServer.start_link(__MODULE__, {binary_metadata, mod, opts})
  end

  def execution_model(installer_mod), do: installer_mod.execution_model()
  def interfaces(installer_mod), do: installer_mod.interfaces()

  def path_install(pid, path) do
    GenServer.cast(pid, {:path_install, path})
  end

  def stream_init(pid) do
    GenServer.cast(pid, :stream_init)
  end

  def stream_update(pid, bytes) do
    GenServer.cast(pid, {:stream_update, bytes})
  end

  def stream_finish(pid, validity, hash) do
    GenServer.cast(pid, {:stream_finish, validity, hash})
  end

  def stream_error(pid, error) do
    GenServer.cast(pid, {:stream_error, error})
  end

  def init({binary_metadata, mod, opts}) do
    Logger.info("[Installer #{binary_metadata.prn}] Starting")
    Process.flag(:trap_exit, true)

    cache_pid = Map.get(opts, :cache_pid, Cache)
    kv_pid = Map.get(opts, :kv_pid, KV)
    callback = opts.callback

    {:ok,
     %State{
       callback: callback,
       cache_pid: cache_pid,
       kv_pid: kv_pid,
       installer_mod: mod,
       installer_opts: opts,
       binary_metadata: binary_metadata
     }}
  end

  def handle_cast({:path_install, path}, state) do
    apply(state.installer_mod, :path_install, [
      state.binary_metadata,
      path,
      state.installer_opts
    ])
    |> installer_resp(state)
    |> installer_complete()
  end

  def handle_cast(:stream_init, state) do
    apply(state.installer_mod, :stream_init, [
      state.binary_metadata,
      state.installer_opts
    ])
    |> installer_resp(state)
    |> installer_progress()
  end

  def handle_cast({:stream_update, bytes}, state) do
    apply(state.installer_mod, :stream_update, [
      state.binary_metadata,
      bytes,
      state.installer_state
    ])
    |> installer_resp(state)
    |> installer_progress()
  end

  def handle_cast({:stream_finish, validity, hash}, state) do
    apply(state.installer_mod, :stream_finish, [
      state.binary_metadata,
      validity,
      hash,
      state.installer_state
    ])
    |> installer_resp(state)
    |> installer_complete()
  end

  def handle_cast({:stream_error, reason}, state) do
    apply(state.installer_mod, :stream_error, [
      state.binary_metadata,
      reason,
      state.installer_state
    ])
    |> installer_resp(state)
    |> installer_error()
  end

  def handle_info({:EXIT, _, error}, state) do
    Logger.debug("[Installer] Handle EXIT")
    installer_error({:stop, error, state})
  end

  def handle_info(msg, state) do
    apply(state.installer_mod, :stream_info, [
      msg,
      state.installer_state
    ])
    |> installer_resp(state)
    |> installer_progress()
    |> installer_complete()
  end

  defp installer_resp({ok, installer_state}, state) when ok in [:ok, :noreply] do
    {:noreply, %{state | installer_state: installer_state}}
  end

  defp installer_resp({:stop, reason, installer_state}, state) do
    {:stop, reason, %{state | installer_state: installer_state}}
  end

  defp installer_resp({:error, reason, installer_state}, state) do
    {:stop, reason, %{state | installer_state: installer_state}}
  end

  defp installer_complete({:stop, :normal, state}) do
    Logger.info("[Installer #{state.binary_metadata.prn}] Complete")
    Binary.stamp_installed(state.cache_pid, state.binary_metadata)
    Binary.put_kv_installed(state.kv_pid, state.binary_metadata, :progress)
    try_send(state.callback, {Installer, state.binary_metadata.prn, :complete})
    {:stop, :normal, state}
  end

  defp installer_complete({:noreply, state}) do
    {:noreply, state}
  end

  defp installer_complete({:stop, error, state}) do
    Logger.error("[Installer #{state.binary_metadata.prn}] Error #{inspect(error)}")
    Binary.stamp_cached(state.cache_pid, state.binary_metadata)
    try_send(state.callback, {Installer, state.binary_metadata.prn, {:error, error}})
    {:stop, :normal, state}
  end

  defp installer_progress({:noreply, state}) do
    {:noreply, state}
  end

  defp installer_progress({:stop, :normal, state}) do
    {:stop, :normal, state}
  end

  defp installer_progress({:stop, error, state}) do
    Logger.error("[Installer #{state.binary_metadata.prn}] Error #{inspect(error)}")
    try_send(state.callback, {Installer, state.binary_metadata.prn, {:error, error}})
    {:stop, :normal, state}
  end

  defp installer_error({:stop, error, state}) do
    Logger.error("[Installer #{state.binary_metadata.prn}] Error #{inspect(error)}")
    try_send(state.callback, {Installer, state.binary_metadata.prn, {:error, error}})
    {:stop, :normal, state}
  end

  def mod(%Binary{custom_metadata: %{"peridiod" => %{"installer" => "cache"}}}),
    do: Installer.Cache

  def mod(%Binary{custom_metadata: %{"peridiod" => %{"installer" => "fwup"}}}),
    do: Installer.Fwup

  def mod(%Binary{custom_metadata: %{"peridiod" => %{"installer" => "file"}}}),
    do: Installer.File

  def mod(%Binary{custom_metadata: %{"peridiod" => %{"installer" => "deb"}}}),
    do: Installer.Deb

  def mod(%Binary{custom_metadata: %{"peridiod" => %{"installer" => "rpm"}}}),
    do: Installer.Rpm

  def mod(%Binary{custom_metadata: %{"peridiod" => %{"installer" => "opkg"}}}),
    do: Installer.Opkg

  def mod(%Binary{custom_metadata: %{"peridiod" => %{"installer" => "swupdate"}}}),
    do: Installer.SWUpdate

  def mod(%Binary{custom_metadata: %{"peridiod" => %{"installer" => "avocado-os"}}}),
    do: Installer.AvocadoOS

  def mod(%Binary{custom_metadata: %{"peridiod" => %{"installer" => "avocado-ext"}}}),
    do: Installer.AvocadoExt

  def mod(%Binary{custom_metadata: %{"peridiod" => %{"installer" => installer}}}) do
    {:error, "The specified installer: #{inspect(installer)} is not a supported installer module"}
  end

  def mod(%Binary{custom_metadata: %{"peridiod" => _}}) do
    {:error, "Installer key missing from custom_metadata"}
  end

  def mod(_binary_metadata) do
    {:error, "custom_metadata is missing peridiod configuration settings"}
  end

  def opts(%Binary{custom_metadata: %{"peridiod" => %{"installer_opts" => opts}}}) do
    opts
  end

  def opts(_binary_metadata) do
    %{}
  end

  def config_opts(Installer.Fwup, config) do
    Map.take(config, [:fwup_devpath, :fwup_env, :fwup_public_keys, :fwup_extra_args])
  end

  # AvocadoOS may delegate to Fwup, so include fwup config options
  def config_opts(Installer.AvocadoOS, config) do
    Map.take(config, [:fwup_devpath, :fwup_env, :fwup_public_keys, :fwup_extra_args])
  end

  def config_opts(_mod, _config), do: %{}

  defp try_send(nil, _msg), do: :ok

  defp try_send(pid, msg) do
    if Process.alive?(pid) do
      send(pid, msg)
    end
  end
end
