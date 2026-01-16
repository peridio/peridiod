defmodule Peridiod.Distribution.DownloadTest do
  use PeridiodTest.Case

  alias Peridiod.{Distribution, Config}

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
