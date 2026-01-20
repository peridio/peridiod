defmodule Peridiod.ClientTest do
  use ExUnit.Case, async: true

  alias Peridiod.Client

  # Test client that implements reboot/1 with custom options
  defmodule TestClientWithOpts do
    @behaviour Peridiod.Client

    @impl Peridiod.Client
    def update_available(_data), do: :apply

    @impl Peridiod.Client
    def handle_fwup_message(_message), do: :ok

    @impl Peridiod.Client
    def handle_error(_error), do: :ok

    @impl Peridiod.Client
    def reboot(opts) do
      # Send opts to test process to verify they were passed correctly
      send(:client_test_process, {:reboot_called, opts})
      :ok
    end
  end

  # Legacy test client that implements reboot/0 (backward compatibility)
  defmodule LegacyTestClient do
    @behaviour Peridiod.Client

    @impl Peridiod.Client
    def update_available(_data), do: :apply

    @impl Peridiod.Client
    def handle_fwup_message(_message), do: :ok

    @impl Peridiod.Client
    def handle_error(_error), do: :ok

    # Old-style reboot/0 for backward compatibility testing
    def reboot() do
      send(:client_test_process, {:legacy_reboot_called})
      :ok
    end
  end

  # Test client with no reboot callback
  defmodule MinimalTestClient do
    @behaviour Peridiod.Client

    @impl Peridiod.Client
    def update_available(_data), do: :apply

    @impl Peridiod.Client
    def handle_fwup_message(_message), do: :ok

    @impl Peridiod.Client
    def handle_error(_error), do: :ok
  end

  describe "initiate_reboot/0" do
    setup do
      # Register this process so test clients can send messages back
      Process.register(self(), :client_test_process)

      on_exit(fn ->
        # Only unregister if still registered
        if Process.whereis(:client_test_process) do
          Process.unregister(:client_test_process)
        end
      end)

      :ok
    end

    test "calls reboot/1 with config options when client implements reboot/1" do
      # Set custom client
      original_client = Application.get_env(:peridiod, :client)
      Application.put_env(:peridiod, :client, TestClientWithOpts)

      # Call initiate_reboot
      assert :ok = Client.initiate_reboot()

      # Verify reboot was called with proper options
      assert_receive {:reboot_called, opts}

      # Verify all required config keys are present
      assert Map.has_key?(opts, :reboot_cmd)
      assert Map.has_key?(opts, :reboot_opts)
      assert Map.has_key?(opts, :reboot_sync_cmd)
      assert Map.has_key?(opts, :reboot_sync_opts)

      # Verify default values
      assert opts[:reboot_cmd] == "reboot"
      assert opts[:reboot_opts] == []
      assert opts[:reboot_sync_cmd] == "sync"
      assert opts[:reboot_sync_opts] == []

      # Restore original client
      if original_client do
        Application.put_env(:peridiod, :client, original_client)
      else
        Application.delete_env(:peridiod, :client)
      end
    end

    test "calls reboot/1 with custom config options" do
      # Set custom client and config
      original_client = Application.get_env(:peridiod, :client)
      original_reboot_cmd = Application.get_env(:peridiod, :reboot_cmd)
      original_reboot_opts = Application.get_env(:peridiod, :reboot_opts)
      original_sync_cmd = Application.get_env(:peridiod, :reboot_sync_cmd)
      original_sync_opts = Application.get_env(:peridiod, :reboot_sync_opts)

      Application.put_env(:peridiod, :client, TestClientWithOpts)
      Application.put_env(:peridiod, :reboot_cmd, "/sbin/reboot")
      Application.put_env(:peridiod, :reboot_opts, ["-f"])
      Application.put_env(:peridiod, :reboot_sync_cmd, "/bin/sync")
      Application.put_env(:peridiod, :reboot_sync_opts, ["-f"])

      # Call initiate_reboot
      assert :ok = Client.initiate_reboot()

      # Verify custom options were passed
      assert_receive {:reboot_called, opts}
      assert opts[:reboot_cmd] == "/sbin/reboot"
      assert opts[:reboot_opts] == ["-f"]
      assert opts[:reboot_sync_cmd] == "/bin/sync"
      assert opts[:reboot_sync_opts] == ["-f"]

      # Restore original config
      if original_client,
        do: Application.put_env(:peridiod, :client, original_client),
        else: Application.delete_env(:peridiod, :client)

      if original_reboot_cmd,
        do: Application.put_env(:peridiod, :reboot_cmd, original_reboot_cmd),
        else: Application.delete_env(:peridiod, :reboot_cmd)

      if original_reboot_opts,
        do: Application.put_env(:peridiod, :reboot_opts, original_reboot_opts),
        else: Application.delete_env(:peridiod, :reboot_opts)

      if original_sync_cmd,
        do: Application.put_env(:peridiod, :reboot_sync_cmd, original_sync_cmd),
        else: Application.delete_env(:peridiod, :reboot_sync_cmd)

      if original_sync_opts,
        do: Application.put_env(:peridiod, :reboot_sync_opts, original_sync_opts),
        else: Application.delete_env(:peridiod, :reboot_sync_opts)
    end

    test "calls legacy reboot/0 for backward compatibility" do
      # Set legacy client
      original_client = Application.get_env(:peridiod, :client)
      Application.put_env(:peridiod, :client, LegacyTestClient)

      # Call initiate_reboot
      assert :ok = Client.initiate_reboot()

      # Verify legacy reboot was called
      assert_receive {:legacy_reboot_called}

      # Restore original client
      if original_client do
        Application.put_env(:peridiod, :client, original_client)
      else
        Application.delete_env(:peridiod, :client)
      end
    end

    test "falls back to :os.cmd when client has no reboot callback" do
      # Set minimal client with no reboot callback
      original_client = Application.get_env(:peridiod, :client)
      Application.put_env(:peridiod, :client, MinimalTestClient)

      # Call initiate_reboot - should not crash
      assert :ok = Client.initiate_reboot()

      # Note: We can't easily test :os.cmd('reboot') being called in test env,
      # but we verify it doesn't crash and returns :ok

      # Restore original client
      if original_client do
        Application.put_env(:peridiod, :client, original_client)
      else
        Application.delete_env(:peridiod, :client)
      end
    end
  end

  describe "Peridiod.Client.Default" do
    alias Peridiod.Client.Default

    test "reboot/1 accepts opts map with defaults" do
      # This will skip actual reboot in test env
      # We just verify it doesn't crash
      assert Default.reboot(%{}) == :ok
    end

    test "reboot/1 can be called with no arguments (default opts)" do
      # Should work with default argument
      assert Default.reboot() == :ok
    end

    test "reboot/1 accepts custom command options" do
      opts = %{
        reboot_cmd: "custom-reboot",
        reboot_opts: ["--force"],
        reboot_sync_cmd: "custom-sync",
        reboot_sync_opts: ["--data"]
      }

      # Should not crash with custom opts
      assert Default.reboot(opts) == :ok
    end

    test "reboot/1 uses defaults when keys are missing" do
      # Partial opts should work with defaults for missing keys
      opts = %{reboot_cmd: "custom-reboot"}

      assert Default.reboot(opts) == :ok
    end
  end
end
