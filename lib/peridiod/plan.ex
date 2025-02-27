defmodule Peridiod.Plan do
  alias Peridiod.{Bundle, Binary, Binary.Installer}
  alias Peridiod.Plan.Step

  defstruct callback: nil,
            run: [[]],
            on_init: [],
            on_error: [],
            on_finish: []

  def resolve_install_bundle(%Bundle{} = bundle_metadata, opts) do
    callback = opts[:callback]
    cache_pid = opts[:cache_pid]
    kv_pid = opts[:kv_pid]
    binaries_metadata = opts[:filtered_binaries] || bundle_metadata.binaries
    installed_binaries = opts[:installed_binaries] || []

    steps =
      binaries_metadata
      |> binary_install_steps(opts)
      |> binary_install_chunk_sequential()

    on_init =
      [
        {Step.Cache,
         %{
           metadata: bundle_metadata,
           action: :save_metadata,
           kv_pid: kv_pid,
           cache_pid: cache_pid
         }},
        {Step.SystemState,
         %{
           action: :progress,
           kv_pid: kv_pid,
           cache_pid: cache_pid,
           bundle_metadata: bundle_metadata
         }}
      ] ++ binary_installed_steps(installed_binaries, opts)

    on_finish = [
      {Step.Cache,
       %{
         metadata: bundle_metadata,
         action: :stamp_installed,
         kv_pid: kv_pid,
         cache_pid: cache_pid
       }},
      {Step.SystemState, %{action: :advance, kv_pid: kv_pid, cache_pid: cache_pid}}
    ]

    on_error = [
      {Step.SystemState, %{action: :progress_reset, kv_pid: kv_pid, cache_pid: cache_pid}}
    ]

    %__MODULE__{
      run: steps,
      callback: callback,
      on_init: on_init,
      on_finish: on_finish,
      on_error: on_error
    }
  end

  def resolve_install_bundle(%{bundle: %Bundle{} = bundle_metadata} = via_metadata, opts) do
    callback = opts[:callback]
    cache_pid = opts[:cache_pid]
    kv_pid = opts[:kv_pid]
    binaries_metadata = opts[:filtered_binaries] || bundle_metadata.binaries
    installed_binaries = opts[:installed_binaries] || []

    steps =
      binaries_metadata
      |> binary_install_steps(opts)
      |> binary_install_chunk_sequential()

    on_init =
      [
        {Step.Cache,
         %{
           metadata: bundle_metadata,
           action: :save_metadata,
           kv_pid: kv_pid,
           cache_pid: cache_pid
         }},
        {Step.Cache,
         %{metadata: via_metadata, action: :save_metadata, kv_pid: kv_pid, cache_pid: cache_pid}},
        {Step.SystemState,
         %{
           action: :progress,
           kv_pid: kv_pid,
           cache_pid: cache_pid,
           bundle_metadata: bundle_metadata,
           via_metadata: via_metadata
         }}
      ] ++ binary_installed_steps(installed_binaries, opts)

    on_finish = [
      {Step.Cache,
       %{
         metadata: bundle_metadata,
         action: :stamp_installed,
         kv_pid: kv_pid,
         cache_pid: cache_pid
       }},
      {Step.Cache,
       %{metadata: via_metadata, action: :stamp_installed, kv_pid: kv_pid, cache_pid: cache_pid}},
      {Step.SystemState, %{action: :advance, kv_pid: kv_pid, cache_pid: cache_pid}}
    ]

    on_error = [
      {Step.SystemState, %{action: :progress_reset, kv_pid: kv_pid, cache_pid: cache_pid}}
    ]

    %__MODULE__{
      run: steps,
      callback: callback,
      on_init: on_init,
      on_finish: on_finish,
      on_error: on_error
    }
  end

  def resolve_cache_bundle(%Bundle{} = bundle_metadata, opts) do
    cache_pid = opts[:cache_pid]
    kv_pid = opts[:kv_pid]
    callback = opts[:callback]
    binaries_metadata = opts[:filtered_binaries] || bundle_metadata.binaries

    on_init = [
      {Step.Cache,
       %{metadata: bundle_metadata, action: :save_metadata, kv_pid: kv_pid, cache_pid: cache_pid}}
    ]

    steps = binary_cache_steps(binaries_metadata, opts)

    on_finish = [
      {Step.Cache, %{metadata: bundle_metadata, action: :stamp_cached, cache_pid: cache_pid}}
    ]

    %__MODULE__{on_init: on_init, run: steps, callback: callback, on_finish: on_finish}
  end

  def resolve_cache_bundle(
        %{bundle: bundle_metadata} = via_metadata,
        opts
      ) do
    callback = opts[:callback]
    kv_pid = opts[:kv_pid]
    cache_pid = opts[:cache_pid]
    binaries_metadata = opts[:filtered_binaries] || bundle_metadata.binaries

    on_init = [
      {Step.Cache,
       %{metadata: bundle_metadata, action: :save_metadata, kv_pid: kv_pid, cache_pid: cache_pid}},
      {Step.Cache,
       %{metadata: via_metadata, action: :save_metadata, kv_pid: kv_pid, cache_pid: cache_pid}}
    ]

    steps = binary_cache_steps(binaries_metadata, opts)

    on_finish = [
      {Step.Cache, %{metadata: bundle_metadata, action: :stamp_cached, cache_pid: cache_pid}},
      {Step.Cache, %{metadata: via_metadata, action: :stamp_cached, cache_pid: cache_pid}}
    ]

    %__MODULE__{on_init: on_init, run: steps, callback: callback, on_finish: on_finish}
  end

  def resolve_install_binaries(binaries, opts) do
    callback = opts[:callback]

    steps =
      binaries
      |> binary_install_steps(opts)
      |> binary_install_chunk_sequential()

    %__MODULE__{run: steps, callback: callback}
  end

  def resolve_cache_binaries(binaries, opts) do
    callback = opts[:callback]
    steps = binary_cache_steps(binaries, opts)
    %__MODULE__{run: steps, callback: callback}
  end

  defp binary_cache_steps(binaries, opts) do
    Enum.map(binaries, &{Step.BinaryCache, %{cache_pid: opts[:cache_pid], binary_metadata: &1}})
  end

  defp binary_install_steps(binaries, opts) do
    config = opts[:config] || Peridiod.config()

    Enum.map(binaries, fn binary_metadata ->
      installer_mod = Installer.mod(binary_metadata)
      installer_opts = Installer.opts(binary_metadata)
      installer_config_opts = Installer.config_opts(installer_mod, config)
      installer_opts = Map.merge(installer_config_opts, installer_opts)
      source = if Binary.cached?(binary_metadata), do: :cache, else: binary_metadata.uri

      step_opts =
        %{}
        |> Map.put(:binary_metadata, binary_metadata)
        |> Map.put(:cache_pid, opts[:cache_pid])
        |> Map.put(:kv_pid, opts[:kv_pid])
        |> Map.put(:installer_mod, installer_mod)
        |> Map.put(:installer_opts, installer_opts)
        |> Map.put(:source, source)

      {Step.BinaryInstall, step_opts}
    end)
  end

  defp binary_installed_steps(installed_binaries, opts) do
    Enum.map(
      installed_binaries,
      &{Step.BinaryState, %{metadata: &1, action: :put_kv_installed, kv_pid: opts[:kv_pid]}}
    )
  end

  defp binary_install_chunk_sequential(steps) do
    Enum.chunk_while(
      steps,
      [],
      fn
        {_, %{installer_mod: mod}} = step, acc ->
          if Enum.any?(acc, &(elem(&1, 1).installer_mod == mod)) and
               Installer.execution_model(mod) == :sequential do
            {:cont, Enum.reverse(acc), [step]}
          else
            {:cont, [step | acc]}
          end
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
  end
end
