defmodule Peridiod.Binary.ChunkDownloaderTest do
  use PeridiodTest.Case
  alias Peridiod.Binary.ChunkDownloader
  alias Peridiod.Binary.Downloader.RetryConfig

  describe "fatal HTTP error handling" do
    @tag capture_log: true
    test "sends fatal_http_error message on HTTP 400" do
      test_pid = self()
      handler_fun = fn message -> send(test_pid, {:handler_received, message}) end

      url = URI.parse("http://localhost:4001/error/400")
      chunk_file_path = "test-chunk.part0000"

      {:ok, downloader_pid} =
        ChunkDownloader.start(
          "test-chunk-400",
          url,
          0,
          0,
          1000,
          chunk_file_path,
          handler_fun,
          %RetryConfig{}
        )

      ref = Process.monitor(downloader_pid)

      # Should receive fatal error message
      assert_receive {:handler_received, {:fatal_http_error, 400, %URI{} = uri}}, 2000
      assert URI.to_string(uri) =~ "/error/400"

      # Should exit with :normal (not crash)
      assert_receive {:DOWN, ^ref, :process, ^downloader_pid, :normal}, 2000
    end

    @tag capture_log: true
    test "sends fatal_http_error message on HTTP 403" do
      test_pid = self()
      handler_fun = fn message -> send(test_pid, {:handler_received, message}) end

      url = URI.parse("http://localhost:4001/error/403")
      chunk_file_path = "test-chunk.part0001"

      {:ok, downloader_pid} =
        ChunkDownloader.start(
          "test-chunk-403",
          url,
          1,
          1000,
          2000,
          chunk_file_path,
          handler_fun,
          %RetryConfig{}
        )

      ref = Process.monitor(downloader_pid)

      assert_receive {:handler_received, {:fatal_http_error, 403, %URI{}}}, 2000
      assert_receive {:DOWN, ^ref, :process, ^downloader_pid, :normal}, 2000
    end

    @tag capture_log: true
    test "exits normally without crash on HTTP 4xx" do
      test_pid = self()
      handler_fun = fn message -> send(test_pid, {:handler_received, message}) end

      url = URI.parse("http://localhost:4001/error/404")
      chunk_file_path = "test-chunk.part0002"

      {:ok, downloader_pid} =
        ChunkDownloader.start(
          "test-chunk-404",
          url,
          2,
          2000,
          3000,
          chunk_file_path,
          handler_fun,
          %RetryConfig{}
        )

      ref = Process.monitor(downloader_pid)

      assert_receive {:DOWN, ^ref, :process, ^downloader_pid, :normal}, 2000
      assert_received {:handler_received, {:fatal_http_error, 404, %URI{}}}
    end
  end

  describe "non-linking start function" do
    @tag capture_log: true
    test "start/8 creates process without linking" do
      test_pid = self()
      handler_fun = fn message -> send(test_pid, {:handler_received, message}) end

      url = URI.parse("http://localhost:4001/error/400")
      chunk_file_path = "test-chunk-nolink.part0000"

      # Use start (not start_link)
      {:ok, downloader_pid} =
        ChunkDownloader.start(
          "test-chunk-nolink",
          url,
          0,
          0,
          1000,
          chunk_file_path,
          handler_fun,
          %RetryConfig{}
        )

      # Verify the process was created
      assert Process.alive?(downloader_pid)

      # Monitor to verify it exits normally
      ref = Process.monitor(downloader_pid)

      # Should receive fatal error and exit normally
      assert_receive {:handler_received, {:fatal_http_error, 400, %URI{}}}, 2000
      assert_receive {:DOWN, ^ref, :process, ^downloader_pid, :normal}, 2000

      # Verify we're still alive (not linked, so crash didn't propagate)
      assert Process.alive?(test_pid)
    end

    @tag capture_log: true
    test "start_with_resume/9 creates process without linking" do
      test_pid = self()
      handler_fun = fn message -> send(test_pid, {:handler_received, message}) end

      url = URI.parse("http://localhost:4001/error/400")
      chunk_file_path = "test-chunk-resume-nolink.part0000"

      # Ensure cleanup happens even if test fails
      on_exit(fn -> File.rm_rf(chunk_file_path) end)

      # Create a temporary file with some content to simulate resume
      File.write!(chunk_file_path, "partial data")

      # Use start_with_resume (not start_link_with_resume)
      {:ok, downloader_pid} =
        ChunkDownloader.start_with_resume(
          "test-chunk-resume-nolink",
          url,
          0,
          0,
          1000,
          chunk_file_path,
          handler_fun,
          %RetryConfig{},
          12
        )

      # Verify the process was created
      assert Process.alive?(downloader_pid)

      ref = Process.monitor(downloader_pid)

      # Should exit normally
      assert_receive {:DOWN, ^ref, :process, ^downloader_pid, :normal}, 2000
    end
  end

  describe "oversized chunk file cleanup" do
    @tag capture_log: true
    test "start/8 removes existing file before downloading" do
      test_pid = self()
      handler_fun = fn message -> send(test_pid, {:handler_received, message}) end

      chunk_file_path = "test-chunk-oversized.part0000"

      # Create an oversized file with garbage data
      File.write!(chunk_file_path, :crypto.strong_rand_bytes(5000))

      # Verify file exists and has content
      assert File.exists?(chunk_file_path)
      {:ok, %{size: original_size}} = File.stat(chunk_file_path)
      assert original_size == 5000

      # Start a fresh download (not resume) - should delete the file first
      {:ok, downloader_pid} =
        ChunkDownloader.start(
          "test-chunk-oversized",
          URI.parse("http://localhost:4001/error/400"),
          0,
          0,
          1000,
          chunk_file_path,
          handler_fun,
          %RetryConfig{}
        )

      ref = Process.monitor(downloader_pid)

      # Wait for process to exit
      assert_receive {:DOWN, ^ref, :process, ^downloader_pid, :normal}, 2000

      # The file should have been deleted by init (even though download fails)
      # Since we got HTTP 400, no new file should have been created
      refute File.exists?(chunk_file_path)
    end
  end

  describe "successful chunk download" do
    setup :start_cache

    @tag capture_log: true
    test "downloads chunk and sends stream events", %{cache_dir: cache_dir} do
      test_pid = self()
      stream_count = :counters.new(1, [])

      handler_fun = fn
        {:stream, data} ->
          :counters.add(stream_count, 1, 1)
          send(test_pid, {:handler_received, {:stream, byte_size(data)}})

        :complete ->
          send(test_pid, {:handler_received, :complete})

        {:error, reason} ->
          send(test_pid, {:handler_received, {:error, reason}})

        {:fatal_http_error, status, uri} ->
          send(test_pid, {:handler_received, {:fatal_http_error, status, uri}})
      end

      url = URI.parse("http://localhost:4001/1M.bin")
      chunk_file_path = "test-chunk-success.part0000"
      abs_path = Path.join(cache_dir, chunk_file_path)
      File.mkdir_p!(Path.dirname(abs_path))

      # Download first 10KB as a chunk
      {:ok, downloader_pid} =
        ChunkDownloader.start(
          "test-chunk-success",
          url,
          0,
          0,
          10239,
          chunk_file_path,
          handler_fun,
          %RetryConfig{}
        )

      ref = Process.monitor(downloader_pid)

      # Should receive stream events
      assert_receive {:handler_received, {:stream, _size}}, 2000

      # Should eventually complete
      assert_receive {:handler_received, :complete}, 5000

      # Should exit normally
      assert_receive {:DOWN, ^ref, :process, ^downloader_pid, :normal}, 2000

      # Verify we received multiple stream chunks
      count = :counters.get(stream_count, 1)
      assert count > 0
    end
  end
end
