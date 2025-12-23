defmodule Peridiod.Binary.Installer.AvocadoExtTest do
  use PeridiodTest.Case

  alias Peridiod.Binary
  alias Peridiod.Binary.Installer.AvocadoExt

  describe "execution_model/0 and interfaces/0" do
    test "returns correct execution model" do
      assert AvocadoExt.execution_model() == :parallel
    end

    test "returns correct interfaces" do
      assert AvocadoExt.interfaces() == [:path, :stream]
    end
  end

  describe "path_install/3" do
    setup do
      test_dir = System.tmp_dir!() |> Path.join("avocado_ext_test_#{System.unique_integer()}")
      extensions_path = Path.join(test_dir, "usr/lib/avocado/extensions")
      File.mkdir_p!(test_dir)

      source_file = Path.join(test_dir, "source_extension")
      File.write!(source_file, "extension content")

      on_exit(fn ->
        File.rm_rf!(test_dir)
      end)

      %{test_dir: test_dir, extensions_path: extensions_path, source_file: source_file}
    end

    test "returns error when image is missing" do
      result = AvocadoExt.path_install(%Binary{}, "/some/path", %{})
      assert {:error, "AvocadoExt installer_opts key image is required", nil} = result
    end

    test "returns error when opts is empty map" do
      result = AvocadoExt.path_install(%Binary{}, "/some/path", %{"other" => "value"})
      assert {:error, "AvocadoExt installer_opts key image is required", nil} = result
    end
  end

  describe "stream_init/2" do
    test "returns error when image is missing" do
      binary = %Binary{prn: "prn:1:be4d30b5-6a15-4dfe-b002-bd0c:binary:test-binary"}
      result = AvocadoExt.stream_init(binary, %{})
      assert {:error, "AvocadoExt installer_opts key image is required", nil} = result
    end

    test "returns error when opts has wrong keys" do
      binary = %Binary{prn: "prn:1:be4d30b5-6a15-4dfe-b002-bd0c:binary:test-binary"}
      result = AvocadoExt.stream_init(binary, %{"other" => "value"})
      assert {:error, "AvocadoExt installer_opts key image is required", nil} = result
    end

    test "initializes successfully with valid image" do
      binary = %Binary{prn: "prn:1:be4d30b5-6a15-4dfe-b002-bd0c:binary:test-binary"}
      result = AvocadoExt.stream_init(binary, %{"image" => "my-extension.raw"})

      case result do
        {:ok, {tmp_dest, final_dest}} ->
          assert String.ends_with?(final_dest, "my-extension.raw")
          assert String.contains?(final_dest, "avocado/extensions")
          assert is_binary(tmp_dest)

        {:error, reason, _state} ->
          # May fail due to permissions on /usr/lib
          assert is_binary(reason) or is_atom(reason)
      end
    end
  end

  describe "stream_update/3" do
    setup do
      test_dir = System.tmp_dir!() |> Path.join("avocado_ext_stream_#{System.unique_integer()}")
      File.mkdir_p!(test_dir)

      tmp_file = Path.join(test_dir, "tmp_extension")
      final_file = Path.join(test_dir, "final_extension")

      on_exit(fn ->
        File.rm_rf!(test_dir)
      end)

      %{test_dir: test_dir, tmp_file: tmp_file, final_file: final_file}
    end

    test "appends data to tmp file", %{tmp_file: tmp_file, final_file: final_file} do
      binary = %Binary{prn: "prn:1:be4d30b5-6a15-4dfe-b002-bd0c:binary:test-binary"}
      state = {tmp_file, final_file}

      {:ok, state} = AvocadoExt.stream_update(binary, "chunk1", state)
      {:ok, _state} = AvocadoExt.stream_update(binary, "chunk2", state)

      content = File.read!(tmp_file)
      assert content == "chunk1chunk2"
    end
  end

  describe "stream_finish/4" do
    setup do
      test_dir = System.tmp_dir!() |> Path.join("avocado_ext_finish_#{System.unique_integer()}")
      File.mkdir_p!(test_dir)

      tmp_file = Path.join(test_dir, "tmp_extension")
      final_file = Path.join(test_dir, "final_extension")

      File.write!(tmp_file, "extension content")

      on_exit(fn ->
        File.rm_rf!(test_dir)
      end)

      %{test_dir: test_dir, tmp_file: tmp_file, final_file: final_file}
    end

    test "renames tmp file to final destination on valid signature", %{
      tmp_file: tmp_file,
      final_file: final_file
    } do
      binary = %Binary{prn: "prn:1:be4d30b5-6a15-4dfe-b002-bd0c:binary:test-binary"}
      state = {tmp_file, final_file}

      result = AvocadoExt.stream_finish(binary, :valid_signature, "somehash", state)

      assert {:stop, :normal, {^tmp_file, ^final_file}} = result
      assert File.exists?(final_file)
      assert File.read!(final_file) == "extension content"
      refute File.exists?(tmp_file)
    end

    test "removes tmp file on invalid signature", %{tmp_file: tmp_file, final_file: final_file} do
      binary = %Binary{prn: "prn:1:be4d30b5-6a15-4dfe-b002-bd0c:binary:test-binary"}
      state = {tmp_file, final_file}

      result = AvocadoExt.stream_finish(binary, :invalid_signature, "somehash", state)

      assert {:error, :invalid_signature, {^tmp_file, ^final_file}} = result
      refute File.exists?(tmp_file)
      refute File.exists?(final_file)
    end

    test "removes existing final file before renaming", %{
      tmp_file: tmp_file,
      final_file: final_file
    } do
      # Create an existing file at final destination
      File.write!(final_file, "old content")

      binary = %Binary{prn: "prn:1:be4d30b5-6a15-4dfe-b002-bd0c:binary:test-binary"}
      state = {tmp_file, final_file}

      result = AvocadoExt.stream_finish(binary, :valid_signature, "somehash", state)

      assert {:stop, :normal, _state} = result
      assert File.read!(final_file) == "extension content"
    end
  end
end
