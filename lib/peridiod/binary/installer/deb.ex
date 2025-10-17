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

  use Peridiod.Binary.Installer
  alias Peridiod.Utils

  def execution_model(), do: :sequential
  def interfaces(), do: [:path]

  def path_install(_binary_metadata, path, opts) do
    case Utils.exec_installed?(@exec) do
      false ->
        {:error,
         "Unable to locate executable #{@exec} which is required to install with deb installer",
         nil}

      true ->
        extra_args = opts["extra_args"] || []

        case determine_deb_path(path) do
          {:ok, deb_path} ->
            case System.cmd(@exec, ["install", "-y", deb_path] ++ extra_args) do
              {_result, 0} ->
                {:stop, :normal, nil}

              {error, _} ->
                {:error, error, nil}
            end

          {:error, reason} ->
            {:error, reason, nil}
        end
    end
  end

  defp determine_deb_path(path) do
    cond do
      String.ends_with?(path, ".deb") ->
        if File.exists?(path) do
          {:ok, path}
        else
          {:error, "File does not exist: #{path}"}
        end

      File.exists?(path <> ".deb") ->
        {:ok, path <> ".deb"}

      File.exists?(path) ->
        deb_path = path <> ".deb"

        case File.ln_s(path, deb_path) do
          :ok -> {:ok, deb_path}
          {:error, reason} -> {:error, "Failed to create symbolic link: #{inspect(reason)}"}
        end

      true ->
        {:error, "File does not exist: #{path}"}
    end
  end
end
