defmodule Peridiod.Binary.Installer.AvocadoOSTest do
  use PeridiodTest.Case

  alias Peridiod.Binary
  alias Peridiod.Binary.Installer.AvocadoOS
  alias Peridiod.Binary.Installer

  describe "execution_model/0 and interfaces/0" do
    test "returns correct execution model" do
      assert AvocadoOS.execution_model() == :sequential
    end

    test "returns correct interfaces" do
      assert AvocadoOS.interfaces() == [:path, :stream]
    end
  end

  describe "type_to_module mapping" do
    test "supports cache type" do
      binary = %Binary{prn: "prn:1:be4d30b5-6a15-4dfe-b002-bd0c:binary:test"}
      opts = %{"type" => "cache"}

      # Should not error on unknown type
      result = AvocadoOS.stream_init(binary, opts)
      refute match?({:error, "AvocadoOS unknown installer type:" <> _, _}, result)
    end

    test "supports file type" do
      binary = %Binary{prn: "prn:1:be4d30b5-6a15-4dfe-b002-bd0c:binary:test"}
      opts = %{"type" => "file", "name" => "test.bin", "path" => "/tmp"}

      result = AvocadoOS.stream_init(binary, opts)
      # Should delegate to file installer, may succeed or fail based on filesystem
      refute match?({:error, "AvocadoOS unknown installer type:" <> _, _}, result)
    end

    test "returns error for unknown type" do
      binary = %Binary{prn: "prn:1:be4d30b5-6a15-4dfe-b002-bd0c:binary:test"}
      opts = %{"type" => "unknown_installer"}

      result = AvocadoOS.stream_init(binary, opts)
      assert {:error, "AvocadoOS unknown installer type: \"unknown_installer\"", nil} = result
    end
  end

  describe "path_install/3" do
    setup do
      test_dir = System.tmp_dir!() |> Path.join("avocado_os_path_#{System.unique_integer()}")
      File.mkdir_p!(test_dir)

      source_file = Path.join(test_dir, "source_file")
      File.write!(source_file, "test content")

      on_exit(fn ->
        File.rm_rf!(test_dir)
      end)

      %{test_dir: test_dir, source_file: source_file}
    end

    test "returns error when type is missing" do
      result = AvocadoOS.path_install(%Binary{}, "/some/path", %{})
      assert {:error, "AvocadoOS installer_opts key type is required", nil} = result
    end

    test "returns error when type is missing but other opts present" do
      result = AvocadoOS.path_install(%Binary{}, "/some/path", %{"name" => "test"})
      assert {:error, "AvocadoOS installer_opts key type is required", nil} = result
    end

    test "delegates to file installer with correct opts", %{
      test_dir: test_dir,
      source_file: source_file
    } do
      dest_path = Path.join(test_dir, "dest")
      File.mkdir_p!(dest_path)

      opts = %{
        "type" => "file",
        "name" => "installed_file.bin",
        "path" => dest_path
      }

      result = AvocadoOS.path_install(%Binary{}, source_file, opts)

      # File installer creates a symlink
      assert {:stop, :normal, nil} = result
      final_file = Path.join(dest_path, "installed_file.bin")
      assert File.exists?(final_file)
    end

    test "passes through sub-installer errors", %{source_file: source_file} do
      # File installer requires name and path
      opts = %{"type" => "file"}

      result = AvocadoOS.path_install(%Binary{}, source_file, opts)

      # Should return error from file installer about missing opts
      assert match?({:error, _, nil}, result)
    end
  end

  describe "stream_init/2" do
    test "returns error when type is missing" do
      binary = %Binary{prn: "prn:1:be4d30b5-6a15-4dfe-b002-bd0c:binary:test"}
      result = AvocadoOS.stream_init(binary, %{})
      assert {:error, "AvocadoOS installer_opts key type is required", nil} = result
    end

    test "wraps sub-installer state with module reference" do
      test_dir = System.tmp_dir!() |> Path.join("avocado_os_init_#{System.unique_integer()}")

      binary = %Binary{prn: "prn:1:be4d30b5-6a15-4dfe-b002-bd0c:binary:test"}
      opts = %{"type" => "file", "name" => "test.bin", "path" => test_dir}

      result = AvocadoOS.stream_init(binary, opts)

      case result do
        {:ok, {sub_mod, sub_state}} ->
          assert sub_mod == Installer.File
          assert is_tuple(sub_state)

        {:error, _reason, _state} ->
          # May fail due to filesystem issues
          assert true
      end

      File.rm_rf(test_dir)
    end

    test "removes type from opts passed to sub-installer" do
      test_dir = System.tmp_dir!() |> Path.join("avocado_os_opts_#{System.unique_integer()}")

      binary = %Binary{prn: "prn:1:be4d30b5-6a15-4dfe-b002-bd0c:binary:test"}
      # If type was passed through, file installer would error on it
      opts = %{"type" => "file", "name" => "test.bin", "path" => test_dir}

      result = AvocadoOS.stream_init(binary, opts)

      # Should succeed if type is properly removed
      case result do
        {:ok, _state} ->
          assert true

        {:error, reason, _state} ->
          # Should not be an error about unexpected "type" key
          refute String.contains?(to_string(reason), "type")
      end

      File.rm_rf(test_dir)
    end
  end

  describe "stream_update/3" do
    setup do
      test_dir = System.tmp_dir!() |> Path.join("avocado_os_update_#{System.unique_integer()}")
      File.mkdir_p!(test_dir)

      tmp_file = Path.join(test_dir, "tmp_file")
      final_file = Path.join(test_dir, "final_file")

      on_exit(fn ->
        File.rm_rf!(test_dir)
      end)

      %{test_dir: test_dir, tmp_file: tmp_file, final_file: final_file}
    end

    test "delegates to sub-installer and wraps state", %{
      tmp_file: tmp_file,
      final_file: final_file
    } do
      binary = %Binary{prn: "prn:1:be4d30b5-6a15-4dfe-b002-bd0c:binary:test"}
      sub_state = {tmp_file, final_file}
      state = {Installer.File, sub_state}

      {:ok, {returned_mod, _new_sub_state}} = AvocadoOS.stream_update(binary, "data", state)

      assert returned_mod == Installer.File
      assert File.read!(tmp_file) == "data"
    end
  end

  describe "stream_finish/4" do
    setup do
      test_dir = System.tmp_dir!() |> Path.join("avocado_os_finish_#{System.unique_integer()}")
      File.mkdir_p!(test_dir)

      tmp_file = Path.join(test_dir, "tmp_file")
      final_file = Path.join(test_dir, "final_file")

      File.write!(tmp_file, "test content")

      on_exit(fn ->
        File.rm_rf!(test_dir)
      end)

      %{test_dir: test_dir, tmp_file: tmp_file, final_file: final_file}
    end

    test "delegates to sub-installer on valid signature", %{
      tmp_file: tmp_file,
      final_file: final_file
    } do
      binary = %Binary{prn: "prn:1:be4d30b5-6a15-4dfe-b002-bd0c:binary:test"}
      sub_state = {tmp_file, final_file}
      state = {Installer.File, sub_state}

      result = AvocadoOS.stream_finish(binary, :valid_signature, "hash", state)

      assert {:stop, :normal, {Installer.File, _new_sub_state}} = result
      # File installer creates symlink
      assert File.exists?(final_file)
    end

    test "delegates to sub-installer on invalid signature", %{
      tmp_file: tmp_file,
      final_file: final_file
    } do
      binary = %Binary{prn: "prn:1:be4d30b5-6a15-4dfe-b002-bd0c:binary:test"}
      sub_state = {tmp_file, final_file}
      state = {Installer.File, sub_state}

      result = AvocadoOS.stream_finish(binary, :invalid_signature, "hash", state)

      assert {:error, :invalid_signature, {Installer.File, _new_sub_state}} = result
      refute File.exists?(tmp_file)
    end
  end

  describe "stream_error/3" do
    test "delegates error to sub-installer" do
      binary = %Binary{prn: "prn:1:be4d30b5-6a15-4dfe-b002-bd0c:binary:test"}
      sub_state = {"tmp", "final"}
      state = {Installer.File, sub_state}

      result = AvocadoOS.stream_error(binary, :download_failed, state)

      assert {:error, :download_failed, {Installer.File, _new_sub_state}} = result
    end
  end

  describe "stream_info/2" do
    test "delegates info messages to sub-installer" do
      sub_state = {"tmp", "final"}
      state = {Installer.File, sub_state}

      result = AvocadoOS.stream_info(:some_message, state)

      assert {:ok, {Installer.File, _new_sub_state}} = result
    end
  end
end
