defmodule Peridiod.Binary.Installer.AvocadoOS do
  @moduledoc """
  Installer module for Avocado OS installations

  This installer acts as an intermediary that delegates to another installer
  based on the "type" specified in installer_opts.

  custom_metadata
  ```
  {
    "peridiod": {
      "installer": "avocado-os",
      "installer_opts": {
        "type": "file",
        "name": "filename.ext",
        "path": "/path/to/"
      },
      "reboot_required": false
    }
  }
  ```

  The "type" field specifies which sub-installer to use (e.g., "file", "fwup", "deb", etc.)
  All other installer_opts are passed through to the sub-installer.
  """

  use Peridiod.Binary.Installer

  alias Peridiod.Binary.Installer

  @type_to_module %{
    "cache" => Installer.Cache,
    "fwup" => Installer.Fwup,
    "file" => Installer.File,
    "deb" => Installer.Deb,
    "rpm" => Installer.Rpm,
    "opkg" => Installer.Opkg,
    "swupdate" => Installer.SWUpdate
  }

  def execution_model(), do: :sequential

  # Default interfaces when we don't know the sub-type yet
  def interfaces(), do: [:path, :stream]

  # Get interfaces from the sub-module based on "type" in opts
  def interfaces(%{"type" => type}) do
    case get_sub_module(type) do
      {:ok, sub_mod} -> sub_mod.interfaces()
      {:error, _} -> [:path, :stream]
    end
  end

  def interfaces(_opts), do: [:path, :stream]

  def path_install(binary_metadata, path, %{"type" => type} = opts) do
    sub_opts = Map.delete(opts, "type")

    case get_sub_module(type) do
      {:ok, sub_mod} ->
        sub_mod.path_install(binary_metadata, path, sub_opts)

      {:error, _} = error ->
        {error, nil}
    end
  end

  def path_install(_binary_metadata, _path, _opts) do
    {:error, "AvocadoOS installer_opts key type is required", nil}
  end

  def stream_init(binary_metadata, %{"type" => type} = opts) do
    sub_opts = Map.delete(opts, "type")

    case get_sub_module(type) do
      {:ok, sub_mod} ->
        case sub_mod.stream_init(binary_metadata, sub_opts) do
          {:ok, sub_state} ->
            {:ok, {sub_mod, sub_state}}

          {:error, reason, sub_state} ->
            {:error, reason, {sub_mod, sub_state}}

          {:error, reason} ->
            {:error, reason, nil}
        end

      {:error, reason} ->
        {:error, reason, nil}
    end
  end

  def stream_init(_binary_metadata, _opts) do
    {:error, "AvocadoOS installer_opts key type is required", nil}
  end

  def stream_update(binary_metadata, data, {sub_mod, sub_state}) do
    case sub_mod.stream_update(binary_metadata, data, sub_state) do
      {:ok, new_sub_state} ->
        {:ok, {sub_mod, new_sub_state}}

      {:error, reason, new_sub_state} ->
        {:error, reason, {sub_mod, new_sub_state}}
    end
  end

  def stream_finish(binary_metadata, validity, hash, {sub_mod, sub_state}) do
    case sub_mod.stream_finish(binary_metadata, validity, hash, sub_state) do
      {:stop, reason, new_sub_state} ->
        {:stop, reason, {sub_mod, new_sub_state}}

      {:noreply, new_sub_state} ->
        {:noreply, {sub_mod, new_sub_state}}

      {:error, reason, new_sub_state} ->
        {:error, reason, {sub_mod, new_sub_state}}
    end
  end

  def stream_error(binary_metadata, error, {sub_mod, sub_state}) do
    case sub_mod.stream_error(binary_metadata, error, sub_state) do
      {:error, reason, new_sub_state} ->
        {:error, reason, {sub_mod, new_sub_state}}
    end
  end

  def stream_info(msg, {sub_mod, sub_state}) do
    case sub_mod.stream_info(msg, sub_state) do
      {:ok, new_sub_state} ->
        {:ok, {sub_mod, new_sub_state}}

      {:stop, reason, new_sub_state} ->
        {:stop, reason, {sub_mod, new_sub_state}}

      {:error, reason, new_sub_state} ->
        {:error, reason, {sub_mod, new_sub_state}}
    end
  end

  defp get_sub_module(type) do
    case Map.get(@type_to_module, type) do
      nil -> {:error, "AvocadoOS unknown installer type: #{inspect(type)}"}
      mod -> {:ok, mod}
    end
  end
end
