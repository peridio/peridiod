defmodule Peridiod.Configurator do
  use Peridiod.Log
  use GenServer

  alias Peridiod.Backoff
  alias __MODULE__

  require Logger

  @device_api_version "1.0.0"
  @console_version "1.0.0"

  defmodule Config do
    defstruct device_api_host: "device.cremini.peridio.com",
              device_api_port: 443,
              device_api_sni: "device.cremini.peridio.com",
              device_api_verify: :verify_peer,
              device_api_ca_certificate_path: nil,
              key_pair_source: "env",
              key_pair_config: %{"private_key" => nil, "certificate" => nil},
              fwup_public_keys: [],
              fwup_devpath: "/dev/mmcblk0",
              fwup_env: [],
              fwup_extra_args: [],
              params: %{},
              remote_shell: false,
              remote_iex: false,
              remote_access_tunnels: %{},
              socket: [],
              ssl: [],
              sdk_client: nil

    @type t() :: %__MODULE__{
            device_api_host: String.t(),
            device_api_port: String.t(),
            device_api_sni: charlist(),
            device_api_verify: :verify_peer | :verify_none,
            device_api_ca_certificate_path: Path.t(),
            fwup_public_keys: [binary()],
            fwup_devpath: Path.t(),
            fwup_env: [{String.t(), String.t()}],
            fwup_extra_args: [String.t()],
            params: map(),
            remote_iex: boolean,
            remote_shell: boolean,
            remote_access_tunnels: map(),
            socket: any(),
            ssl: [:ssl.tls_client_option()],
            sdk_client: %{}
          }
  end

  @callback build(%Config{}) :: Config.t()

  def start_link(%Config{} = config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
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

  def init(%Config{} = config) do
    {:ok, build(config)}
  end

  def handle_call(:get_config, _from, config) do
    {:reply, config, config}
  end

  @spec build(Config.t()) :: Config.t()
  defp build(config) do
    config
    |> base_config()
    |> build_config(resolve_config())
    |> add_socket_opts()
  end

  defp resolve_config do
    path = config_path()
    debug("using config path: #{path}")

    with {:ok, file} <- File.read(path),
         {:ok, config} <- Jason.decode(file) do
      config
    else
      {:error, e} ->
        warn(%{message: "unable to read peridio config file", file_read_error: e})
        %{}
    end
  end

  defp config_path() do
    System.get_env("PERIDIO_CONFIG_FILE", default_path())
  end

  defp build_config(%Config{} = config, config_file) do
    {host, port} =
      case config_file["device_api"]["url"] do
        nil ->
          {nil, nil}

        url ->
          parts = String.split(url, ":")
          {Enum.at(parts, 0), Enum.at(parts, 1)}
      end

    config =
      config
      |> Map.put(
        :device_api_ca_certificate_path,
        Application.app_dir(:peridiod, "priv/peridio-cert.pem")
      )
      |> Map.put(
        :remote_access_tunnels,
        rat_merge_config(
          config.remote_access_tunnels,
          Map.get(config_file, "remote_access_tunnels", %{})
        )
      )
      |> override_if_set(
        :device_api_ca_certificate_path,
        config_file["device_api"]["certificate_path"]
      )
      |> override_if_set(:device_api_host, host)
      |> override_if_set(:device_api_port, port)
      |> override_if_set(:device_api_verify, config_file["device_api"]["verify"])
      |> override_if_set(:fwup_devpath, config_file["fwup"]["devpath"])
      |> override_if_set(:fwup_public_keys, config_file["fwup"]["public_keys"])
      |> override_if_set(:fwup_env, config_file["fwup"]["env"])
      |> override_if_set(:fwup_extra_args, config_file["fwup"]["extra_args"])
      |> override_if_set(:remote_shell, config_file["remote_shell"])
      |> override_if_set(:remote_iex, config_file["remote_iex"])
      |> override_if_set(:key_pair_source, config_file["node"]["key_pair_source"])
      |> override_if_set(:key_pair_config, config_file["node"]["key_pair_config"])

    verify =
      case config.device_api_verify do
        true -> :verify_peer
        false -> :verify_none
        value when is_atom(value) -> value
      end

    config =
      config
      |> Map.put(:socket,
        url: "wss://#{config.device_api_host}:#{config.device_api_port}/socket/websocket"
      )
      |> Map.put(:ssl,
        server_name_indication: to_charlist(config.device_api_host),
        verify: verify,
        cacertfile: config.device_api_ca_certificate_path
      )

    config =
      case config.key_pair_source do
        "file" ->
          Configurator.File.config(config.key_pair_config, config)

        "pkcs11" ->
          Configurator.PKCS11.config(config.key_pair_config, config)

        "uboot-env" ->
          Configurator.UBootEnv.config(config.key_pair_config, config)

        "env" ->
          Configurator.Env.config(config.key_pair_config, config)

        type ->
          error("Unknown key pair type: #{type}")
      end

    adapter = {Tesla.Adapter.Mint, transport_opts: config.ssl}

    sdk_client =
      PeridioSDK.Client.new(
        device_api_host: "https://#{config.device_api_host}",
        adapter: adapter,
        release_prn: "",
        release_version: ""
      )

    Map.put(config, :sdk_client, sdk_client)
  end

  defp override_if_set(%{} = config, _key, value) when is_nil(value), do: config
  defp override_if_set(%{} = config, key, value), do: Map.replace(config, key, value)

  def rat_merge_config(rat_config, rat_config_file) do
    hooks_config = Map.get(rat_config, :hooks, %{})

    hooks =
      rat_default_hooks()
      |> Map.merge(hooks_config)
      |> override_if_set(:pre_up, rat_config_file["hooks"]["pre_up"])
      |> override_if_set(:post_up, rat_config_file["hooks"]["post_up"])
      |> override_if_set(:pre_down, rat_config_file["hooks"]["pre_down"])
      |> override_if_set(:post_down, rat_config_file["hooks"]["post_down"])

    %{
      enabled: rat_config_file["enabled"] || rat_config[:enabled] || false,
      port_range:
        (rat_config_file["port_range"] || rat_config[:port_range]) |> encode_port_range(),
      ipv4_cidrs:
        (rat_config_file["ipv4_cidrs"] || rat_config[:ipv4_cidrs]) |> encode_ipv4_cidrs(),
      service_ports: rat_config_file["service_ports"] || rat_config[:service_ports] || [],
      persistent_keepalive:
        rat_config_file["persistent_keepalive"] || rat_config[:persistent_keepalive] || 25,
      hooks: hooks
    }
  end

  def rat_default_hooks() do
    priv_dir = Application.app_dir(:peridiod, "priv")

    %{
      pre_up: "#{priv_dir}/pre-up.sh",
      post_up: "#{priv_dir}/post-up.sh",
      pre_down: "#{priv_dir}/pre-down.sh",
      post_down: "#{priv_dir}/post-down.sh"
    }
  end

  def encode_port_range(nil), do: Peridio.RAT.Network.default_port_ranges()

  def encode_port_range(range) do
    [r_start, r_end] = String.split(range, "-") |> Enum.map(&String.to_integer/1)
    Range.new(r_start, r_end)
  end

  def encode_ipv4_cidrs(nil), do: Peridio.RAT.Network.default_ip_address_cidrs()

  def encode_ipv4_cidrs([_ | _] = cidrs) do
    Enum.map(cidrs, &Peridio.RAT.Network.CIDR.from_string!/1)
  end

  def deep_merge(map1, map2) when is_map(map1) and is_map(map2) do
    Map.merge(map1, map2, fn _key, val1, val2 ->
      deep_merge(val1, val2)
    end)
  end

  def deep_merge(_val1, val2), do: val2

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

  defp base_config(base) do
    url = "wss://#{base.device_api_host}:#{base.device_api_port}/socket/websocket"

    socket = Keyword.put_new(base.socket, :url, url)

    ssl =
      base.ssl
      |> Keyword.put_new(:verify, :verify_peer)
      |> Keyword.put_new(:versions, [:"tlsv1.2"])
      |> Keyword.put_new(:server_name_indication, to_charlist(base.device_api_sni))

    fwup_devpath = Peridiod.KV.get("peridio_disk_devpath") || Peridiod.KV.get("nerves_fw_devpath")

    peridio_uuid =
      Peridiod.KV.get_active("peridio_uuid") || Peridiod.KV.get_active("nerves_fw_uuid")

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
