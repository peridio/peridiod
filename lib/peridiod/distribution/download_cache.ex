defmodule Peridiod.Distribution.DownloadCache do
  use Peridiod.Cache.Helpers, cache_path: "downloads", cache_file: "firmware.bin"

  alias Peridiod.Cache

  # Use uuid as the identifier for legacy download caching
  def cache_path(%{uuid: uuid}) when is_binary(uuid), do: cache_path(uuid)
  def cache_path(uuid) when is_binary(uuid), do: Path.join(cache_path(), uuid)

  def cache_file(%{uuid: uuid}) when is_binary(uuid), do: cache_file(uuid)
  def cache_file(uuid) when is_binary(uuid), do: Path.join(cache_path(uuid), "firmware.bin")

  @doc """
  Path to the in-progress download file (with .part suffix).
  """
  def part_file(%{uuid: uuid}) do
    part_file(uuid)
  end

  def part_file(uuid) when is_binary(uuid) do
    cache_file(uuid) <> ".part"
  end

  @doc """
  Path to a specific chunk file used by the parallel downloader.
  """
  def chunk_file(%{uuid: uuid}, index) when is_integer(index) do
    chunk_file(uuid, index)
  end

  def chunk_file(uuid, index) when is_binary(uuid) and is_integer(index) do
    chunk_suffix = String.pad_leading(Integer.to_string(index), 4, "0")
    cache_file(uuid) <> ".part" <> chunk_suffix
  end

  @doc """
  Ensure the directory for the cache file exists.
  """
  def ensure_dir(cache_pid \\ Cache, uuid) do
    cache_file = cache_file(uuid)
    dir = Path.dirname(cache_file)

    Cache.abs_path(cache_pid, dir)
    |> File.mkdir_p()
  end
end
