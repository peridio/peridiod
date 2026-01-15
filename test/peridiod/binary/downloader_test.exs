defmodule Peridiod.Binary.DownloaderTest do
  use PeridiodTest.Case
  alias Peridiod.Binary.Downloader
  alias Peridiod.Binary.Downloader.RetryConfig

  describe "fatal HTTP error handling" do
    @tag capture_log: true
    test "sends fatal_http_error message on HTTP 400" do
      test_pid = self()
      handler_fun = fn message -> send(test_pid, {:handler_received, message}) end

      url = URI.parse("http://localhost:4001/error/400")
      {:ok, downloader_pid} = Downloader.start_link("test-400", url, handler_fun, %RetryConfig{})

      # Monitor the process to verify it exits normally
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
      {:ok, downloader_pid} = Downloader.start_link("test-403", url, handler_fun, %RetryConfig{})

      ref = Process.monitor(downloader_pid)

      assert_receive {:handler_received, {:fatal_http_error, 403, %URI{}}}, 2000
      assert_receive {:DOWN, ^ref, :process, ^downloader_pid, :normal}, 2000
    end

    @tag capture_log: true
    test "sends fatal_http_error message on HTTP 404" do
      test_pid = self()
      handler_fun = fn message -> send(test_pid, {:handler_received, message}) end

      url = URI.parse("http://localhost:4001/error/404")
      {:ok, downloader_pid} = Downloader.start_link("test-404", url, handler_fun, %RetryConfig{})

      ref = Process.monitor(downloader_pid)

      assert_receive {:handler_received, {:fatal_http_error, 404, %URI{}}}, 2000
      assert_receive {:DOWN, ^ref, :process, ^downloader_pid, :normal}, 2000
    end

    @tag capture_log: true
    test "downloader exits normally without supervisor restart" do
      test_pid = self()
      handler_fun = fn message -> send(test_pid, {:handler_received, message}) end

      url = URI.parse("http://localhost:4001/error/400")

      {:ok, downloader_pid} =
        Downloader.start_link("test-normal-exit", url, handler_fun, %RetryConfig{})

      ref = Process.monitor(downloader_pid)

      # Wait for exit
      assert_receive {:DOWN, ^ref, :process, ^downloader_pid, :normal}, 2000

      # Verify we got the error message before exit
      assert_received {:handler_received, {:fatal_http_error, 400, %URI{}}}
    end
  end

  describe "successful download handling" do
    @tag capture_log: true
    test "downloads file and sends stream events" do
      test_pid = self()

      handler_fun = fn
        {:stream, _data} ->
          send(test_pid, {:handler_received, :stream})

        :complete ->
          send(test_pid, {:handler_received, :complete})

        {:error, reason} ->
          send(test_pid, {:handler_received, {:error, reason}})

        {:fatal_http_error, status, uri} ->
          send(test_pid, {:handler_received, {:fatal_http_error, status, uri}})
      end

      url = URI.parse("http://localhost:4001/1M.bin")

      {:ok, downloader_pid} =
        Downloader.start_link("test-success", url, handler_fun, %RetryConfig{})

      ref = Process.monitor(downloader_pid)

      # Should receive stream events
      assert_receive {:handler_received, :stream}, 2000

      # Should eventually complete
      assert_receive {:handler_received, :complete}, 5000

      # Should exit normally after completion
      assert_receive {:DOWN, ^ref, :process, ^downloader_pid, :normal}, 2000
    end
  end
end
