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

  def start_child(id, uri, fun, opts) when is_list(opts) do
    parsed_uri = if is_binary(uri), do: URI.parse(uri), else: uri
    retry_config = Keyword.get(opts, :retry_config, %RetryConfig{})
    verify_config = Keyword.get(opts, :verify_config)

    child_spec =
      if verify_config do
        Downloader.child_spec(id, parsed_uri, fun, retry_config, verify_config)
      else
        Downloader.child_spec(id, parsed_uri, fun, retry_config)
      end

    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
