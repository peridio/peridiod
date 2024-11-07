defmodule Peridiod.Binary.Installer.Fwup do
  @moduledoc """
  Installer module for fwup packages

  custom_metadata
  ```
  {
    "peridiod": {
      "installer": "fwup",
      "installer_opts": {
        "env": {"KEY": "VALUE"},
        "extra_args": [],
        "task": "upgrade",
        "devpath": "/dev/mmcblk0"
      },
      "reboot_required": false
    }
  }
  ```
  """

  use Peridiod.Binary.Installer.Behaviour

  alias PeridiodPersistence.KV
  alias __MODULE__

  require Logger

  def install_init(
        _binary_metadata,
        opts,
        _source,
        config
      ) do
    devpath =
      opts["devpath"] || config.fwup_devpath || KV.get("peridio_disk_devpath") ||
        KV.get("nerves_fw_devpath")

    env = opts["env"] || config.fwup_env
    extra_args = opts["extra_args"] || config.fwup_extra_args
    public_keys = config.fwup_public_keys
    task = opts["task"] || "upgrade"

    fwup_config = %Fwup.Config{
      fwup_public_keys: public_keys,
      fwup_devpath: devpath,
      fwup_env: Fwup.Config.parse_fwup_env(env),
      fwup_extra_args: extra_args,
      fwup_task: task
    }

    fwup_config = Fwup.Config.validate_base!(fwup_config)

    {:ok, fwup} =
      Fwup.stream(self(), Fwup.Config.to_cmd_args(fwup_config), fwup_env: fwup_config.fwup_env)

    {:ok, %{fwup: fwup}}
  end

  def install_update(_binary_metadata, data, state) do
    _ = Fwup.Stream.send_chunk(state.fwup, data)
    {:ok, state}
  end

  def install_finish(_binary_metadata, :valid_signature, _hash, state) do
    {:noreply, state}
  end

  def install_finish(_binary_metadata, :invalid_signature, _hash, state) do
    Process.exit(state.fwup, :normal)
    {:error, :invalid_signature, state}
  end

  def install_info({:fwup, message}, state) do
    case message do
      {:ok, 0, _message} ->
        Logger.debug("[FWUP] Finished")
        {:stop, :normal, state}

      {:progress, percent} ->
        Logger.debug("[FWUP] Progress: #{inspect(percent)}")
        {:ok, state}

      {:error, _, message} ->
        Logger.debug("[FWUP] Error: #{inspect(message)}")
        {:error, message, state}

      resp ->
        Logger.debug("[FWUP] Misc: #{inspect(resp)}")
        {:ok, state}
    end
  end

  @doc "Returns a list of `[\"/path/to/device\", byte_size]`"
  def get_devices do
    {result, 0} = System.cmd("fwup", ["--detect"])

    result
    |> String.trim()
    |> String.split("\n")
    |> Enum.map(&String.split(&1, ","))
  end

  @doc "Returns the path to the `fwup` executable."
  def exe do
    System.find_executable("fwup") || raise("Could not find `fwup` executable.")
  end

  @doc """
  Apply a fwupdate

  * `device` - block device to write too. See `get_device/0`.
  * `task`   - Can be any task in the fwup.conf.
               Traditionally it will be `upgrade` or `complete`
  * `path`   - path to the firmware file
  * `extra_args` - extra optional args to pass to fwup.
  """
  def apply(device, task, path, extra_args \\ []) do
    args = ["-a", "-d", device, "-t", task, "-i", path | extra_args]

    all_opts =
      Keyword.put_new([], :name, Fwup.Stream)
      |> Keyword.put(:cm, self())
      |> Keyword.put(:fwup_args, args)

    Fwup.Stream.start_link(all_opts)
  end

  @doc """
  Stream a firmware image to the device

  Options

  * `:name` - register the started GenServer under this name (defaults to Fwup.Stream)
  * `:fwup_env` - the OS environment to pass to fwup
  """
  def stream(pid, args, opts \\ []) do
    all_opts =
      opts
      |> Keyword.put(:cm, pid)
      |> Keyword.put(:fwup_args, args)

    Fwup.Stream.start_link(all_opts)
  end

  defdelegate send_chunk(pid, chunk),
    to: Fwup.Stream

  def installed?() do
    is_binary(System.find_executable("fwup"))
  end

  def version do
    {version_string, 0} = System.cmd("fwup", ["--version"])
    String.trim(version_string)
  end
end
