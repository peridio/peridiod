defmodule Peridiod.Plan do
  alias Peridiod.{Bundle, Binary, Binary.Installer}
  alias Peridiod.Plan.Step

  require Logger

  defstruct callback: nil,
            run: [[]],
            on_init: [],
            on_error: [],
            on_finish: []

  def resolve_install_bundle(%Bundle{} = bundle_metadata, opts) do
    config = opts[:config] || Peridiod.config()
    callback = opts[:callback]
    cache_pid = opts[:cache_pid]
    kv_pid = opts[:kv_pid]
    binaries_metadata = opts[:filtered_binaries] || bundle_metadata.binaries
    installed_binaries = opts[:installed_binaries] || []

    steps =
      binaries_metadata
      |> separate_binaries_by_type(installed_binaries)
      |> build_install_steps(opts)

    maybe_reboot = reboot_step(steps, config)

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
      | maybe_reboot
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
    config = opts[:config] || Peridiod.config()
    callback = opts[:callback]
    cache_pid = opts[:cache_pid]
    kv_pid = opts[:kv_pid]
    binaries_metadata = opts[:filtered_binaries] || bundle_metadata.binaries
    installed_binaries = opts[:installed_binaries] || []

    steps =
      binaries_metadata
      |> separate_binaries_by_type(installed_binaries)
      |> build_install_steps(opts)

    maybe_reboot = reboot_step(steps, config)

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
      | maybe_reboot
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

    {cache_steps, steps} =
      Enum.reduce(binaries, {[], []}, fn
        binary_metadata, {cache_steps, steps} ->
          installer_mod = Installer.mod(binary_metadata)
          installer_opts = Installer.opts(binary_metadata)
          installer_config_opts = Installer.config_opts(installer_mod, config)
          installer_opts = Map.merge(installer_config_opts, installer_opts)

          {source, cache_steps} =
            case {Binary.cached?(binary_metadata), installer_mod.interfaces()} do
              {false, [:path]} ->
                Logger.info("[Plan] Binary not cached, adding cache step")

                {:cache,
                 [
                   {Step.BinaryCache,
                    %{cache_pid: opts[:cache_pid], binary_metadata: binary_metadata}}
                   | cache_steps
                 ]}

              {true, _} ->
                Logger.info("[Plan] Binary already cached")
                {:cache, cache_steps}

              _ ->
                Logger.info("[Plan] Binary download from uri")
                {binary_metadata.uri, cache_steps}
            end

          step_opts =
            %{}
            |> Map.put(:binary_metadata, binary_metadata)
            |> Map.put(:cache_pid, opts[:cache_pid])
            |> Map.put(:kv_pid, opts[:kv_pid])
            |> Map.put(:installer_mod, installer_mod)
            |> Map.put(:installer_opts, installer_opts)
            |> Map.put(:source, source)

          steps = [{Step.BinaryInstall, step_opts} | steps]
          {cache_steps, steps}
      end)

    case cache_steps do
      [] -> Enum.reverse(steps)
      cache_steps -> [Enum.reverse(cache_steps) |> Enum.uniq(), Enum.reverse(steps)]
    end
  end

  defp binary_installed_steps(installed_binaries, opts) do
    Enum.map(
      installed_binaries,
      &{Step.BinaryState, %{metadata: &1, action: :put_kv_installed, kv_pid: opts[:kv_pid]}}
    )
  end

  defp binary_install_chunk_sequential([cache_steps, steps])
       when is_list(cache_steps) and is_list(steps) do
    [cache_steps | binary_install_chunk_sequential(steps)]
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

  defp reboot_step(steps, config) do
    steps = List.flatten(steps)

    requires_reboot? =
      Enum.any?(steps, fn
        {_, %{binary_metadata: binary_metadata}} ->
          get_in(binary_metadata.custom_metadata, ["peridiod", "reboot_required"]) == true

        _ ->
          false
      end)

    case requires_reboot? do
      true ->
        reboot_opts =
          Map.take(config, [
            :reboot_cmd,
            :reboot_opts,
            :reboot_delay,
            :reboot_sync_cmd,
            :reboot_sync_opts
          ])

        [{Step.SystemReboot, reboot_opts}]

      false ->
        []
    end
  end

  defp separate_binaries_by_type(binaries_metadata, installed_binaries) do
    {avocado_extensions, rest} = Enum.split_with(binaries_metadata, &avocado_extension?/1)
    {avocado_os, non_avocado} = Enum.split_with(rest, &avocado_os?/1)

    # Find already-installed Avocado extensions
    installed_extensions = Enum.filter(installed_binaries, &avocado_extension?/1)

    # Combine ALL extension names (installed + uninstalled)
    all_extension_names =
      (avocado_extensions ++ installed_extensions)
      |> extract_extension_names()

    os_version = extract_os_version(avocado_os)

    %{
      avocado_extensions: avocado_extensions,
      avocado_os: avocado_os,
      non_avocado: non_avocado,
      all_extension_names: all_extension_names,
      os_version: os_version
    }
  end

  defp build_install_steps(grouped_binaries, opts, initial_steps \\ []) do
    initial_steps
    |> build_extension_install_steps(grouped_binaries.avocado_extensions, opts)
    |> build_extension_enable_step(
      grouped_binaries.all_extension_names,
      grouped_binaries.os_version,
      opts
    )
    |> build_non_avocado_steps(grouped_binaries.non_avocado, opts)
    |> build_os_or_refresh_step(
      grouped_binaries.avocado_os,
      grouped_binaries.all_extension_names,
      opts
    )
  end

  defp build_extension_install_steps(steps, [], _opts), do: steps

  defp build_extension_install_steps(steps, extensions, opts) do
    extension_steps =
      extensions
      |> binary_install_steps(opts)
      |> binary_install_chunk_sequential()

    steps ++ extension_steps
  end

  defp build_extension_enable_step(steps, [], _os_version, _opts), do: steps

  defp build_extension_enable_step(steps, extension_names, os_version, opts) do
    enable_step = [
      {Step.AvocadoExtensionEnable,
       %{
         extension_names: extension_names,
         os_version: os_version,
         avocadoctl_cmd: opts[:avocadoctl_cmd]
       }}
    ]

    steps ++ [enable_step]
  end

  defp build_non_avocado_steps(steps, [], _opts), do: steps

  defp build_non_avocado_steps(steps, non_avocado, opts) do
    non_avocado_steps =
      non_avocado
      |> binary_install_steps(opts)
      |> binary_install_chunk_sequential()

    steps ++ non_avocado_steps
  end

  defp build_os_or_refresh_step(steps, avocado_os, extension_names, opts) do
    cond do
      # If we have an OS binary, install it
      !Enum.empty?(avocado_os) ->
        os_steps =
          avocado_os
          |> binary_install_steps(opts)
          |> binary_install_chunk_sequential()

        steps ++ os_steps

      # If we have extensions (new or already-installed) but no OS, refresh
      !Enum.empty?(extension_names) ->
        refresh_step = [
          {Step.AvocadoRefresh,
           %{
             avocadoctl_cmd: opts[:avocadoctl_cmd]
           }}
        ]

        steps ++ [refresh_step]

      # No Avocado components at all
      true ->
        steps
    end
  end

  defp avocado_extension?(%Binary{
         custom_metadata: %{"peridiod" => %{"installer" => "avocado-ext"}}
       }),
       do: true

  defp avocado_extension?(_), do: false

  defp avocado_os?(%Binary{
         custom_metadata: %{"peridiod" => %{"installer" => "avocado-os"}}
       }),
       do: true

  defp avocado_os?(_), do: false

  defp extract_os_version([]), do: nil

  defp extract_os_version([%Binary{} = os_binary | _]) do
    # Version comes from the binary's version field (from artifact_version.version)
    os_binary.version
  end

  defp extract_extension_names(extension_binaries) do
    extension_binaries
    |> Enum.filter(&extension_enabled?/1)
    |> Enum.map(fn binary ->
      get_in(binary.custom_metadata, ["peridiod", "avocado", "extension_name"])
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp extension_enabled?(binary) do
    installer_opts = Installer.opts(binary)
    installer_opts["enabled"] == true
  end
end
