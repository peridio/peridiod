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

        case System.cmd(@exec, ["install", "-y", path] ++ extra_args) do
          {_result, 0} ->
            {:stop, :normal, nil}

          {error, _} ->
            {:error, error, nil}
        end
    end
  end
end
