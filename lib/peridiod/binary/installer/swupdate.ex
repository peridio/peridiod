defmodule Peridiod.Binary.Installer.SWUpdate do
  @moduledoc """
  Installer module for swu (SWUpdate) packages

  custom_metadata
  ```
  {
    "peridiod": {
      "installer": "swupdate",
      "installer_opts": {
        "extra_args": ["-p", "custom_post_action"]
      },
      "reboot_required": false
    }
  }
  ```
  """

  @exec "swupdate"

  use Peridiod.Binary.Installer.Behaviour

  alias Peridiod.{Binary, Utils, Cache}
  alias Peridiod.Binary.CacheDownloader

  require Logger

  def install_downloader(_binary_metadata, _opts) do
    CacheDownloader
  end

  def install_init(
        _binary_metadata,
        opts,
        _source,
        config
      ) do
    case Utils.exec_installed?(@exec) do
      false ->
        {:error,
         "Unable to locate executable #{@exec} which is required to install with the swupdate installer",
         nil}

      true ->
        {:ok, {opts, config}}
    end
  end

  def install_finish(binary_metadata, :valid_signature, _hash, {opts, config}) do
    extra_args = opts["extra_args"] || []
    cache_file_path = Binary.cache_file(binary_metadata)
    cache_file = Cache.abs_path(config.cache_pid, cache_file_path)

    case System.cmd("swupdate", ["-i", cache_file] ++ extra_args) do
      {_result, 0} ->
        {:stop, :normal, nil}

      {error, _} ->
        Logger.debug("[Installer SWupdate] Install Error: #{inspect(error)}")
        Binary.cache_rm(config.cache_pid, binary_metadata)
        {:error, error, nil}
    end
  end

  def install_finish(binary_metadata, invalid, _hash, {_opts, config}) do
    Binary.cache_rm(config.cache_pid, binary_metadata)
    {:error, invalid, nil}
  end
end
