defmodule Peridiod.Cache.DekTest do
  use ExUnit.Case
  import ExUnit.CaptureLog
  import Bitwise, only: [band: 2]

  alias Peridiod.Cache

  defp base_config do
    struct(Peridiod.Config, Application.get_all_env(:peridiod)) |> Peridiod.Config.new()
  end

  setup context do
    cache_dir = "test/workspace/cache/#{context.test}"
    File.rm_rf!(cache_dir)
    on_exit(fn -> File.rm_rf!(cache_dir) end)
    {:ok, cache_dir: cache_dir}
  end

  test "regenerates the DEK when .dek is empty", %{cache_dir: cache_dir} do
    {pid, log, old_dek} =
      restart_with_corrupt_dek(cache_dir, fn ->
        File.write!(Path.join(cache_dir, ".dek"), "")
      end)

    assert log =~ "Failed to load DEK: :invalid_dek_size"
    assert_dek_regenerated(pid, cache_dir, old_dek)
  end

  test "regenerates the DEK when .dek is truncated", %{cache_dir: cache_dir} do
    {pid, log, old_dek} =
      restart_with_corrupt_dek(cache_dir, fn ->
        dek_path = Path.join(cache_dir, ".dek")
        File.write!(dek_path, binary_part(File.read!(dek_path), 0, 31))
      end)

    assert log =~ "Failed to load DEK: :invalid_dek_size"
    assert_dek_regenerated(pid, cache_dir, old_dek)
  end

  test "regenerates the DEK when .dek.sig is malformed", %{cache_dir: cache_dir} do
    {pid, log, old_dek} =
      restart_with_corrupt_dek(cache_dir, fn ->
        File.write!(Path.join(cache_dir, ".dek.sig"), "not hex")
      end)

    assert log =~ "Failed to load DEK: :invalid_dek_signature_format"
    assert_dek_regenerated(pid, cache_dir, old_dek)
  end

  test "regenerates the DEK when the DEK signature is invalid", %{cache_dir: cache_dir} do
    {pid, log, old_dek} =
      restart_with_corrupt_dek(cache_dir, fn ->
        File.write!(Path.join(cache_dir, ".dek"), :crypto.strong_rand_bytes(32))
      end)

    assert log =~ "DEK signature invalid"
    assert log =~ "investigate for potential tampering"
    assert_dek_regenerated(pid, cache_dir, old_dek)
  end

  test "regenerated DEK loads cleanly on the next start", %{cache_dir: cache_dir} do
    {pid, _log, _old_dek} =
      restart_with_corrupt_dek(cache_dir, fn ->
        File.write!(Path.join(cache_dir, ".dek"), "")
      end)

    :ok = Cache.write(pid, "new", "new content")
    GenServer.stop(pid)

    {:ok, pid} = Cache.start_link(Map.put(base_config(), :cache_dir, cache_dir), [])
    assert {:ok, "new content"} = Cache.read(pid, "new")
    GenServer.stop(pid)
  end

  test "writes .dek and .dek.sig at mode 0600 with no temp files", %{cache_dir: cache_dir} do
    {:ok, pid} = Cache.start_link(Map.put(base_config(), :cache_dir, cache_dir), [])
    GenServer.stop(pid)

    for name <- [".dek", ".dek.sig"] do
      assert {:ok, %File.Stat{mode: mode}} = File.stat(Path.join(cache_dir, name))
      assert band(mode, 0o777) == 0o600
    end

    assert byte_size(File.read!(Path.join(cache_dir, ".dek"))) == 32
    refute File.exists?(Path.join(cache_dir, ".dek.tmp"))
    refute File.exists?(Path.join(cache_dir, ".dek.sig.tmp"))
  end

  defp restart_with_corrupt_dek(cache_dir, corrupt_fun) do
    {:ok, pid} = Cache.start_link(Map.put(base_config(), :cache_dir, cache_dir), [])
    :ok = Cache.write(pid, "old", "old content")
    GenServer.stop(pid)

    old_dek = File.read!(Path.join(cache_dir, ".dek"))
    corrupt_fun.()

    log =
      capture_log(fn ->
        {:ok, pid} = Cache.start_link(Map.put(base_config(), :cache_dir, cache_dir), [])
        send(self(), {:cache_pid, pid})
      end)

    assert_received {:cache_pid, pid}
    {pid, log, old_dek}
  end

  defp assert_dek_regenerated(pid, cache_dir, old_dek) do
    new_dek = File.read!(Path.join(cache_dir, ".dek"))
    assert byte_size(new_dek) == 32
    assert new_dek != old_dek

    for name <- [".dek", ".dek.sig"] do
      assert {:ok, %File.Stat{mode: mode}} = File.stat(Path.join(cache_dir, name))
      assert band(mode, 0o777) == 0o600
    end

    refute File.exists?(Path.join(cache_dir, ".dek.tmp"))
    refute File.exists?(Path.join(cache_dir, ".dek.sig.tmp"))

    refute File.exists?(Path.join(cache_dir, "old"))
    refute File.exists?(Path.join(cache_dir, "old.sig"))
    assert {:error, :enoent} = Cache.read(pid, "old")

    :ok = Cache.write(pid, "new", "new content")
    assert {:ok, "new content"} = Cache.read(pid, "new")
    GenServer.stop(pid)
  end
end
