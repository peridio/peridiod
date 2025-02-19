import Config

config :peridiod,
  client: Peridiod.Client.Default

config :peridio_rat, wireguard_client: Peridio.RAT.WireGuard.Default

import_config "#{Mix.env()}.exs"
