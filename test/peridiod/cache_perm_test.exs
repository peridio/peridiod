defmodule Peridiod.Cache.PermTest do
  use ExUnit.Case
  import ExUnit.CaptureLog
  import Bitwise, only: [band: 2]

  alias Peridiod.Cache

  defp base_config do
    struct(Peridiod.Config, Application.get_all_env(:peridiod)) |> Peridiod.Config.new()
  end

  test "warns and corrects when cache_dir has too-permissive mode" do
    cache_dir = "test/workspace/cache/perm_warn_mode"
    File.rm_rf!(cache_dir)
    File.mkdir_p!(cache_dir)
    File.chmod!(cache_dir, 0o755)

    config = Map.put(base_config(), :cache_dir, cache_dir)

    log =
      capture_log(fn ->
        {:ok, pid} = Cache.start_link(config, [])
        GenServer.stop(pid)
      end)

    assert log =~ "expected 0700"
    assert {:ok, %File.Stat{mode: mode}} = File.stat(cache_dir)
    assert band(mode, 0o777) == 0o700
  end

  test "creates cache_dir and log subdir at mode 0700 when missing" do
    cache_dir = "test/workspace/cache/perm_create"
    File.rm_rf!(cache_dir)

    config = Map.put(base_config(), :cache_dir, cache_dir)
    {:ok, pid} = Cache.start_link(config, [])
    GenServer.stop(pid)

    assert {:ok, %File.Stat{mode: cache_mode}} = File.stat(cache_dir)
    assert band(cache_mode, 0o777) == 0o700

    log_dir = Path.join(cache_dir, "log")
    assert {:ok, %File.Stat{mode: log_mode}} = File.stat(log_dir)
    assert band(log_mode, 0o777) == 0o700
  end
end
