defmodule Peridiod.Binary.Installer.Cache do
  @moduledoc """
  Installer module for cache only packages
  This is really only used for testing

  custom_metadata
  ```
  {
    "peridiod": {
      "installer": "cache",
      "installer_opts": {},
      "reboot_required": false
    }
  }
  ```
  """

  use Peridiod.Binary.Installer.Behaviour

  alias Peridiod.{Binary, Cache}
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
    {:ok, {opts, config}}
  end

  def install_finish(binary_metadata, :valid_signature, _hash, {_opts, config}) do
    cache_file_path = Binary.cache_file(binary_metadata)

    case Cache.exists?(config.cache_pid, cache_file_path) do
      true ->
        {:stop, :normal, nil}

      false ->
        Binary.cache_rm(config.cache_pid, binary_metadata)
        {:error, :invalid_cache, nil}
    end
  end

  def install_finish(binary_metadata, invalid, _hash, {_opts, config}) do
    Binary.cache_rm(config.cache_pid, binary_metadata)
    {:error, invalid, nil}
  end
end
