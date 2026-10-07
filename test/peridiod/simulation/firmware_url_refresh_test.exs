defmodule Peridiod.Simulation.FirmwareUrlRefreshTest do
  @moduledoc """
  The firmware URL refresh end to end, with nothing mocked on the device side.

  The real `Cloud.Socket` (Slipstream) connects over TLS to a fake Peridio device
  channel, the real `Distribution.Server` downloads from a fake S3 whose signed
  URLs expire, and fwup applies the firmware. What is simulated is the cloud:

    * `PeridiodTest.FakeDeviceServer` speaks the Phoenix channel protocol and
      answers each join with the pending update, signing a fresh URL when the
      device reports the firmware it is downloading.
    * `PeridiodTest.FakeS3` serves the firmware at tokens that expire the way an
      S3 presigned URL does when its STS session ends (HTTP 400 `ExpiredToken`).
  """
  use PeridiodTest.Case

  alias Peridiod.{Cloud, Config, Distribution}

  @uuid "sim-firmware-uuid"

  setup context do
    start_supervised!(PeridiodTest.FakeS3)
    start_supervised!(PeridiodTest.FakeDeviceServer)
    PeridiodTest.FakeS3.notify(self())

    port = PeridiodTest.FakeDeviceServer.start(self())
    on_exit(&PeridiodTest.FakeDeviceServer.stop/0)

    # the fake server's certificate is self-signed
    original_tls_opts = Cloud.get_tls_opts()
    :ok = Cloud.update_tls_opts(Keyword.put(original_tls_opts, :verify, :verify_none))
    on_exit(fn -> Cloud.update_tls_opts(original_tls_opts) end)

    context = start_cache(context)
    devpath = Path.join("test/workspace/install/#{context.test}", "fwup.img")
    File.mkdir_p!(Path.dirname(devpath))
    :os.cmd(~c"fwup -a -t complete -i test/fixtures/binaries/fwup.fw -d \"#{devpath}\"")

    config =
      struct(Config, Application.get_all_env(:peridiod))
      |> Config.new()
      |> Map.merge(%{
        fwup_devpath: devpath,
        fwup_extra_args: ["--unsafe", "-q"],
        cache_dir: context.cache_dir,
        cache_pid: context.cache_pid,
        distributions_cache_download: false,
        distributions_download_parallel_count: 0,
        device_api_host: "localhost",
        device_api_port: port,
        remote_shell: false,
        remote_iex: false,
        remote_access_tunnels: %{enabled: false}
      })

    {:ok, config: config}
  end

  # The cloud answers a join with the pending firmware. A join that reports the
  # firmware being downloaded gets a freshly signed URL, any other the stale one.
  defp pending_update_join_handler do
    firmware_meta = %{
      "uuid" => @uuid,
      "product" => "sim",
      "version" => "1.0.0",
      "architecture" => "test",
      "platform" => "test",
      "author" => nil,
      "description" => nil,
      "vcs_identifier" => nil,
      "misc" => nil
    }

    fn params ->
      token = if params["currently_downloading_uuid"] == @uuid, do: "fresh", else: "stale"

      %{
        "update_available" => true,
        "firmware_url" => "http://localhost:4001/sim/#{token}/fwup.fw",
        "firmware_meta" => firmware_meta,
        "deployment_id" => "c0b60586-b445-4ec1-b0e1-6c0c70ae4169"
      }
    end
  end

  defp start_device(config) do
    PeridiodTest.FakeDeviceServer.set_join_handler(pending_update_join_handler())
    start_device_with_handler(config)
  end

  defp start_device_with_handler(config) do
    start_supervised!(Cloud.Connection)
    start_supervised!({Distribution.Server, config})
    watch_distribution_server()
    start_supervised!({Cloud.Socket, config})
  end

  # Reports the messages the server receives, to see fwup's verdict
  defp watch_distribution_server do
    test_pid = self()

    :sys.install(
      Distribution.Server,
      {fn state, event, _process_state ->
         send(test_pid, {:server_event, event})
         state
       end, :ok}
    )
  end

  # fwup applied the firmware, which only happens when the stream it was fed is
  # complete and valid
  defp assert_firmware_installed(timeout \\ 20_000) do
    assert_receive {:server_event, {:in, {:fwup, {:ok, 0, _message}}}}, timeout
  end

  defp refute_firmware_installed do
    refute_received {:server_event, {:in, {:fwup, {:ok, 0, _message}}}}
  end

  defp wait_until_idle(attempts \\ 300) do
    state = :sys.get_state(Distribution.Server)

    cond do
      state.status == :idle and state.distribution == nil -> :ok
      attempts == 0 -> flunk("the update never ended, status: #{inspect(state.status)}")
      true -> Process.sleep(100) && wait_until_idle(attempts - 1)
    end
  end

  describe "the URL has already expired when the download starts" do
    @tag capture_log: true
    test "the device gets a fresh URL by rejoining and installs the firmware", %{config: config} do
      PeridiodTest.FakeS3.put_token("stale", expired: true)
      PeridiodTest.FakeS3.put_token("fresh")

      start_device(config)

      # connecting joins the channel, the cloud answers with the pending update
      assert_receive {:fake_device, :join, "device", first_join}, 10_000
      refute first_join["currently_downloading_uuid"]
      assert_receive {:s3_request, "stale", nil}, 10_000

      # the stale URL is refused, so the device rejoins and says what it is downloading
      assert_receive {:fake_device, :leave, "device"}, 10_000
      assert_receive {:fake_device, :join, "device", second_join}, 10_000
      assert second_join["currently_downloading_uuid"] == @uuid

      # the answer carries the fresh URL, and the download carries on with it
      assert_receive {:s3_request, "fresh", nil}, 10_000
      assert_firmware_installed()
    end

    @tag capture_log: true
    test "gives up when the cloud keeps answering with the expired URL", %{config: config} do
      config = %{config | distributions_url_refresh_max_attempts: 2}
      config = %{config | distributions_url_refresh_wait_ms: 200}

      PeridiodTest.FakeS3.put_token("stale", expired: true)
      # the rejoin gets the expired URL again, whatever the device reports
      PeridiodTest.FakeDeviceServer.set_join_handler(fn _params ->
        %{
          "update_available" => true,
          "firmware_url" => "http://localhost:4001/sim/stale/fwup.fw",
          "firmware_meta" => %{
            "uuid" => @uuid,
            "product" => "sim",
            "version" => "1.0.0",
            "architecture" => "test",
            "platform" => "test"
          },
          "deployment_id" => "c0b60586-b445-4ec1-b0e1-6c0c70ae4169"
        }
      end)

      start_device_with_handler(config)

      assert_receive {:s3_request, "stale", nil}, 10_000
      # it asked for a new URL twice, then stopped
      assert_receive {:fake_device, :leave, "device"}, 10_000
      assert_receive {:fake_device, :leave, "device"}, 10_000
      wait_until_idle()
      refute_receive {:fake_device, :leave, "device"}, 1_000
      refute_firmware_installed()
    end
  end

  describe "a refresh is requested while the channel isn't joined" do
    @tag capture_log: true
    test "there is nothing to leave, so no flag is left behind", %{config: config} do
      # nothing listens on this port, so the socket never joins
      config = %{config | device_api_port: 1}
      PeridiodTest.FakeDeviceServer.set_join_handler(pending_update_join_handler())

      start_supervised!(Cloud.Connection)
      start_supervised!({Distribution.Server, config})
      start_supervised!({Cloud.Socket, config})

      Cloud.Socket.refresh_update()

      # a leave that never happens would leave this set, and a later close would rejoin
      assert %{assigns: %{rejoin_for_update: false}} = :sys.get_state(Cloud.Socket)
      refute_receive {:fake_device, :leave, _}, 300
    end
  end

  describe "the channel crashes while the firmware downloads" do
    # Slipstream waits 5 seconds before it rejoins
    @tag :slow
    @tag capture_log: true
    test "the device rejoins reporting the firmware it is downloading", %{config: config} do
      # the download is under way, and stays there
      PeridiodTest.FakeS3.put_token("stale", budget: 100, then: :stall)
      start_device(config)

      assert_receive {:fake_device, :join, "device", first_join}, 10_000
      refute first_join["currently_downloading_uuid"]
      assert_receive {:s3_request, "stale", nil}, 10_000

      PeridiodTest.FakeDeviceServer.end_topic("device", "phx_error")

      # a join that said nothing would count as another attempt to update the device
      assert_receive {:fake_device, :join, "device", rejoin}, 15_000
      assert rejoin["currently_downloading_uuid"] == @uuid
    end
  end

  describe "the URL expires while the download is under way" do
    # The first response is cut after 100 bytes. The downloader waits 15 seconds
    # before it resumes, and by then the URL is dead. That wait is why this one is
    # slow: run it with `mix test --include slow`.
    @tag :slow
    @tag capture_log: true
    @tag timeout: 90_000
    test "the device resumes from the bytes it has with the fresh URL", %{config: config} do
      PeridiodTest.FakeS3.put_token("stale", budget: 100)
      PeridiodTest.FakeS3.put_token("fresh")

      start_device(config)

      assert_receive {:fake_device, :join, "device", first_join}, 10_000
      refute first_join["currently_downloading_uuid"]
      assert_receive {:s3_request, "stale", nil}, 10_000

      # the resume asks for the rest with the same URL, which has expired by now
      assert_receive {:s3_request, "stale", "bytes=100-"}, 30_000
      assert_receive {:fake_device, :leave, "device"}, 10_000
      assert_receive {:fake_device, :join, "device", rejoin}, 10_000
      assert rejoin["currently_downloading_uuid"] == @uuid

      # and carries on from the same offset with the fresh URL
      assert_receive {:s3_request, "fresh", "bytes=100-"}, 10_000
      assert_firmware_installed()
    end
  end
end
