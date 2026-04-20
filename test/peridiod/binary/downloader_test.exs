defmodule Peridiod.Binary.DownloaderTest do
  use PeridiodTest.Case
  alias Peridiod.Binary.Downloader
  alias Peridiod.Binary.Downloader.RetryConfig
  alias Peridiod.Binary.Downloader.VerifyConfig

  # SHA-256 of test/fixtures/binaries/1M.bin
  @bin_1m_hash Base.decode16!("a073ad730e540107fbb92ee48baab97c9bc16105333a42b15a53bcc183f6f5c2",
                 case: :lower
               )
  @bin_1m_size 1_048_576

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

  describe "integrity verification" do
    # Only forward terminal events (:complete, {:error, ...}) to the test mailbox,
    # not {:stream, data} chunks, to avoid flooding the mailbox with binary data.
    defp verify_handler(test_pid) do
      fn
        {:stream, _} -> :ok
        msg -> send(test_pid, {:handler_received, msg})
      end
    end

    @tag capture_log: true
    test "completes successfully with correct hash" do
      test_pid = self()
      verify_config = %VerifyConfig{expected_hash: @bin_1m_hash}
      url = URI.parse("http://localhost:4001/1M.bin")

      {:ok, pid} =
        Downloader.start_link(
          "test-hash-ok",
          url,
          verify_handler(test_pid),
          %RetryConfig{},
          verify_config
        )

      ref = Process.monitor(pid)

      assert_receive {:handler_received, :complete}, 5000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2000
    end

    @tag capture_log: true
    test "fails with checksum mismatch on wrong hash" do
      test_pid = self()
      wrong_hash = :crypto.hash(:sha256, "wrong")
      verify_config = %VerifyConfig{expected_hash: wrong_hash}
      url = URI.parse("http://localhost:4001/1M.bin")

      {:ok, pid} =
        Downloader.start_link(
          "test-hash-bad",
          url,
          verify_handler(test_pid),
          %RetryConfig{},
          verify_config
        )

      ref = Process.monitor(pid)

      assert_receive {:handler_received, {:error, {:checksum_mismatch, details}}}, 5000
      assert details[:expected] == wrong_hash
      assert details[:actual] == @bin_1m_hash
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2000
      refute_received {:handler_received, :complete}
    end

    @tag capture_log: true
    test "completes successfully with correct size" do
      test_pid = self()
      verify_config = %VerifyConfig{expected_size: @bin_1m_size}
      url = URI.parse("http://localhost:4001/1M.bin")

      {:ok, pid} =
        Downloader.start_link(
          "test-size-ok",
          url,
          verify_handler(test_pid),
          %RetryConfig{},
          verify_config
        )

      ref = Process.monitor(pid)

      assert_receive {:handler_received, :complete}, 5000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2000
    end

    @tag capture_log: true
    test "fails with size mismatch on wrong expected size" do
      test_pid = self()
      verify_config = %VerifyConfig{expected_size: 999}
      url = URI.parse("http://localhost:4001/1M.bin")

      {:ok, pid} =
        Downloader.start_link(
          "test-size-bad",
          url,
          verify_handler(test_pid),
          %RetryConfig{},
          verify_config
        )

      ref = Process.monitor(pid)

      assert_receive {:handler_received, {:error, {:size_mismatch, details}}}, 5000
      assert details[:expected] == 999
      assert details[:actual] == @bin_1m_size
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2000
      refute_received {:handler_received, :complete}
    end

    @tag capture_log: true
    test "completes successfully with both correct hash and size" do
      test_pid = self()
      verify_config = %VerifyConfig{expected_hash: @bin_1m_hash, expected_size: @bin_1m_size}
      url = URI.parse("http://localhost:4001/1M.bin")

      {:ok, pid} =
        Downloader.start_link(
          "test-hash-size-ok",
          url,
          verify_handler(test_pid),
          %RetryConfig{},
          verify_config
        )

      ref = Process.monitor(pid)

      assert_receive {:handler_received, :complete}, 5000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2000
    end

    @tag capture_log: true
    test "backward compatible without verify_config" do
      test_pid = self()
      url = URI.parse("http://localhost:4001/1M.bin")

      {:ok, pid} =
        Downloader.start_link("test-no-verify", url, verify_handler(test_pid), %RetryConfig{})

      ref = Process.monitor(pid)

      assert_receive {:handler_received, :complete}, 5000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2000
    end

    @tag capture_log: true
    test "partial resumed download skips hash verification but size still applies" do
      test_pid = self()

      # existing_size > 0 means this is a true partial resume — hash must be skipped
      # because the downloader only sees bytes from the resume point onward.
      # Size verification still works since downloaded_length tracks the running total.
      existing_size = 512
      verify_config = %VerifyConfig{expected_hash: @bin_1m_hash, expected_size: @bin_1m_size}
      url = URI.parse("http://localhost:4001/1M.bin")

      {:ok, pid} =
        Downloader.start_link_with_resume(
          "test-resume-hash-skip",
          url,
          verify_handler(test_pid),
          %RetryConfig{},
          existing_size,
          verify_config
        )

      ref = Process.monitor(pid)

      # Hash is skipped for partial resumes; size check passes since
      # downloaded_length (existing + new bytes) will equal expected_size.
      assert_receive {:handler_received, :complete}, 5000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2000
    end
  end
end
