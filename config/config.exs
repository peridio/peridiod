import Config
alias Peridiod.Configurator
alias Peridiod.Link

config :nerves_hub_link,
  client: Peridiod.Link,
  configurator: Peridiod.Configurator
