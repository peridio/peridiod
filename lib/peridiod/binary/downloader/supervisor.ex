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

    child_spec =
      case Keyword.get(opts, :verify_config) do
        nil ->
          Downloader.child_spec(id, parsed_uri, fun, retry_config)

        %Downloader.VerifyConfig{} = verify_config ->
          Downloader.child_spec(id, parsed_uri, fun, retry_config, verify_config)

        invalid ->
          raise ArgumentError,
                "expected :verify_config to be nil or %Peridiod.Binary.Downloader.VerifyConfig{}, " <>
                  "got: #{inspect(invalid)}"
      end

    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
