defmodule Peridiod.Binary.Installer.Rpm do
  @moduledoc """
  Installer module for rpm packages

  custom_metadata
  ```
  {
    "peridiod": {
      "installer": "rpm",
      "installer_opts": {
        "extra_args": []
      },
      "reboot_required": false
    }
  }
  ```
  """

  @exec "dnf"

  use Peridiod.Binary.Installer

  alias Peridiod.Utils

  def execution_model(), do: :sequential
  def interfaces(), do: [:path]

  def path_install(_binary_metadata, path, opts) do
    case Utils.exec_installed?(@exec) do
      false ->
        {:error,
         "Unable to locate executable #{@exec} which is required to install with the rpm installer",
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
