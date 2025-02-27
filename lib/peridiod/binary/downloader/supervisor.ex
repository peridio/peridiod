defmodule Peridiod.Binary.Downloader.Supervisor do
  use DynamicSupervisor

  alias Peridiod.Binary.Downloader
  alias Peridiod.Binary.Downloader.RetryConfig

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  def start_child(id, %URI{} = uri, fun) do
    child_spec = Downloader.child_spec(id, uri, fun, %RetryConfig{})
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  def start_child(id, url, fun) when is_binary(url) do
    child_spec = Downloader.child_spec(id, URI.parse(url), fun, %RetryConfig{})
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
