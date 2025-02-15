import Config

config :peridiod,
  client: Peridiod.Client.Default

config :peridio_rat, wireguard_client: Peridio.RAT.WireGuard.Default

config :peridio_net_mon,
  internet_host_list: [{"device.cremini.peridio.com", 443}]

import_config "#{Mix.env()}.exs"
