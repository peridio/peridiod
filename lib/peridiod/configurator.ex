defmodule Peridiod.Configurator do
  use Peridiod.Log
  use GenServer

  alias Peridiod.Backoff
  alias __MODULE__

  require Logger

  @device_api_version "1.0.0"
  @console_version "1.0.0"

  defmodule Config do
    defstruct device_api_host: "device.nerves-hub.org",
              device_api_port: 443,
              device_api_sni: "device.nerves-hub.org",
              fwup_public_keys: [],
              fwup_devpath: "/dev/mmcblk0",
              fwup_env: [],
              nerves_key: [],
              params: %{},
              remote_iex: false,
              socket: [],
              ssl: []

    @type t() :: %__MODULE__{
            device_api_host: String.t(),
            device_api_port: String.t(),
            device_api_sni: charlist(),
            fwup_public_keys: [binary()],
            fwup_devpath: Path.t(),
            fwup_env: [{String.t(), String.t()}],
            nerves_key: any(),
            params: map(),
            remote_iex: boolean,
            socket: any(),
            ssl: [:ssl.tls_client_option()]
          }
  end

  @callback build(%Config{}) :: Config.t()


  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def get_config() do
    GenServer.call(__MODULE__, :get_config)
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

  def init(nil) do
    {:ok, build()}
  end

  def handle_call(:get_config, _from, config) do
    {:reply, config, config}
  end

  @spec build :: Config.t()
  defp build() do
    resolve_config()
    |> build_config(base_config())
    |> add_socket_opts()
  end

  defp atomize_config(config) do
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

  defp resolve_config do
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

  defp build_config(peridio_config, base_config) do
    verify =
      case peridio_config.device_api.verify do
        true -> :verify_peer
        false -> :verify_none
      end
    config =
    %{
      base_config
      | device_api_host: peridio_config.device_api.url,
        device_api_sni: peridio_config.device_api.url,
        fwup_devpath: peridio_config.fwup.devpath,
        fwup_public_keys: peridio_config.fwup.public_keys,
        socket: [url: "wss://#{peridio_config.device_api.url}:443/socket/websocket"],
        remote_iex: peridio_config.remote_shell,
        ssl: [
          server_name_indication: to_charlist(peridio_config.device_api.url),
          verify: verify,
          cacertfile: peridio_config.device_api.certificate_path,
        ]
    }

    case peridio_config.node.key_pair_source do
      "file" ->
        Configurator.File.config(peridio_config.node.key_pair_config, config)
      "pkcs11" ->
        Configurator.PKCS11.config(peridio_config.node.key_pair_config, config)
      type ->
        Logger.error("Unknown key pair type: #{type}")
    end
  end

  defp add_socket_opts(config) do
    # PhoenixClient requires these SSL options be passed as
    # [transport_opts: [socket_opts: ssl]]. So for convenience,
    # we'll bundle it all here as expected without overriding
    # any other items that may have been provided in :socket or
    # :transport_opts keys previously.
    transport_opts = config.socket[:transport_opts] || []
    transport_opts = Keyword.put(transport_opts, :socket_opts, config.ssl)

    socket =
      config.socket
      |> Keyword.put(:transport_opts, transport_opts)
      |> Keyword.put_new_lazy(:reconnect_after_msec, fn ->
        # Default retry interval
        # 1 second minimum delay that doubles up to 60 seconds. Up to 50% of
        # the delay is added to introduce jitter into the retry attempts.
        Backoff.delay_list(1000, 60000, 0.50)
      end)

    %{config | socket: socket}
  end

  defp base_config() do
    base = struct(Config, Application.get_all_env(:peridiod))

    url = "wss://#{base.device_api_host}:#{base.device_api_port}/socket/websocket"

    socket = Keyword.put_new(base.socket, :url, url)

    ssl =
      base.ssl
      |> Keyword.put_new(:verify, :verify_peer)
      |> Keyword.put_new(:versions, [:"tlsv1.2"])
      |> Keyword.put_new(:server_name_indication, to_charlist(base.device_api_sni))

    fwup_devpath = Peridiod.KV.get("peridio_disk_devpath") || Peridiod.KV.get("nerves_fw_devpath")
    peridio_uuid = Peridiod.KV.get_active("peridio_uuid") || Peridiod.KV.get_active("nerves_fw_uuid")
    params =
      Peridiod.KV.get_all_active()
      |> Map.put("nerves_fw_uuid", peridio_uuid)
      |> Map.put("fwup_version", fwup_version())
      |> Map.put("device_api_version", @device_api_version)
      |> Map.put("console_version", @console_version)

    %{base | params: params, socket: socket, ssl: ssl, fwup_devpath: fwup_devpath}
  end

  defp fwup_version do
    {version_string, 0} = System.cmd("fwup", ["--version"])
    String.trim(version_string)
  end
end
