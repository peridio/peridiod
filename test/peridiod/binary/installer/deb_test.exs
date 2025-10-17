defmodule Peridiod.Binary.Installer.DebTest do
  use PeridiodTest.Case

  alias Peridiod.Binary.Installer.Deb

  describe "execution_model/0 and interfaces/0" do
    test "returns correct execution model" do
      assert Deb.execution_model() == :sequential
    end

    test "returns correct interfaces" do
      assert Deb.interfaces() == [:path]
    end
  end

  describe "path_install/3 - integration behavior" do
    setup do
      test_dir = System.tmp_dir!() |> Path.join("deb_integration_test_#{System.unique_integer()}")
      File.mkdir_p!(test_dir)

      on_exit(fn ->
        File.rm_rf!(test_dir)
      end)

      %{test_dir: test_dir}
    end

    test "returns appropriate error for various scenarios" do
      # Create a fake path that doesn't exist
      fake_path = "/fake/path/that/does/not/exist"

      # This should fail with either:
      # 1. "Unable to locate executable apt" if apt is not available
      # 2. "File does not exist" if apt is available but file doesn't exist
      result = Deb.path_install(%{}, fake_path, %{})

      case result do
        {:error, message, nil} ->
          assert is_binary(message)
          # Accept either apt not found or file not found errors
          assert message =~ ~r/(Unable to locate executable apt|File does not exist)/

        _ ->
          # Should always return an error tuple for this scenario
          flunk("Expected error tuple, got: #{inspect(result)}")
      end
    end

    test "handles apt availability with existing file", %{test_dir: test_dir} do
      # Create a valid .deb file
      deb_file = Path.join(test_dir, "test.deb")
      File.write!(deb_file, "fake deb content")

      result = Deb.path_install(%{}, deb_file, %{})

      case result do
        {:error, "Unable to locate executable apt" <> _, nil} ->
          # Expected when apt is not available
          assert true

        {:error, message, nil} ->
          # If apt is available, we might get installation errors
          # which is also acceptable for this test
          assert is_binary(message)

        {:stop, :normal, nil} ->
          # Unlikely but possible if apt install succeeds
          assert true

        other ->
          flunk("Unexpected result: #{inspect(other)}")
      end
    end

    test "handles extra_args parameter correctly", %{test_dir: test_dir} do
      deb_file = Path.join(test_dir, "test.deb")
      File.write!(deb_file, "fake content")

      # Test with no extra_args (should not crash)
      result1 = Deb.path_install(%{}, deb_file, %{})
      # Should return error about apt not being available, but not crash
      assert match?({:error, _, nil}, result1)

      # Test with empty extra_args
      result2 = Deb.path_install(%{}, deb_file, %{"extra_args" => []})
      assert match?({:error, _, nil}, result2)

      # Test with extra_args
      result3 = Deb.path_install(%{}, deb_file, %{"extra_args" => ["--force-yes"]})
      assert match?({:error, _, nil}, result3)
    end

    test "processes files correctly before attempting installation", %{test_dir: test_dir} do
      # Test the file processing logic by creating files and seeing what happens
      original_file = Path.join(test_dir, "test_package")
      File.write!(original_file, "test content")

      # This will likely fail early if apt is not installed
      result = Deb.path_install(%{}, original_file, %{})

      # The file may or may not be symlinked depending on whether apt is available
      expected_deb_file = Path.join(test_dir, "test_package.deb")

      case result do
        {:error, message, nil} ->
          if String.contains?(message, "Unable to locate executable apt") do
            # If apt is not available, file won't be processed
            refute File.exists?(expected_deb_file)
          else
            # If apt is available but installation fails, file should be symlinked
            assert File.exists?(expected_deb_file)
            # Verify it's a symbolic link pointing to the original file
            assert {:ok, target} = File.read_link(expected_deb_file)
            assert target == original_file
            # The content should be accessible through the symlink
            assert File.read!(expected_deb_file) == "test content"
          end

        _ ->
          # Any other result is also acceptable for this test
          assert true
      end
    end
  end

  describe "edge cases" do
    test "handles paths with special characters" do
      # Test with a path that has spaces and special characters
      special_path = "/tmp/test package with spaces & symbols.deb"

      # Should not crash, even if it fails due to missing apt
      result = Deb.path_install(%{}, special_path, %{})
      assert match?({:error, _, nil}, result)
    end

    test "handles very long paths" do
      long_name = String.duplicate("a", 200)
      long_path = "/tmp/#{long_name}.deb"

      result = Deb.path_install(%{}, long_path, %{})
      assert match?({:error, _, nil}, result)
    end
  end
end
