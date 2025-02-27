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

  use Peridiod.Binary.Installer

  alias Peridiod.{Binary, Cache}

  def execution_model(), do: :parallel
  def interfaces(), do: [:stream]

  def stream_init(_binary_metadata, opts) do
    {:ok, opts}
  end

  def stream_update(binary_metadata, data, opts) do
    file = Binary.cache_file(binary_metadata)

    case Cache.write_stream_update(opts[:cache_pid], file, data) do
      :ok ->
        {:ok, opts}

      error ->
        {:error, error, opts}
    end
  end

  def stream_finish(binary_metadata, :valid_signature, _hash, opts) do
    file = Binary.cache_file(binary_metadata)

    case Cache.exists?(opts[:cache_pid], file) do
      true ->
        Binary.stamp_cached(opts[:cache_pid], binary_metadata)
        {:stop, :normal, nil}

      false ->
        Binary.cache_rm(opts[:cache_pid], binary_metadata)
        {:error, :invalid_cache, nil}
    end
  end

  def stream_finish(binary_metadata, invalid, _hash, opts) do
    Binary.cache_rm(opts[:cache_pid], binary_metadata)
    {:error, invalid, nil}
  end
end
