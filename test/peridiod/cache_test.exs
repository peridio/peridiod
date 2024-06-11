defmodule Peridiod.CacheTest do
  use PeridiodTest.Case
  doctest Peridiod.Cache

  alias Peridiod.Cache

  setup context do
    application_config = Application.get_all_env(:peridiod)
    config = struct(Peridiod.Config, application_config) |> Peridiod.Config.new()
    cache_dir = "test/workspace/cache/#{context.test}"
    config = Map.put(config, :cache_dir, cache_dir)
    {:ok, cache_pid} = Cache.start_link(config, [])

    {:ok, %{cache_pid: cache_pid, cache_dir: cache_dir}}
  end

  test "write read valid", %{cache_pid: cache_pid, test: name} do
    file = to_string(name)
    content = to_string(name)
    :ok = Cache.write(cache_pid, file, content)
    assert {:ok, ^content} = Cache.read(cache_pid, file)
  end

  test "write read invalid", %{cache_pid: cache_pid, cache_dir: cache_dir, test: name} do
    file = to_string(name)
    content = to_string(name)
    :ok = Cache.write(cache_pid, file, content)
    file_sig_path = Path.join(cache_dir, file <> ".sig")

    File.write(file_sig_path, "")
    assert {:error, :invalid_signature} = Cache.read(cache_pid, file)

    File.write(file_sig_path, "null")
    assert {:error, :invalid_signature} = Cache.read(cache_pid, file)
  end

  test "write read stream", %{cache_pid: cache_pid, test: name} do
    file = to_string(name)
    content = to_string(name)
    :ok = Cache.write(cache_pid, file, content)

    Cache.read_stream(cache_pid, file) |> Enum.map(&send(self(), &1))
    assert_receive {:eof, :valid_signature, _hash}
  end

  test "write read stream no cache", %{cache_pid: cache_pid, test: name} do
    file = to_string(name)
    assert {:error, :enoent} = Cache.read_stream(cache_pid, file)
  end

  test "exists invalid", %{cache_pid: cache_pid, cache_dir: cache_dir, test: name} do
    file = to_string(name)
    content = to_string(name)
    :ok = Cache.write(cache_pid, file, content)

    file_sig_path = Path.join(cache_dir, file <> ".sig")
    File.write(file_sig_path, "")

    refute Cache.exists?(cache_pid, file)
  end

  test "write read missing file", %{cache_pid: cache_pid, cache_dir: cache_dir, test: name} do
    file = to_string(name)
    content = to_string(name)
    :ok = Cache.write(cache_pid, file, content)

    file_path = Path.join(cache_dir, file)
    File.rm!(file_path)
    assert {:error, :enoent} = Cache.read(cache_pid, file)
  end

  test "write read missing signature", %{cache_pid: cache_pid, cache_dir: cache_dir, test: name} do
    file = to_string(name)
    content = to_string(name)
    :ok = Cache.write(cache_pid, file, content)

    file_sig_path = Path.join(cache_dir, file <> ".sig")
    File.rm!(file_sig_path)
    assert {:error, :enoent} = Cache.read(cache_pid, file)
  end

  test "link exists", %{cache_pid: cache_pid, cache_dir: cache_dir, test: name} do
    file = to_string(name)
    content = to_string(name)
    link = to_string(name) <> " link"

    :ok = Cache.write(cache_pid, file, content)
    :ok = Cache.ln_s(cache_pid, file, link)
    assert {:ok, ^content} = File.read(Path.join([cache_dir, link]))
  end
end
