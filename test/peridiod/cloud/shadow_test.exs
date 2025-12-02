defmodule Peridiod.Cloud.ShadowTest do
  use PeridiodTest.Case

  alias Peridiod.Cloud.Shadow

  describe "validate_executable" do
    test "rejects nil executable" do
      config = %{shadow_executable: nil, shadow_args: []}

      assert {:error, "Shadow executable not configured"} = Shadow.update(config)
    end

    test "rejects non-string executable" do
      config = %{shadow_executable: 123, shadow_args: []}

      assert {:error, "Shadow executable must be a string"} = Shadow.update(config)
    end

    test "rejects executable without absolute path" do
      config = %{shadow_executable: "relative/path/script.sh", shadow_args: []}

      assert {:error, "Shadow executable must be an absolute path"} = Shadow.update(config)
    end

    test "rejects executable with semicolon" do
      config = %{shadow_executable: "/bin/echo; rm -rf /", shadow_args: []}

      assert {:error, "Shadow executable contains invalid characters"} = Shadow.update(config)
    end

    test "rejects executable with pipe" do
      config = %{shadow_executable: "/bin/cat | grep foo", shadow_args: []}

      assert {:error, "Shadow executable contains invalid characters"} = Shadow.update(config)
    end

    test "rejects executable with ampersand" do
      config = %{shadow_executable: "/bin/echo & /bin/rm", shadow_args: []}

      assert {:error, "Shadow executable contains invalid characters"} = Shadow.update(config)
    end

    test "rejects executable with backtick" do
      config = %{shadow_executable: "/bin/echo `whoami`", shadow_args: []}

      assert {:error, "Shadow executable contains invalid characters"} = Shadow.update(config)
    end

    test "rejects executable with dollar sign" do
      config = %{shadow_executable: "/bin/echo $HOME", shadow_args: []}

      assert {:error, "Shadow executable contains invalid characters"} = Shadow.update(config)
    end

    test "rejects executable with parentheses" do
      config = %{shadow_executable: "/bin/bash -c (echo hi)", shadow_args: []}

      assert {:error, "Shadow executable contains invalid characters"} = Shadow.update(config)
    end

    test "rejects executable with curly braces" do
      config = %{shadow_executable: "/bin/bash -c {echo,hi}", shadow_args: []}

      assert {:error, "Shadow executable contains invalid characters"} = Shadow.update(config)
    end

    test "rejects executable with redirect characters" do
      config = %{shadow_executable: "/bin/echo > /tmp/file", shadow_args: []}

      assert {:error, "Shadow executable contains invalid characters"} = Shadow.update(config)
    end

    test "rejects executable with newline" do
      config = %{shadow_executable: "/bin/echo\n/bin/rm", shadow_args: []}

      assert {:error, "Shadow executable contains invalid characters"} = Shadow.update(config)
    end

    test "rejects executable with carriage return" do
      config = %{shadow_executable: "/bin/echo\r/bin/rm", shadow_args: []}

      assert {:error, "Shadow executable contains invalid characters"} = Shadow.update(config)
    end
  end

  describe "validate_args" do
    test "rejects non-list args" do
      config = %{shadow_executable: "/bin/echo", shadow_args: "not a list"}

      assert {:error, "Shadow args must be a list"} = Shadow.update(config)
    end

    test "rejects args with non-string elements" do
      config = %{shadow_executable: "/bin/echo", shadow_args: ["valid", 123, "also valid"]}

      assert {:error, "Shadow args contain invalid values"} = Shadow.update(config)
    end

    test "rejects args with atom elements" do
      config = %{shadow_executable: "/bin/echo", shadow_args: [:atom_arg]}

      assert {:error, "Shadow args contain invalid values"} = Shadow.update(config)
    end

    test "rejects args with map elements" do
      config = %{shadow_executable: "/bin/echo", shadow_args: [%{key: "value"}]}

      assert {:error, "Shadow args contain invalid values"} = Shadow.update(config)
    end

    test "accepts empty args list" do
      config = %{shadow_executable: "/usr/bin/false", shadow_args: []}

      # /usr/bin/false exits with code 1, so validation passes but script "fails"
      assert {:error, :script_failed} = Shadow.update(config)
    end

    test "accepts args with all string elements" do
      config = %{
        shadow_executable: "/usr/bin/false",
        shadow_args: ["arg1", "arg2", "--flag"]
      }

      # /usr/bin/false exits with code 1, so validation passes but script "fails"
      assert {:error, :script_failed} = Shadow.update(config)
    end
  end
end
