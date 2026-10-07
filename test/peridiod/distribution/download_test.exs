defmodule Peridiod.Distribution.DownloadTest do
  use PeridiodTest.Case

  alias Peridiod.{Distribution, Config, Cache}

  @expired_url "http://localhost:4001/s3/expired-token"
  @unreachable_url "http://127.0.0.1:1/never"
  @fresh_url "http://localhost:4001/fwup.fw?fresh=1"

  describe "configuration parsing" do
    test "parses new download parallel configuration options" do
      config = %Config{}
      assert config.distributions_download_parallel_count == 1
      assert config.distributions_download_parallel_chunk_bytes == 5_000_000

      config_with_values = %Config{
        distributions_download_parallel_count: 3,
        distributions_download_parallel_chunk_bytes: 2_097_152
      }

      assert config_with_values.distributions_download_parallel_count == 3
      assert config_with_values.distributions_download_parallel_chunk_bytes == 2_097_152
    end
  end

  describe "streamed downloads (no cache)" do
    setup :setup_stream_download_server

    @tag capture_log: true
    test "starts fwup and downloader", %{config: config} do
      {:ok, server} = Distribution.Server.start_link(config, [])
      url = "http://localhost:4001/fwup.fw"

      firmware_meta = %{
        "uuid" => "test-firmware-uuid-stream",
        "version" => "1.0.0",
        "platform" => "test",
        "architecture" => "test",
        "product" => "test"
      }

      {:ok, dist} = Distribution.parse(%{"firmware_meta" => firmware_meta, "firmware_url" => url})

      Distribution.Server.apply_update(server, dist)

      # Wait for any install message to confirm update was accepted and started
      # Note: On fast systems, small files may complete before we can check state
      assert_receive {Distribution.Server, :install, _}, 3000

      # Verify server is not in error state
      state = :sys.get_state(server)
      refute match?(%{status: {:error, _}}, state)

      GenServer.stop(server)
      # Brief delay to let download processes clean up before cache is removed
      Process.sleep(50)
    end
  end

  describe "cache downloads - non parallel" do
    setup :setup_cache_download_server

    @tag capture_log: true
    test "initializes fwup and .part caching", %{config: config} do
      {:ok, server} = Distribution.Server.start_link(config, [])
      url = "http://localhost:4001/1M.bin"

      firmware_meta = %{
        "uuid" => "test-firmware-uuid-cache-np",
        "version" => "1.0.0",
        "platform" => "test",
        "architecture" => "test",
        "product" => "test"
      }

      {:ok, dist} = Distribution.parse(%{"firmware_meta" => firmware_meta, "firmware_url" => url})

      Distribution.Server.apply_update(server, dist)

      state = :sys.get_state(server)
      assert match?(%{status: {:updating, 0}}, state)
      assert is_pid(state.fwup)
      assert is_pid(state.download)
      assert is_binary(state.download_file_path)
      assert String.ends_with?(state.download_file_path, ".part")
      assert state.next_chunk_to_stream == nil

      GenServer.stop(server)
      # Brief delay to let download processes clean up before cache is removed
      Process.sleep(50)
    end
  end

  describe "cache downloads - parallel" do
    setup :setup_parallel_download_server

    @tag capture_log: true
    test "initializes fwup and ordering state", %{config: config} do
      {:ok, server} = Distribution.Server.start_link(config, [])
      url = "http://localhost:4001/1M.bin"

      firmware_meta = %{
        "uuid" => "test-firmware-uuid-cache-par",
        "version" => "1.0.0",
        "platform" => "test",
        "architecture" => "test",
        "product" => "test"
      }

      {:ok, dist} = Distribution.parse(%{"firmware_meta" => firmware_meta, "firmware_url" => url})

      Distribution.Server.apply_update(server, dist)

      state = :sys.get_state(server)
      assert match?(%{status: {:updating, 0}}, state)
      assert is_pid(state.fwup)
      assert is_pid(state.download)
      # In parallel plan, ordering state is initialized
      assert state.next_chunk_to_stream in [0, nil]
      # total_chunks may be initialized when content-length is known
      assert is_nil(state.total_chunks) or is_integer(state.total_chunks)

      GenServer.stop(server)
      # Brief delay to let download processes clean up before cache is removed
      Process.sleep(50)
    end
  end

  describe "chunk filename format" do
    test "zero-based, 4 digits" do
      uuid = "some-uuid"

      assert String.ends_with?(
               Peridiod.Distribution.DownloadCache.chunk_file(uuid, 0),
               ".part0000"
             )

      assert String.ends_with?(
               Peridiod.Distribution.DownloadCache.chunk_file(uuid, 11),
               ".part0011"
             )
    end
  end

  defmodule HungFwup do
    @moduledoc false
    # alive, but never answers a chunk
    use GenServer

    def init(_), do: {:ok, nil}
    def handle_call({:send_chunk, _chunk}, _from, state), do: {:noreply, state}
  end

  describe "fwup is alive but doesn't take a chunk in time" do
    setup :setup_stream_download_server

    setup do
      Application.put_env(:peridiod, :fwup_chunk_timeout_ms, 50)
      on_exit(fn -> Application.delete_env(:peridiod, :fwup_chunk_timeout_ms) end)
    end

    @tag capture_log: true
    test "the update fails and the missed chunk doesn't move the resume offset", %{config: config} do
      {:ok, server} = Distribution.Server.start_link(config, [])
      {:ok, hung_fwup} = GenServer.start(HungFwup, nil)

      {:ok, dist} =
        Distribution.parse(%{
          "firmware_url" => "http://127.0.0.1:1/never",
          "firmware_meta" => %{
            "uuid" => "fwup-stalled",
            "version" => "1.0.0",
            "platform" => "test",
            "architecture" => "test",
            "product" => "test"
          }
        })

      :sys.replace_state(server, fn state ->
        %{
          state
          | fwup: hung_fwup,
            distribution: dist,
            downloaded_bytes: 7,
            awaiting_url: make_ref()
        }
      end)

      send(server, {:download, {:stream, "a chunk fwup never takes"}})

      state = :sys.get_state(server)
      assert {:fwup_error, message} = state.status
      assert message =~ "did not take a chunk"
      # dropping it and carrying on would feed fwup a stream with a hole, and a resume
      # would skip bytes it never got
      assert state.downloaded_bytes == 7
      assert state.fwup == nil
      # the update is over, so a refresh that was waiting for it is too
      assert state.awaiting_url == nil
      # the server still knows what it was downloading
      assert state.distribution.firmware_meta.uuid == "fwup-stalled"
      refute Process.alive?(hung_fwup)

      GenServer.stop(server)
    end
  end

  describe "fwup exits while the firmware is still downloading" do
    setup :setup_stream_download_server

    @tag capture_log: true
    test "a chunk for the dead fwup doesn't crash the server", %{config: config} do
      {:ok, server} = Distribution.Server.start_link(config, [])
      dead_fwup = spawn(fn -> :ok end)
      ref = Process.monitor(dead_fwup)
      assert_receive {:DOWN, ^ref, :process, ^dead_fwup, _}

      {:ok, dist} =
        Distribution.parse(%{
          "firmware_url" => "http://127.0.0.1:1/never",
          "firmware_meta" => %{
            "uuid" => "fwup-gone",
            "version" => "1.0.0",
            "platform" => "test",
            "architecture" => "test",
            "product" => "test"
          }
        })

      :sys.replace_state(server, &%{&1 | fwup: dead_fwup, distribution: dist})
      send(server, {:download, {:stream, "more firmware"}})

      # still the same process, still knows what it was downloading
      assert Process.alive?(server)
      assert %{distribution: %{firmware_meta: %{uuid: "fwup-gone"}}} = :sys.get_state(server)
      assert Distribution.Server.currently_downloading_uuid(server) == "fwup-gone"

      GenServer.stop(server)
    end
  end

  describe "fwup exits while a cached chunk is being streamed to it" do
    setup :setup_parallel_download_server

    defp server_with_dead_fwup(config) do
      {:ok, server} = Distribution.Server.start_link(config, [])
      dead_fwup = spawn(fn -> :ok end)
      ref = Process.monitor(dead_fwup)
      assert_receive {:DOWN, ^ref, :process, ^dead_fwup, _}
      :sys.replace_state(server, &%{&1 | fwup: dead_fwup})
      server
    end

    @tag capture_log: true
    test "a small chunk fails the update instead of crashing the server", %{config: config} do
      server = server_with_dead_fwup(config)
      chunk = Path.join(System.tmp_dir!(), "small-chunk-#{System.unique_integer([:positive])}")
      File.write!(chunk, "a small chunk")
      on_exit(fn -> File.rm(chunk) end)

      send(server, {:async_stream_small_chunk_file, chunk})

      assert %{status: {:fwup_error, _}} = :sys.get_state(server)
      assert Process.alive?(server)

      GenServer.stop(server)
    end

    @tag capture_log: true
    test "a large chunk fails the update instead of crashing the server", %{config: config} do
      server = server_with_dead_fwup(config)
      chunk = Path.join(System.tmp_dir!(), "large-chunk-#{System.unique_integer([:positive])}")
      File.write!(chunk, "a large chunk")
      on_exit(fn -> File.rm(chunk) end)

      :sys.replace_state(server, fn state ->
        %{state | async_streaming: %{file_path: chunk, offset: 0, file_size: 13}}
      end)

      send(server, {:async_stream_file, chunk, 0})

      assert %{status: {:fwup_error, _}, async_streaming: nil} = :sys.get_state(server)
      assert Process.alive?(server)

      GenServer.stop(server)
    end
  end

  describe "restoring the refresh budget" do
    setup :setup_parallel_download_server

    alias Peridiod.Distribution.UrlRefresh

    @tag capture_log: true
    test "a restarted parallel download only does it for new bytes", %{config: config} do
      {:ok, server} = Distribution.Server.start_link(config, [])

      :sys.replace_state(server, fn state ->
        %{
          state
          | url_refresh: %UrlRefresh{attempts: 2},
            parallel_progress_bytes: 500,
            next_chunk_to_stream: 0
        }
      end)

      # what the restart already had on disk moves nothing
      send(server, {:download, {:chunk_complete, 1, "firmware.bin.part0001"}})
      send(server, {:download, {:progress, %{downloaded: 500}}})
      assert %{url_refresh: %{attempts: 2}, parallel_progress_bytes: 500} = :sys.get_state(server)

      # bytes beyond the highest seen are progress
      send(server, {:download, {:progress, %{downloaded: 501}}})
      assert %{url_refresh: %{attempts: 0}, parallel_progress_bytes: 501} = :sys.get_state(server)

      GenServer.stop(server)
    end
  end

  describe "fatal HTTP error handling - streamed downloads" do
    setup :setup_stream_download_server

    @tag capture_log: true
    test "resets to :idle state after fatal HTTP 400 error", %{config: config} do
      {:ok, server} = Distribution.Server.start_link(config, [])
      url = "http://localhost:4001/error/400"

      firmware_meta = %{
        "uuid" => "test-firmware-uuid-error-400",
        "version" => "1.0.0",
        "platform" => "test",
        "architecture" => "test",
        "product" => "test"
      }

      {:ok, dist} = Distribution.parse(%{"firmware_meta" => firmware_meta, "firmware_url" => url})

      Distribution.Server.apply_update(server, dist)

      # Wait for the error to be processed
      assert_receive {Distribution.Server, :install, {:error, :http_download_failed}}, 3000

      # Verify state was reset to :idle
      state = :sys.get_state(server)
      assert state.status == :idle
      assert state.download == nil
      assert state.fwup == nil
      assert state.distribution == nil

      GenServer.stop(server)
    end

    @tag capture_log: true
    test "accepts new update after fatal HTTP error", %{config: config} do
      {:ok, server} = Distribution.Server.start_link(config, [])

      # First update with error URL
      error_url = "http://localhost:4001/error/403"

      firmware_meta_error = %{
        "uuid" => "test-firmware-uuid-error-403",
        "version" => "1.0.0",
        "platform" => "test",
        "architecture" => "test",
        "product" => "test"
      }

      {:ok, dist_error} =
        Distribution.parse(%{"firmware_meta" => firmware_meta_error, "firmware_url" => error_url})

      Distribution.Server.apply_update(server, dist_error)

      # Wait for error
      assert_receive {Distribution.Server, :install, {:error, :http_download_failed}}, 3000

      # Verify state reset
      state = :sys.get_state(server)
      assert state.status == :idle

      # Second update with valid URL should be accepted
      # Use a valid firmware file since streamed downloads go directly to fwup
      valid_url = "http://localhost:4001/fwup.fw"

      firmware_meta_valid = %{
        "uuid" => "test-firmware-uuid-valid-after-error",
        "version" => "1.0.1",
        "platform" => "test",
        "architecture" => "test",
        "product" => "test"
      }

      {:ok, dist_valid} =
        Distribution.parse(%{"firmware_meta" => firmware_meta_valid, "firmware_url" => valid_url})

      # This should NOT be rejected with "already updating"
      Distribution.Server.apply_update(server, dist_valid)

      # Wait for the update to be accepted and start processing
      # Receiving any install message confirms the update was accepted (not rejected)
      assert_receive {Distribution.Server, :install, _msg}, 3000

      GenServer.stop(server)
      # Brief delay to let download processes clean up before cache is removed
      Process.sleep(50)
    end

    @tag capture_log: true
    test "ignores stale fwup messages when fwup is nil", %{config: config} do
      {:ok, server} = Distribution.Server.start_link(config, [])

      # Send stale fwup messages directly to the server when fwup is nil
      send(server, {:fwup, {:progress, 50}})
      send(server, {:fwup, {:ok, 0, "complete"}})

      # Give it a moment to process
      Process.sleep(100)

      # Verify state remains :idle and didn't change
      state = :sys.get_state(server)
      assert state.status == :idle
      assert state.fwup == nil

      GenServer.stop(server)
    end
  end

  describe "fatal HTTP error handling - cached downloads" do
    setup :setup_cache_download_server

    @tag capture_log: true
    test "resets to :idle state after fatal HTTP error in cached mode", %{config: config} do
      {:ok, server} = Distribution.Server.start_link(config, [])
      url = "http://localhost:4001/error/400"

      firmware_meta = %{
        "uuid" => "test-firmware-uuid-cache-error-400",
        "version" => "1.0.0",
        "platform" => "test",
        "architecture" => "test",
        "product" => "test"
      }

      {:ok, dist} = Distribution.parse(%{"firmware_meta" => firmware_meta, "firmware_url" => url})

      Distribution.Server.apply_update(server, dist)

      # Wait for error
      assert_receive {Distribution.Server, :install, {:error, :http_download_failed}}, 3000

      # Verify state reset
      state = :sys.get_state(server)
      assert state.status == :idle
      assert state.download == nil
      assert state.fwup == nil
      assert state.distribution == nil
      assert state.download_file_path == nil

      GenServer.stop(server)
    end

    @tag capture_log: true
    test "accepts new update after fatal HTTP error in cached mode", %{config: config} do
      {:ok, server} = Distribution.Server.start_link(config, [])

      # First update with error
      error_url = "http://localhost:4001/error/404"

      firmware_meta_error = %{
        "uuid" => "test-firmware-uuid-cache-error-404",
        "version" => "1.0.0",
        "platform" => "test",
        "architecture" => "test",
        "product" => "test"
      }

      {:ok, dist_error} =
        Distribution.parse(%{"firmware_meta" => firmware_meta_error, "firmware_url" => error_url})

      Distribution.Server.apply_update(server, dist_error)

      # Wait for error
      assert_receive {Distribution.Server, :install, {:error, :http_download_failed}}, 3000

      # Second update with valid URL
      valid_url = "http://localhost:4001/1M.bin"

      firmware_meta_valid = %{
        "uuid" => "test-firmware-uuid-cache-valid",
        "version" => "1.0.1",
        "platform" => "test",
        "architecture" => "test",
        "product" => "test"
      }

      {:ok, dist_valid} =
        Distribution.parse(%{"firmware_meta" => firmware_meta_valid, "firmware_url" => valid_url})

      # Should be accepted
      Distribution.Server.apply_update(server, dist_valid)

      # Verify new download started
      state = :sys.get_state(server)
      assert match?(%{status: {:updating, _}}, state)
      assert is_pid(state.download)
      assert is_pid(state.fwup)

      GenServer.stop(server)
      # Brief delay to let download processes clean up before cache is removed
      Process.sleep(50)
    end
  end

  describe "fatal HTTP error handling - parallel downloads" do
    setup :setup_parallel_download_server

    @tag capture_log: true
    test "resets to :idle state after fatal HTTP error in parallel mode", %{config: config} do
      {:ok, server} = Distribution.Server.start_link(config, [])
      url = "http://localhost:4001/error/400"

      firmware_meta = %{
        "uuid" => "test-firmware-uuid-parallel-error-400",
        "version" => "1.0.0",
        "platform" => "test",
        "architecture" => "test",
        "product" => "test"
      }

      {:ok, dist} = Distribution.parse(%{"firmware_meta" => firmware_meta, "firmware_url" => url})

      Distribution.Server.apply_update(server, dist)

      # Wait for error
      assert_receive {Distribution.Server, :install, {:error, :http_download_failed}}, 3000

      # Verify state reset
      state = :sys.get_state(server)
      assert state.status == :idle
      assert state.download == nil
      assert state.fwup == nil
      assert state.distribution == nil
      assert state.next_chunk_to_stream == nil
      assert state.ready_chunk_files == %{}

      GenServer.stop(server)
    end

    @tag capture_log: true
    test "accepts new update after fatal HTTP error in parallel mode", %{config: config} do
      {:ok, server} = Distribution.Server.start_link(config, [])

      # First update with error
      error_url = "http://localhost:4001/error/403"

      firmware_meta_error = %{
        "uuid" => "test-firmware-uuid-parallel-error-403",
        "version" => "1.0.0",
        "platform" => "test",
        "architecture" => "test",
        "product" => "test"
      }

      {:ok, dist_error} =
        Distribution.parse(%{"firmware_meta" => firmware_meta_error, "firmware_url" => error_url})

      Distribution.Server.apply_update(server, dist_error)

      # Wait for error
      assert_receive {Distribution.Server, :install, {:error, :http_download_failed}}, 3000

      # Second update with valid URL
      valid_url = "http://localhost:4001/1M.bin"

      firmware_meta_valid = %{
        "uuid" => "test-firmware-uuid-parallel-valid",
        "version" => "1.0.1",
        "platform" => "test",
        "architecture" => "test",
        "product" => "test"
      }

      {:ok, dist_valid} =
        Distribution.parse(%{"firmware_meta" => firmware_meta_valid, "firmware_url" => valid_url})

      # Should be accepted
      Distribution.Server.apply_update(server, dist_valid)

      # Verify new download started
      state = :sys.get_state(server)
      assert match?(%{status: {:updating, _}}, state)
      assert is_pid(state.download)
      assert is_pid(state.fwup)

      GenServer.stop(server)
      # Brief delay to let download processes clean up before cache is removed
      Process.sleep(50)
    end
  end

  describe "expired firmware URL - streamed downloads" do
    setup :setup_stream_download_server

    @tag capture_log: true
    test "asks for a new URL and resumes from the bytes streamed to fwup", %{config: config} do
      {:ok, server} = start_server(config)
      Distribution.Server.apply_update(server, distribution("refresh-stream", @unreachable_url))
      first_download = :sys.get_state(server).download
      assert is_pid(first_download)

      # the download got this far before its URL expired
      :sys.replace_state(server, &%{&1 | downloaded_bytes: 100})
      send(server, expired_message())

      assert_receive :new_url_requested, 2000
      assert %{awaiting_url: wait_ref} = :sys.get_state(server)
      assert is_reference(wait_ref)

      # the cloud answers the rejoin with the pending update and a fresh URL
      Distribution.Server.apply_update(server, distribution("refresh-stream", @fresh_url))

      state = :sys.get_state(server)
      assert state.awaiting_url == nil
      assert state.distribution.firmware_url == URI.parse(@fresh_url)
      assert state.download != first_download
      assert %{initial_downloaded_length: 100} = :sys.get_state(state.download)

      GenServer.stop(server)
    end

    @tag capture_log: true
    test "the URL that just failed isn't the answer", %{config: config} do
      {:ok, server} = start_server(config)
      Distribution.Server.apply_update(server, distribution("refresh-same", @unreachable_url))
      first_download = :sys.get_state(server).download

      send(
        server,
        {:download,
         {:fatal_http_error, 400, URI.parse(@unreachable_url), %{code: "ExpiredToken"}}}
      )

      assert_receive :new_url_requested, 2000

      Distribution.Server.apply_update(server, distribution("refresh-same", @unreachable_url))

      state = :sys.get_state(server)
      assert is_reference(state.awaiting_url)
      assert state.download == first_download

      GenServer.stop(server)
    end

    @tag capture_log: true
    test "an update for different firmware isn't the answer", %{config: config} do
      {:ok, server} = start_server(config)
      Distribution.Server.apply_update(server, distribution("refresh-a", @unreachable_url))
      first_download = :sys.get_state(server).download

      send(server, expired_message())
      assert_receive :new_url_requested, 2000

      Distribution.Server.apply_update(server, distribution("refresh-b", @fresh_url))

      state = :sys.get_state(server)
      assert is_reference(state.awaiting_url)
      assert state.download == first_download
      assert state.distribution.firmware_meta.uuid == "refresh-a"

      GenServer.stop(server)
    end

    @tag capture_log: true
    test "keeps asking, then aborts when no new URL arrives", %{config: config} do
      config = %{
        config
        | distributions_url_refresh_max_attempts: 2,
          distributions_url_refresh_wait_ms: 10
      }

      {:ok, server} = start_server(config)
      Distribution.Server.apply_update(server, distribution("refresh-timeout", @expired_url))

      assert_receive {Distribution.Server, :install, {:error, :http_download_failed}}, 5000

      assert_received :new_url_requested
      assert_received :new_url_requested
      refute_received :new_url_requested

      state = :sys.get_state(server)
      assert state.status == :idle
      assert state.distribution == nil
      assert state.awaiting_url == nil
      assert state.url_wait_timer == nil

      GenServer.stop(server)
    end

    @tag capture_log: true
    test "a timeout left over from an earlier wait is ignored", %{config: config} do
      {:ok, server} = start_server(config)
      Distribution.Server.apply_update(server, distribution("refresh-stale", @unreachable_url))

      send(server, expired_message())
      assert_receive :new_url_requested, 2000
      %{awaiting_url: wait_ref} = :sys.get_state(server)

      # the attempt number is back at 0 whenever data flows, so it can't identify a wait.
      # This one belongs to a wait that is long over.
      send(server, {:url_wait_timeout, make_ref()})

      refute_receive :new_url_requested, 200
      assert %{awaiting_url: ^wait_ref} = :sys.get_state(server)

      GenServer.stop(server)
    end

    @tag capture_log: true
    test "a wait left over from a failed update can't abort its replacement", %{config: config} do
      {:ok, server} = start_server(config)
      Distribution.Server.apply_update(server, distribution("replace-a", @unreachable_url))

      send(server, expired_message())
      assert_receive :new_url_requested, 2000
      %{awaiting_url: old_wait} = :sys.get_state(server)

      # fwup fails while the refresh is still waiting for its new URL
      send(server, {:fwup, {:error, 1, "fwup failed"}})

      assert %{status: {:fwup_error, _}, awaiting_url: nil, url_wait_timer: nil} =
               :sys.get_state(server)

      # a replacement update is accepted
      Distribution.Server.apply_update(server, distribution("replace-b", @unreachable_url))
      assert %{status: {:updating, _}} = :sys.get_state(server)

      # and the old wait's timeout arrives
      send(server, {:url_wait_timeout, old_wait})

      refute_receive :new_url_requested, 200
      state = :sys.get_state(server)
      assert {:updating, _} = state.status
      assert state.distribution.firmware_meta.uuid == "replace-b"

      GenServer.stop(server)
    end

    @tag capture_log: true
    test "an update that finishes ends a pending wait", %{config: config} do
      {:ok, server} = start_server(config)

      Distribution.Server.apply_update(
        server,
        distribution("finished-while-waiting", @unreachable_url)
      )

      send(server, expired_message())
      assert_receive :new_url_requested, 2000
      assert %{awaiting_url: wait_ref} = :sys.get_state(server)
      assert is_reference(wait_ref)

      send(server, {:fwup, {:ok, 0, "done"}})

      assert %{status: :idle, awaiting_url: nil, url_wait_timer: nil} = :sys.get_state(server)

      GenServer.stop(server)
    end

    @tag capture_log: true
    test "a replacement update clears a wait that was still pending", %{config: config} do
      {:ok, server} = start_server(config)

      :sys.replace_state(
        server,
        &%{&1 | awaiting_url: make_ref(), expired_url: URI.parse(@expired_url)}
      )

      Distribution.Server.apply_update(server, distribution("replacement", @unreachable_url))

      assert %{awaiting_url: nil, expired_url: nil, status: {:updating, _}} =
               :sys.get_state(server)

      GenServer.stop(server)
    end

    @tag capture_log: true
    test "an error a new URL can't fix aborts without asking for one", %{config: config} do
      {:ok, server} = start_server(config)

      Distribution.Server.apply_update(
        server,
        distribution("refresh-invalid", "http://localhost:4001/s3/invalid-argument")
      )

      assert_receive {Distribution.Server, :install, {:error, :http_download_failed}}, 3000
      refute_received :new_url_requested

      GenServer.stop(server)
    end

    @tag capture_log: true
    test "refreshing can be turned off", %{config: config} do
      config = %{config | distributions_url_refresh_max_attempts: 0}
      {:ok, server} = start_server(config)
      Distribution.Server.apply_update(server, distribution("refresh-off", @expired_url))

      assert_receive {Distribution.Server, :install, {:error, :http_download_failed}}, 3000
      refute_received :new_url_requested

      GenServer.stop(server)
    end

    @tag capture_log: true
    test "a fresh URL for firmware being downloaded is kept for later", %{config: config} do
      {:ok, server} = start_server(config)
      Distribution.Server.apply_update(server, distribution("refresh-adopt", @unreachable_url))
      first_download = :sys.get_state(server).download

      Distribution.Server.apply_update(server, distribution("refresh-adopt", @fresh_url))

      state = :sys.get_state(server)
      assert state.distribution.firmware_url == URI.parse(@fresh_url)
      # nothing was waiting for it, so the download isn't disturbed
      assert state.download == first_download
      refute_received :new_url_requested

      GenServer.stop(server)
    end

    @tag capture_log: true
    test "a wait that ends after the update did is ignored", %{config: config} do
      {:ok, server} = start_server(config)

      send(server, {:url_wait_timeout, make_ref()})

      refute_receive :new_url_requested, 200
      assert :sys.get_state(server).status == :idle

      GenServer.stop(server)
    end
  end

  describe "expired firmware URL - cached downloads" do
    setup :setup_cache_download_server

    @tag capture_log: true
    test "a replacement update clears a wait that was still pending", %{config: config} do
      {:ok, server} = start_server(config)
      :sys.replace_state(server, &%{&1 | awaiting_url: make_ref()})

      Distribution.Server.apply_update(
        server,
        distribution("replacement-cached", @unreachable_url)
      )

      assert %{awaiting_url: nil, status: {:updating, _}} = :sys.get_state(server)

      GenServer.stop(server)
    end

    @tag capture_log: true
    test "resumes from the .part file on disk", %{config: config} do
      {:ok, server} = start_server(config)
      Distribution.Server.apply_update(server, distribution("refresh-cache", @unreachable_url))

      %{download: first_download, download_file_path: part_file} = :sys.get_state(server)
      assert is_pid(first_download)

      part_path = Cache.abs_path(config.cache_pid, part_file)
      File.mkdir_p!(Path.dirname(part_path))
      File.write!(part_path, :binary.copy(<<0>>, 100))
      send(server, expired_message())
      assert_receive :new_url_requested, 2000

      Distribution.Server.apply_update(server, distribution("refresh-cache", @fresh_url))

      state = :sys.get_state(server)
      assert state.download != first_download
      assert %{initial_downloaded_length: 100} = :sys.get_state(state.download)

      GenServer.stop(server)
    end
  end

  describe "expired firmware URL - parallel downloads" do
    setup :setup_parallel_download_server

    @tag capture_log: true
    test "restarts the parallel download with the new URL", %{config: config} do
      {:ok, server} = start_server(config)

      Distribution.Server.apply_update(
        server,
        distribution("refresh-parallel", "http://localhost:4001/1M.bin")
      )

      %{download: first_download, parallel_total_size: total_size} = :sys.get_state(server)
      assert is_pid(first_download)
      assert total_size == 1_048_576

      send(server, expired_message())
      assert_receive :new_url_requested, 2000

      fresh_url = "http://localhost:4001/1M.bin?fresh=1"
      Distribution.Server.apply_update(server, distribution("refresh-parallel", fresh_url))

      state = :sys.get_state(server)
      assert state.distribution.firmware_url == URI.parse(fresh_url)
      assert is_pid(state.download)
      assert state.download != first_download
      assert state.parallel_total_size == 1_048_576

      GenServer.stop(server)
      Process.sleep(50)
    end

    @tag capture_log: true
    test "chunks announced again after a restart aren't streamed twice", %{config: config} do
      {:ok, server} = Distribution.Server.start_link(config, [])
      :sys.replace_state(server, &%{&1 | next_chunk_to_stream: 3, ready_chunk_files: %{}})

      send(server, {:download, {:chunk_complete, 1, "firmware.bin.part0001"}})

      assert %{ready_chunk_files: ready} = :sys.get_state(server)
      assert ready == %{}

      GenServer.stop(server)
    end
  end

  defp distribution(uuid, url) do
    firmware_meta = %{
      "uuid" => uuid,
      "version" => "1.0.0",
      "platform" => "test",
      "architecture" => "test",
      "product" => "test"
    }

    {:ok, dist} = Distribution.parse(%{"firmware_meta" => firmware_meta, "firmware_url" => url})
    dist
  end

  defp expired_message do
    {:download,
     {:fatal_http_error, 400, URI.parse(@unreachable_url),
      %{code: "ExpiredToken", message: "The provided token has expired."}}}
  end

  # What would be a rejoin of the device channel is reported to the test instead
  defp start_server(config) do
    test_pid = self()
    {:ok, server} = Distribution.Server.start_link(config, [])

    :sys.replace_state(server, fn state ->
      %{state | url_refresh_requester: fn -> send(test_pid, :new_url_requested) end}
    end)

    {:ok, server}
  end

  def setup_stream_download_server(context) do
    # Reuse cache + devpath setup, but disable caching during install
    context = start_cache(context)

    working_dir = "test/workspace/install/#{context.test}"
    File.mkdir_p(working_dir)
    devpath = Path.join(working_dir, "fwup.img")

    :os.cmd(~c"fwup -a -t complete -i test/fixtures/binaries/fwup.fw -d \"#{devpath}\"")

    application_config = Application.get_all_env(:peridiod)
    cache_dir = context.cache_dir
    cache_pid = context.cache_pid

    config =
      struct(Peridiod.Config, application_config)
      |> Peridiod.Config.new()
      |> Map.put(:fwup_devpath, devpath)
      |> Map.put(:fwup_extra_args, ["--unsafe", "-q"])
      |> Map.put(:cache_dir, cache_dir)
      |> Map.put(:cache_pid, cache_pid)
      |> Map.put(:distributions_cache_download, false)
      |> Map.put(:distributions_download_parallel_count, 0)

    Map.put(context, :config, config)
  end

  def setup_cache_download_server(context) do
    context = start_cache(context)

    working_dir = "test/workspace/install/#{context.test}"
    File.mkdir_p(working_dir)
    devpath = Path.join(working_dir, "fwup.img")

    :os.cmd(~c"fwup -a -t complete -i test/fixtures/binaries/fwup.fw -d \"#{devpath}\"")

    application_config = Application.get_all_env(:peridiod)
    cache_dir = context.cache_dir
    cache_pid = context.cache_pid

    config =
      struct(Peridiod.Config, application_config)
      |> Peridiod.Config.new()
      |> Map.put(:fwup_devpath, devpath)
      |> Map.put(:fwup_extra_args, ["--unsafe", "-q"])
      |> Map.put(:cache_dir, cache_dir)
      |> Map.put(:cache_pid, cache_pid)
      |> Map.put(:distributions_cache_download, true)
      |> Map.put(:distributions_download_parallel_count, 0)

    Map.put(context, :config, config)
  end

  def setup_parallel_download_server(context) do
    context = start_cache(context)

    working_dir = "test/workspace/install/#{context.test}"
    File.mkdir_p(working_dir)
    devpath = Path.join(working_dir, "fwup.img")

    :os.cmd(~c"fwup -a -t complete -i test/fixtures/binaries/fwup.fw -d \"#{devpath}\"")

    application_config = Application.get_all_env(:peridiod)
    cache_dir = context.cache_dir
    cache_pid = context.cache_pid

    config =
      struct(Peridiod.Config, application_config)
      |> Peridiod.Config.new()
      |> Map.put(:fwup_devpath, devpath)
      |> Map.put(:fwup_extra_args, ["--unsafe", "-q"])
      |> Map.put(:cache_dir, cache_dir)
      |> Map.put(:cache_pid, cache_pid)
      |> Map.put(:distributions_cache_download, true)
      |> Map.put(:distributions_download_parallel_count, 2)
      |> Map.put(:distributions_download_parallel_chunk_bytes, 524_288)

    Map.put(context, :config, config)
  end
end
