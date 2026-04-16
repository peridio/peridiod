defmodule Peridiod.ConfigTest do
  use ExUnit.Case

  defp build_config do
    Application.get_all_env(:peridiod)
    |> then(&struct(Peridiod.Config, &1))
    |> Peridiod.Config.new()
  end

  defp with_config_file(path, fun) do
    original = System.get_env("PERIDIO_CONFIG_FILE")
    System.put_env("PERIDIO_CONFIG_FILE", path)

    try do
      fun.()
    after
      case original do
        nil -> System.delete_env("PERIDIO_CONFIG_FILE")
        val -> System.put_env("PERIDIO_CONFIG_FILE", val)
      end
    end
  end

  describe "device_api_verify" do
    test "struct default is :verify_peer" do
      assert %Peridiod.Config{}.device_api_verify == :verify_peer
    end

    test "verify: true resolves to :verify_peer" do
      config = build_config()
      assert config.ssl[:verify] == :verify_peer
    end

    test "verify: false resolves to :verify_none in non-prod env" do
      with_config_file("test/fixtures/peridio-verify-none.json", fn ->
        config = build_config()
        assert config.ssl[:verify] == :verify_none
      end)
    end
  end
end
