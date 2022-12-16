defmodule Peridiod.KVBackend.InMemory do
  @moduledoc """
  In-memory KV store

  This KV store keeps everything in memory. Use it by specifying it
  as a backend in the application configuration. Specifying an initial
  set of contents is optional.

  ```elixir
  config :peridiod, :kv_backend, {Peridiod.KV.InMemory, contents: %{"key" => "value"}}
  ```
  """
  @behaviour Peridiod.KVBackend

  @impl Peridiod.KVBackend
  def load(options) do
    case Keyword.fetch(options, :contents) do
      {:ok, contents} when is_map(contents) -> {:ok, contents}
      _ -> {:ok, %{}}
    end
  end

  @impl Peridiod.KVBackend
  def save(_new_state, _options), do: :ok
end
