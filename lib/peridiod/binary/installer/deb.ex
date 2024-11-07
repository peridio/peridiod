defmodule Peridiod.Binary.Installer.Deb do
  @moduledoc """
  Installer module for deb packages

  custom_metadata
  ```
  {
    "peridiod": {
      "installer": "deb",
      "installer_opts": {
        "extra_args": []
      },
      "reboot_required": false
    }
  }
  ```
  """

  @exec "apt"

  use Peridiod.Binary.Installer.Behaviour

  alias Peridiod.{Binary, Utils}

  def install_init(
        binary_metadata,
        opts,
        _source,
        _config
      ) do
    case Utils.exec_installed?(@exec) do
      nil ->
        {:error, "Unable to locate executable #{@exec} which is required to install with deb installer"}
      _ ->
        do_init(binary_metadata, opts)
    end
  end



  def install_update(_binary_metadata, data, {cache_file, opts}) do
    File.write(cache_file, data, [:append, :binary])
    {:ok, {cache_file, opts}}
  end

  def install_finish(_binary_metadata, :valid_signature, _hash, {cache_file, opts}) do
    extra_args = opts["extra_args"] || []

    case System.cmd(@exec, ["install", "-y", cache_file] ++ extra_args) do
      {_result, 0} ->
        File.rm(cache_file)
        {:stop, :normal, nil}

      {error, _} ->
        File.rm(cache_file)
        {:error, error, nil}
    end
  end

  def install_finish(_binary_metadata, invalid, _hash, {cache_file, _opts}) do
    File.rm(cache_file)
    {:error, invalid, nil}
  end

  defp do_init(binary_metadata, opts) do
    cache_dir = Binary.cache_dir(binary_metadata)

    with :ok <- File.mkdir_p(cache_dir),
         {:ok, id} <- Binary.id_from_prn(binary_metadata.prn) do
      cache_file = Path.join([cache_dir, id])
      {:ok, {cache_file, opts}}
    else
      {:error, error} ->
        {:error, error, nil}
    end
  end
end
