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

  use Peridiod.Binary.Installer

  alias Peridiod.Utils

  require Logger

  def execution_model(), do: :sequential
  def interfaces(), do: [:path]

  def path_install(_binary_metadata, path, opts) do
    case Utils.exec_installed?(@exec) do
      false ->
        {:error,
         "Unable to locate executable #{@exec} which is required to install with the swupdate installer",
         nil}

      true ->
        extra_args = opts["extra_args"] || []

        case System.cmd("swupdate", ["-i", path] ++ extra_args) do
          {_result, 0} ->
            {:stop, :normal, nil}

          {error, _} ->
            {:error, error, nil}
        end
    end
  end
end
