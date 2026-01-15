defmodule Peridiod.Binary.ParallelDownloaderTest do
  @moduledoc """
  Tests for ParallelDownloader.

  Note: Fatal HTTP error propagation tests are in test/peridiod/distribution/download_test.exs
  as integration tests. Testing ParallelDownloader directly for fatal errors causes ExUnit
  cleanup race conditions because the process exits before ExUnit can clean it up.
  The integration tests use Distribution.Server which properly manages the lifecycle.
  """
  use PeridiodTest.Case
  alias Peridiod.Binary.ParallelDownloader
  alias Peridiod.Binary.Downloader.RetryConfig
  alias Peridiod.Binary.ParallelDownloaderTest.FakeCache

  describe "successful parallel download" do
    setup :start_cache

    @tag capture_log: true
    test "downloads file in parallel chunks and sends chunk_complete events", %{
      cache_pid: cache_pid
    } do
      test_pid = self()
      completed_chunks = :counters.new(1, [])

      handler_fun = fn
        {:chunk_complete, chunk_number, rel_path} ->
          :counters.add(completed_chunks, 1, 1)
          send(test_pid, {:handler_received, {:chunk_complete, chunk_number, rel_path}})

        {:progress, _progress} ->
          :ok

        :complete ->
          send(test_pid, {:handler_received, :complete})

        {:error, reason} ->
          send(test_pid, {:handler_received, {:error, reason}})

        {:fatal_http_error, status, uri} ->
          send(test_pid, {:handler_received, {:fatal_http_error, status, uri}})
      end

      # Download a 1MB file in 256KB chunks with 2 parallel downloads
      url = "http://localhost:4001/1M.bin"
      total_size = 1_048_576
      chunk_size = 262_144

      {:ok, downloader_pid} =
        ParallelDownloader.start_link(
          "test-parallel-success",
          url,
          total_size,
          chunk_size,
          2,
          "test-parallel-success.bin",
          cache_pid,
          handler_fun,
          %RetryConfig{}
        )

      ref = Process.monitor(downloader_pid)

      # Should receive chunk complete events
      assert_receive {:handler_received, {:chunk_complete, _, _}}, 5000

      # Should eventually complete
      assert_receive {:handler_received, :complete}, 15000

      # Should exit normally
      assert_receive {:DOWN, ^ref, :process, ^downloader_pid, :normal}, 2000

      # Should have completed 4 chunks (1MB / 256KB = 4)
      count = :counters.get(completed_chunks, 1)
      assert count == 4
    end
  end

  describe "file write error handling" do
    setup :start_cache

    @tag capture_log: true
    test "restarts chunk after initial file write error", %{cache_dir: cache_dir} do
      test_pid = self()

      {:ok, fake_cache_pid} = FakeCache.start_link(cache_dir)

      handler_fun = fn
        {:progress, _progress} ->
          :ok

        :complete ->
          send(test_pid, {:handler_received, :complete})

        _ ->
          :ok
      end

      url = "http://localhost:4001/1M.bin"
      total_size = 1_048_576
      chunk_size = 524_288
      final_rel_path = "test-parallel-write-error.bin"

      {:ok, downloader_pid} =
        ParallelDownloader.start_link(
          "test-parallel-write-error",
          url,
          total_size,
          chunk_size,
          2,
          final_rel_path,
          fake_cache_pid,
          handler_fun,
          %RetryConfig{}
        )

      ref = Process.monitor(downloader_pid)

      # Initial write fails (simulated), restart should allow completion
      assert_receive {:handler_received, :complete}, 15000

      # Should exit normally
      assert_receive {:DOWN, ^ref, :process, ^downloader_pid, :normal}, 2000
    end
  end

  describe "oversized chunk handling" do
    setup :start_cache

    @tag capture_log: true
    test "oversized chunk files are cleaned up on fresh download", %{
      cache_pid: cache_pid,
      cache_dir: cache_dir
    } do
      test_pid = self()

      handler_fun = fn
        {:chunk_complete, chunk_number, _rel_path} ->
          send(test_pid, {:handler_received, {:chunk_complete, chunk_number}})

        {:progress, _progress} ->
          :ok

        :complete ->
          send(test_pid, {:handler_received, :complete})

        _ ->
          :ok
      end

      url = "http://localhost:4001/1M.bin"
      total_size = 1_048_576
      chunk_size = 524_288
      final_rel_path = "test-parallel-oversized.bin"

      # Create an oversized chunk file (larger than expected chunk size)
      chunk_0_path = Path.join(cache_dir, "#{final_rel_path}.part0000")
      File.mkdir_p!(Path.dirname(chunk_0_path))
      # Write more data than chunk size (600KB > 512KB)
      File.write!(chunk_0_path, :crypto.strong_rand_bytes(600_000))

      {:ok, %{size: original_size}} = File.stat(chunk_0_path)
      assert original_size == 600_000

      {:ok, downloader_pid} =
        ParallelDownloader.start_link(
          "test-parallel-oversized",
          url,
          total_size,
          chunk_size,
          2,
          final_rel_path,
          cache_pid,
          handler_fun,
          %RetryConfig{}
        )

      ref = Process.monitor(downloader_pid)

      # Should complete all chunks - oversized file should have been cleaned up
      assert_receive {:handler_received, :complete}, 15000

      # Should exit normally
      assert_receive {:DOWN, ^ref, :process, ^downloader_pid, :normal}, 2000

      # Verify chunk 0 was properly downloaded (correct size)
      {:ok, %{size: final_size}} = File.stat(chunk_0_path)
      assert final_size == chunk_size
    end
  end

  describe "progress accounting" do
    setup :start_cache

    @tag capture_log: true
    test "progress updates are cumulative and reach total size", %{cache_pid: cache_pid} do
      test_pid = self()

      handler_fun = fn
        {:progress, progress} ->
          send(test_pid, {:handler_received, {:progress, progress}})

        :complete ->
          send(test_pid, {:handler_received, :complete})

        _ ->
          :ok
      end

      url = "http://localhost:4001/1M.bin"
      total_size = 1_048_576
      chunk_size = 1_048_576

      {:ok, downloader_pid} =
        ParallelDownloader.start_link(
          "test-parallel-progress",
          url,
          total_size,
          chunk_size,
          1,
          "test-parallel-progress.bin",
          cache_pid,
          handler_fun,
          %RetryConfig{}
        )

      ref = Process.monitor(downloader_pid)

      progress_values = collect_progress_values([])

      assert progress_values != []
      assert progress_values == Enum.sort(progress_values)
      assert List.last(progress_values) == total_size

      assert_receive {:DOWN, ^ref, :process, ^downloader_pid, :normal}, 2000
    end
  end

  describe "chunk resume handling" do
    setup :start_cache

    @tag capture_log: true
    test "resumes partial chunks on restart", %{cache_pid: cache_pid, cache_dir: cache_dir} do
      test_pid = self()

      handler_fun = fn
        {:chunk_complete, chunk_number, _rel_path} ->
          send(test_pid, {:handler_received, {:chunk_complete, chunk_number}})

        {:progress, _progress} ->
          :ok

        :complete ->
          send(test_pid, {:handler_received, :complete})

        _ ->
          :ok
      end

      url = "http://localhost:4001/1M.bin"
      total_size = 1_048_576
      chunk_size = 524_288
      final_rel_path = "test-parallel-resume.bin"

      # Create a partial chunk file to simulate interrupted download
      chunk_0_path = Path.join(cache_dir, "#{final_rel_path}.part0000")
      File.mkdir_p!(Path.dirname(chunk_0_path))
      # Write 100KB of data
      File.write!(chunk_0_path, :crypto.strong_rand_bytes(102_400))

      {:ok, downloader_pid} =
        ParallelDownloader.start_link(
          "test-parallel-resume",
          url,
          total_size,
          chunk_size,
          2,
          final_rel_path,
          cache_pid,
          handler_fun,
          %RetryConfig{}
        )

      ref = Process.monitor(downloader_pid)

      # Should complete all chunks
      assert_receive {:handler_received, :complete}, 15000

      # Should exit normally
      assert_receive {:DOWN, ^ref, :process, ^downloader_pid, :normal}, 2000
    end
  end

  defp collect_progress_values(acc) do
    receive do
      {:handler_received, {:progress, progress}} ->
        collect_progress_values([progress.downloaded | acc])

      {:handler_received, :complete} ->
        Enum.reverse(acc)
    after
      15_000 ->
        Enum.reverse(acc)
    end
  end
end

defmodule Peridiod.Binary.ParallelDownloaderTest.FakeCache do
  use GenServer

  def start_link(base_dir) do
    GenServer.start_link(__MODULE__, %{base_dir: base_dir, fail_once: true})
  end

  def init(state), do: {:ok, state}

  def handle_call({:abs_path, file}, _from, state) do
    {:reply, Path.join(state.base_dir, file), state}
  end

  def handle_call({:write_stream_update, _file, _data}, _from, %{fail_once: true} = state) do
    {:reply, {:error, :eio}, %{state | fail_once: false}}
  end

  def handle_call({:write_stream_update, file, data}, _from, state) do
    file_path = Path.join(state.base_dir, file)
    dir = Path.dirname(file_path)

    reply =
      with :ok <- File.mkdir_p(dir),
           :ok <- File.write(file_path, data, [:append, :binary]) do
        :ok
      end

    {:reply, reply, state}
  end
end
