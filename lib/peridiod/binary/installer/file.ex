defmodule Peridiod.Binary.Installer.File do
  @moduledoc """
  Installer module for files

  custom_metadata
  ```
  {
    "peridiod": {
      "installer": "file",
      "installer_opts": {
        "name": "filename.ext",
        "path": "/path/to/"
      },
      "reboot_required": false
    }
  }
  ```
  """

  use Peridiod.Binary.Installer

  alias Peridiod.Binary

  def execution_model(), do: :parallel
  def interfaces(), do: [:path, :stream]

  def path_install(_binary_metadata, path, %{"name" => name, "path" => dest_path}) do
    final_dest = Path.join([dest_path, name])
    link_dir = Path.dirname(final_dest)
    File.mkdir_p(link_dir)

    # Remove existing file/link if it exists
    File.rm(final_dest)

    case File.ln_s(path, final_dest) do
      :ok -> {:stop, :normal, nil}
      {:error, error} -> {:error, error, nil}
    end
  end

  def path_install(_binary_metadata, _path, _opts) do
    {:error, "File installer_opts keys name and path are required", nil}
  end

  def stream_init(%Binary{prn: prn}, %{"name" => name, "path" => path}) do
    with :ok <- File.mkdir_p(path),
         {:ok, id} <- Binary.id_from_prn(prn) do
      final_dest = Path.join([path, name])
      tmp_dest = Path.join([path, id])
      state = {tmp_dest, final_dest}
      {:ok, state}
    else
      {:error, error} ->
        {:error, error, nil}
    end
  end

  def stream_init(_binary_metadata, _opts) do
    {:error, "File installer_opts keys name and path are required", nil}
  end

  def stream_update(_binary_metadata, data, {tmp_dest, _final_dest} = state) do
    File.write(tmp_dest, data, [:append, :binary])
    {:ok, state}
  end

  def stream_finish(_binary_metadata, :valid_signature, _hash, {tmp_dest, final_dest} = state) do
    link_name = Path.relative_to(tmp_dest, Path.dirname(tmp_dest))

    # Remove existing file/link if it exists
    File.rm(final_dest)

    case File.ln_s(link_name, final_dest) do
      :ok -> {:stop, :normal, state}
      {:error, error} -> {:error, error, state}
    end
  end

  def stream_finish(_binary_metadata, invalid, _hash, {tmp_dest, _final_dest} = state) do
    File.rm(tmp_dest)
    {:error, invalid, state}
  end
end
