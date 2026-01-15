defmodule Peridiod.Binary.Installer.AvocadoExt do
  @moduledoc """
  Installer module for Avocado Extensions

  custom_metadata
  ```
  {
    "peridiod": {
      "installer": "avocado-ext",
      "installer_opts": {
        "name": "extension-name",
        "path": "/custom/path"  // optional, defaults to /usr/lib/avocado/extensions
      },
      "reboot_required": false
    }
  }
  ```
  """

  use Peridiod.Binary.Installer

  alias Peridiod.Binary

  @default_extensions_path "/usr/lib/avocado/extensions"

  def execution_model(), do: :parallel
  def interfaces(), do: [:path, :stream]

  def path_install(_binary_metadata, path, %{"name" => name} = opts) do
    extensions_path = Map.get(opts, "path", @default_extensions_path)
    final_dest = Path.join([extensions_path, name])
    dest_dir = Path.dirname(final_dest)
    File.mkdir_p(dest_dir)

    # Remove existing file if it exists
    File.rm(final_dest)

    case File.rename(path, final_dest) do
      :ok -> {:stop, :normal, nil}
      {:error, error} -> {:error, error, nil}
    end
  end

  def path_install(_binary_metadata, _path, _opts) do
    {:error, "AvocadoExt installer_opts key name is required", nil}
  end

  def stream_init(%Binary{prn: prn}, %{"name" => name} = opts) do
    extensions_path = Map.get(opts, "path", @default_extensions_path)

    with :ok <- File.mkdir_p(extensions_path),
         {:ok, id} <- Binary.id_from_prn(prn) do
      final_dest = Path.join([extensions_path, name])
      tmp_dest = Path.join([extensions_path, id])
      state = {tmp_dest, final_dest}
      {:ok, state}
    else
      {:error, error} ->
        {:error, error, nil}
    end
  end

  def stream_init(_binary_metadata, _opts) do
    {:error, "AvocadoExt installer_opts key name is required", nil}
  end

  def stream_update(_binary_metadata, data, {tmp_dest, _final_dest} = state) do
    File.write(tmp_dest, data, [:append, :binary])
    {:ok, state}
  end

  def stream_finish(_binary_metadata, :valid_signature, _hash, {tmp_dest, final_dest} = state) do
    # Remove existing file if it exists
    File.rm(final_dest)

    case File.rename(tmp_dest, final_dest) do
      :ok -> {:stop, :normal, state}
      {:error, error} -> {:error, error, state}
    end
  end

  def stream_finish(_binary_metadata, invalid, _hash, {tmp_dest, _final_dest} = state) do
    File.rm(tmp_dest)
    {:error, invalid, state}
  end
end
