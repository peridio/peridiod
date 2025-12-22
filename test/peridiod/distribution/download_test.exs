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

      # Deterministically assert immediate state
      state = :sys.get_state(server)
      assert match?(%{status: {:updating, 0}}, state)
      assert is_pid(state.fwup)
      assert is_pid(state.download)

      GenServer.stop(server)
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
