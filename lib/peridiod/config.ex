defmodule Peridiod.Config do
  use Peridiod.Log

  def atomize_config(config) do
    %{
      "device_api" => %{
        "certificate_path" => cremini_device_api_certificate_path,
        "url" => cremini_device_api_url,
        "verify" => cremini_device_api_verify
      },
      "fwup" => %{
        "devpath" => cremini_fwup_devpath,
        "public_keys" => cremini_fwup_public_keys
      },
      "remote_shell" => cremini_remote_shell,
      "node" => %{
        "key_pair_source" => key_pair_source,
        "key_pair_config" => key_pair_config
      },
      "version" => 1
    } = config

    %{
      device_api: %{
        certificate_path: cremini_device_api_certificate_path,
        url: cremini_device_api_url,
        verify: cremini_device_api_verify
      },
      fwup: %{
        devpath: cremini_fwup_devpath,
        public_keys: cremini_fwup_public_keys
      },
      remote_shell: cremini_remote_shell,
      node: %{
        key_pair_source: key_pair_source,
        key_pair_config: key_pair_config
      }
    }
  end

  @doc """
  Dynamically resolves the default path for a `peridio-config.json` file.

  Environment variables below are expanded before this function returns.

  If `$XDG_CONFIG_HOME` is set:

  `$XDG_CONFIG_HOME/peridio/peridio-config.json`

  Else if `$HOME` is set:

  `$HOME/.config/peridio/peridio-config.json`
  """
  def default_path do
    System.fetch_env("XDG_CONFIG_HOME")
    |> case do
      {:ok, config_home} -> config_home
      :error -> Path.join(System.fetch_env!("HOME"), ".config")
    end
    |> Path.join("peridio/peridio-config.json")
  end

  def resolve_config do
    path =
      System.fetch_env("PERIDIO_CONFIG_FILE")
      |> case do
        {:ok, path} -> path
        :error -> default_path()
      end

    debug("using config path: #{path}")

    path
    |> File.read()
    |> case do
      {:ok, config_json} ->
        config_json

      {:error, e} ->
        error(%{message: "unable to read peridio config file", file_read_error: e})
        System.stop(1)
    end
    |> Jason.decode()
    |> case do
      {:ok, config} ->
        atomize_config(config)

      {:error, e} ->
        error(%{message: "unable to decode peridio config file", json_decode_error: e})
        raise {:error, :decode_json}
    end
  end
end
