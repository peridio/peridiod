defmodule Peridiod.Config do
  use Peridiod.Log

  alias PeridiodPersistence.KV
  alias Peridiod.{Cloud, Cache, SigningKey, Plan}
  alias __MODULE__

  require Logger

  defstruct cache_dir: "/var/lib/peridiod",
            cache_private_key: nil,
            cache_public_key: nil,
            cache_pid: Cache,
            cache_log_enabled: true,
            cache_log_max_bytes: 10_485_760,
            cache_log_max_files: 0,
            cache_log_compress: true,
            cache_log_level: :debug,
            device_api_host: "device.cremini.peridio.com",
            device_api_port: 443,
            device_api_sni: "device.cremini.peridio.com",
            device_api_verify: :verify_peer,
            device_api_ca_certificate_path: nil,
            key_pair_source: "env",
            key_pair_config: nil,
            kv_pid: KV,
            fwup_public_keys: [],
            fwup_devpath: "/dev/mmcblk0",
            fwup_env: [],
            fwup_extra_args: [],
            network_monitor: %{},
            params: %{},
            plan_server_pid: Plan.Server,
            reboot_delay: 5_000,
            reboot_cmd: "reboot",
            reboot_opts: [],
            reboot_sync_cmd: "sync",
            reboot_sync_opts: [],
            remote_shell: false,
            remote_iex: false,
            remote_access_tunnels: %{},
            update_poll_enabled: false,
            update_poll_interval: 300_000,
            update_resume_max_boot_count: 10,
            targets: ["portable"],
            trusted_signing_keys: [],
            trusted_signing_key_dir: nil,
            trusted_signing_key_threshold: 1,
            socket: [],
            socket_enabled?: true,
            ssl: []

  @type public_key :: :public_key.public_key()
  @type private_key :: :public_key.private_key()

  @type t() :: %__MODULE__{
          cache_dir: Path.t(),
          cache_private_key: private_key(),
          cache_public_key: public_key(),
          cache_pid: pid() | module(),
          cache_log_enabled: true,
          cache_log_max_bytes: non_neg_integer(),
          cache_log_max_files: non_neg_integer(),
          cache_log_compress: boolean(),
          cache_log_level: :debug | :info | :warning | :error,
          device_api_host: String.t(),
          device_api_port: String.t(),
          device_api_sni: charlist(),
          device_api_verify: :verify_peer | :verify_none,
          device_api_ca_certificate_path: Path.t(),
          key_pair_source: String.t(),
          key_pair_config: map,
          kv_pid: pid() | module(),
          fwup_public_keys: [binary()],
          fwup_devpath: Path.t(),
          fwup_env: [{String.t(), String.t()}],
          fwup_extra_args: [String.t()],
          network_monitor: NetworkMonitor.t(),
          params: map(),
          plan_server_pid: pid() | module(),
          reboot_delay: non_neg_integer,
          reboot_cmd: String.t(),
          reboot_opts: [String.t()],
          reboot_sync_cmd: String.t(),
          reboot_sync_opts: [String.t()],
          remote_shell: boolean,
          remote_iex: boolean,
          remote_access_tunnels: map(),
          update_poll_enabled: boolean,
          update_poll_interval: non_neg_integer(),
          targets: [String.t()],
          trusted_signing_keys: [SigningKey.t()],
          trusted_signing_key_dir: Path.t(),
          trusted_signing_key_threshold: non_neg_integer(),
          socket: any(),
          socket_enabled?: boolean,
          ssl: [:ssl.tls_client_option()]
        }

  @spec new(Config.t()) :: Config.t()
  def new(config) do
    config
    |> base_config()
    |> build_config(resolve_config())
    |> add_socket_opts()
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

  defp resolve_config do
    path = config_path()
    Logger.info("[Config] Using config path: #{path}")

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
      |> cache_log_merge_config(config_file)
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
      |> override_if_set(:cache_dir, config_file["cache_dir"])
      |> override_if_set(:device_api_host, host)
      |> override_if_set(:device_api_port, port)
      |> override_if_set(:device_api_verify, config_file["device_api"]["verify"])
      |> override_if_set(:fwup_devpath, config_file["fwup"]["devpath"])
      |> override_if_set(:fwup_public_keys, config_file["fwup"]["public_keys"])
      |> override_if_set(:fwup_env, config_file["fwup"]["env"])
      |> override_if_set(:fwup_extra_args, config_file["fwup"]["extra_args"])
      |> override_if_set(:reboot_delay, config_file["reboot_delay"])
      |> override_if_set(:reboot_cmd, config_file["reboot_cmd"])
      |> override_if_set(:reboot_opts, config_file["reboot_opts"])
      |> override_if_set(:reboot_sync_cmd, config_file["reboot_sync_cmd"])
      |> override_if_set(:reboot_sync_opts, config_file["reboot_sync_opts"])
      |> override_if_set(:remote_shell, config_file["remote_shell"])
      |> override_if_set(:remote_iex, config_file["remote_iex"])
      |> override_if_set(:network_monitor, config_file["network_monitor"])
      |> override_if_set(:key_pair_source, config_file["node"]["key_pair_source"])
      |> override_if_set(:key_pair_config, config_file["node"]["key_pair_config"])
      |> override_if_set(:socket_enabled?, config_file["socket_enabled?"])
      |> override_if_set(:targets, config_file["targets"])
      |> override_if_set(:trusted_signing_key_dir, config_file["trusted_signing_key_dir"])
      |> override_if_set(:trusted_signing_keys, config_file["trusted_signing_keys"])
      |> override_if_set(:update_poll_enabled, config_file["release_poll_enabled"])
      |> override_if_set(:update_poll_enabled, config_file["update_poll_enabled"])
      |> override_if_set(:update_poll_interval, config_file["release_poll_interval"])
      |> override_if_set(:update_poll_interval, config_file["update_poll_interval"])
      |> override_if_set(
        :update_resume_max_boot_count,
        config_file["update_resume_max_boot_count"]
      )
      |> override_if_set(
        :trusted_signing_key_threshold,
        config_file["trusted_signing_key_threshold"]
      )

    verify =
      case config.device_api_verify do
        true -> :verify_peer
        false -> :verify_none
        value when is_atom(value) -> value
      end

    network_monitor = Cloud.NetworkMonitor.config(config.network_monitor)
    trusted_signing_keys = Map.get(config, :trusted_signing_keys) |> load_trusted_signing_keys()

    config =
      config
      |> Map.put(:trusted_signing_keys, trusted_signing_keys)
      |> Map.put(:network_monitor, network_monitor)
      |> Map.put(:socket,
        url: "wss://#{config.device_api_host}:#{config.device_api_port}/socket/websocket"
      )
      |> Map.put(:ssl,
        server_name_indication: to_charlist(config.device_api_host),
        verify: verify,
        cacertfile: config.device_api_ca_certificate_path
      )

    case config.key_pair_source do
      "file" ->
        Peridiod.Config.File.config(config.key_pair_config, config)

      "pkcs11" ->
        Peridiod.Config.PKCS11.config(config.key_pair_config, config)

      "uboot-env" ->
        Peridiod.Config.UBootEnv.config(config.key_pair_config, config)

      "env" ->
        Peridiod.Config.Env.config(config.key_pair_config, config)

      type ->
        error("Unknown key pair type: #{type}")
    end
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
      data_dir: rat_config_file["data_dir"] || rat_config[:data_dir] || System.tmp_dir!(),
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

  def cache_log_merge_config(config, config_file) do
    log_level =
      case config_file["cache_log_level"] do
        nil -> config.cache_log_level
        string -> String.to_atom(string)
      end

    config
    |> Map.put(:cache_log_level, log_level)
    |> override_if_set(:cache_log_enabled, config_file["cache_log_enabled"])
    |> override_if_set(:cache_log_max_bytes, config_file["cache_log_max_bytes"])
    |> override_if_set(:cache_log_max_files, config_file["cache_log_max_files"])
    |> override_if_set(:cache_log_compress, config_file["cache_log_compress"])
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
        Cloud.Backoff.delay_list(1000, 60000, 0.50)
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

    %{base | socket: socket, ssl: ssl}
  end

  def load_trusted_signing_keys(trusted_signing_keys) do
    Enum.reduce(trusted_signing_keys, [], fn key, signing_keys ->
      case SigningKey.new(:ed25519, key) do
        {:ok, %SigningKey{} = signing_key} ->
          [signing_key | signing_keys]

        error ->
          Logger.error("[Config] Error loading signing key\n#{key}\nError: #{inspect(error)}")
          signing_keys
      end
    end)
  end
end
