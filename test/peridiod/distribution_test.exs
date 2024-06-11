defmodule Peridiod.DistributionTest do
  use PeridiodTest.Case
  doctest Peridiod.Binary.Installer

  alias Peridiod.Distribution

  describe "distribution server" do
    setup :setup_server

    test "apply update", %{config: config} do
      {:ok, server} = Distribution.Server.start_link(config, [])
      url = "http://localhost:4001/fwup.fw"
      {:ok, dist} = Distribution.parse(%{"firmware_meta" => %{}, "firmware_url" => url})
      Distribution.Server.apply_update(server, dist)
      assert_receive {Distribution.Server, :install, :complete}
    end

    @tag capture_log: true
    test "untrusted", %{config: config} do
      config =
        Map.put(config, :fwup_public_keys, ["WCdq239ZAvOT/X8x5hJBMpXHDC2QhREO5prKwnJyKY0="])

      {:ok, server} = Distribution.Server.start_link(config, [])

      url = "http://localhost:4001/fwup-trusted.fw"
      {:ok, dist} = Distribution.parse(%{"firmware_meta" => %{}, "firmware_url" => url})
      Distribution.Server.apply_update(server, dist)
      assert_receive {Distribution.Server, :install, {:error, error}}
      assert error =~ "fails digital signature verification"
    end
  end

  def setup_server(context) do
    working_dir = "test/workspace/install/#{context.test}"
    File.mkdir_p(working_dir)
    devpath = Path.join(working_dir, "fwup.img")

    :os.cmd(~c"fwup -a -t complete -i test/fixtures/binaries/fwup.fw -d \"#{devpath}\"")

    application_config = Application.get_all_env(:peridiod)

    config =
      struct(Peridiod.Config, application_config)
      |> Peridiod.Config.new()
      |> Map.put(:fwup_devpath, devpath)
      |> Map.put(:fwup_extra_args, ["--unsafe"])

    Map.put(context, :config, config)
  end
end
