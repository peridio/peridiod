defmodule Peridiod.Cache.PermTest do
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

  test "warns and corrects when cache_dir has too-permissive mode", %{cache_dir: cache_dir} do
    File.mkdir_p!(cache_dir)
    File.chmod!(cache_dir, 0o755)

    log =
      capture_log(fn ->
        {:ok, pid} = Cache.start_link(Map.put(base_config(), :cache_dir, cache_dir), [])
        GenServer.stop(pid)
      end)

    assert log =~ "expected 0700"
    assert {:ok, %File.Stat{mode: mode}} = File.stat(cache_dir)
    assert band(mode, 0o777) == 0o700
  end

  test "creates cache_dir and log subdir at mode 0700 when missing", %{cache_dir: cache_dir} do
    {:ok, pid} = Cache.start_link(Map.put(base_config(), :cache_dir, cache_dir), [])
    GenServer.stop(pid)

    assert {:ok, %File.Stat{mode: cache_mode}} = File.stat(cache_dir)
    assert band(cache_mode, 0o777) == 0o700

    log_dir = Path.join(cache_dir, "log")
    assert {:ok, %File.Stat{mode: log_mode}} = File.stat(log_dir)
    assert band(log_mode, 0o777) == 0o700
  end

  test "warns but does not chmod when cache_dir is a symlink with permissive target",
       %{cache_dir: cache_dir} do
    target_dir = cache_dir <> "_target"
    on_exit(fn -> File.rm_rf!(target_dir) end)
    File.rm_rf!(target_dir)
    File.mkdir_p!(target_dir)
    File.chmod!(target_dir, 0o755)
    File.ln_s!(Path.expand(target_dir), cache_dir)

    log =
      capture_log(fn ->
        {:ok, pid} = Cache.start_link(Map.put(base_config(), :cache_dir, cache_dir), [])
        GenServer.stop(pid)
      end)

    assert log =~ "is a symlink"
    assert log =~ "0700"

    # target mode must NOT be corrected — no chmod through symlink
    assert {:ok, %File.Stat{mode: target_mode}} = File.stat(target_dir)
    assert band(target_mode, 0o777) == 0o755

    # log subdir must NOT be created inside the symlink target
    refute File.exists?(Path.join(target_dir, "log"))
  end
end
