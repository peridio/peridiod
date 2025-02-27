defmodule Peridiod.Binary.InstallerTest do
  use PeridiodTest.Case
  doctest Peridiod.Binary.Installer

  # alias Peridiod.Binary.Installer

  # defp start_installer(binary_metadata, opts) do
  #   opts = Map.put(opts, :callback, self())
  #   installer_mod = Installer.mod(binary_metadata)
  #   installer_opts = Installer.opts(binary_metadata) |> Map.merge(opts)
  #   Installer.start_link(binary_metadata, installer_mod, installer_opts)
  # end
end
