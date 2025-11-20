defmodule Peridiod.TestFixtures do
  alias Peridiod.SigningKey

  @trusted_key_pem """
  -----BEGIN PUBLIC KEY-----
  MCowBQYDK2VwAyEAR/D9tfoPRSJi+pd+S6MQqjPfjfyXm9OO65n+RyJ1gbk=
  -----END PUBLIC KEY-----
  """
  @trusted_key_der <<71, 240, 253, 181, 250, 15, 69, 34, 98, 250, 151, 126, 75, 163, 16, 170, 51,
                     223, 141, 252, 151, 155, 211, 142, 235, 153, 254, 71, 34, 117, 129, 185>>
  @trusted_key_raw "R/D9tfoPRSJi+pd+S6MQqjPfjfyXm9OO65n+RyJ1gbk="

  @untrusted_key_pem """
  -----BEGIN PUBLIC KEY-----
  MCowBQYDK2VwAyEATutyLjdRGvOWkjwJX3W3dpYkZNCsOCiFtAWocRtBIM0=
  -----END PUBLIC KEY-----
  """

  @trusted_release_binary_file %{
    "artifact" => %{
      "name" => "1M",
      "prn" =>
        "prn:1:92d0a3ed-9058-4632-ae29-f420078c4507:artifact:3367d524-6cfd-4456-8437-a4de4e44cd83"
    },
    "artifact_version" => %{
      "prn" =>
        "prn:1:92d0a3ed-9058-4632-ae29-f420078c4507:artifact_version:12fd0d27-6849-4b54-9e3b-2b57c3d6855f",
      "version" => "v1.0.0"
    },
    "binary_prn" =>
      "prn:1:92d0a3ed-9058-4632-ae29-f420078c4507:binary:efb1bf04-affd-4256-b959-d8d8fa2f9d78",
    "custom_metadata" => %{
      "peridiod" => %{
        "installer" => "file",
        "installer_opts" => %{
          "name" => "1M.bin",
          "path" => "test/workspace"
        },
        "reboot_required" => false
      }
    },
    "hash" => "a073ad730e540107fbb92ee48baab97c9bc16105333a42b15a53bcc183f6f5c2",
    "signatures" => [
      %{
        "public_value" =>
          "-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAR/D9tfoPRSJi+pd+S6MQqjPfjfyXm9OO65n+RyJ1gbk=\n-----END PUBLIC KEY-----",
        "signature" =>
          "BF59EA4EC4705DA63F56F7A59D72FDB755DF8391EC49399BE6B3F773AF92E925B0C0859D7589933B3A1C896AF3114718E035C1B8A17E6F6AB37106011B58E703",
        "signing_key_prn" =>
          "prn:1:92d0a3ed-9058-4632-ae29-f420078c4507:signing_key:1b02f19b-7330-4be8-8895-8a5d66ebe7f2"
      }
    ],
    "size" => 1_048_576,
    "target" => "portable",
    "url" => "http://localhost:4001/1M.bin"
  }

  @custom_metadata_fwup %{
    "peridiod" => %{
      "installer" => "fwup",
      "installer_opts" => %{
        "devpath" => "test/workspace",
        "extra_args" => ["--unsafe"],
        "env" => %{}
      },
      "reboot_required" => true
    }
  }

  @custom_metadata_swupdate %{
    "peridiod" => %{
      "installer" => "swupdate",
      "installer_opts" => %{},
      "reboot_required" => true
    }
  }

  @custom_metadata_cache %{
    "peridiod" => %{
      "installer" => "cache",
      "installer_opts" => %{},
      "reboot_required" => false
    }
  }

  @custom_metadata_avocado_os %{
    "peridiod" => %{
      "installer" => "swupdate",
      "installer_opts" => %{},
      "avocado" => %{
        "type" => "os"
      },
      "reboot_required" => true
    }
  }

  @custom_metadata_avocado_extension %{
    "peridiod" => %{
      "installer" => "file",
      "installer_opts" => %{
        "name" => "test-app.raw",
        "path" => "/var/lib/avocado/extensions/"
      },
      "avocado" => %{
        "type" => "extension",
        "extension_name" => "test-app"
      },
      "reboot_required" => false
    }
  }

  @trusted_release_binary %{
    "artifact" => %{
      "name" => "fwup.fw",
      "prn" =>
        "prn:1:92d0a3ed-9058-4632-ae29-f420078c4507:artifact:0df9b0af-bbc5-4ac0-a164-8cc1895a25f0"
    },
    "artifact_version" => %{
      "prn" =>
        "prn:1:92d0a3ed-9058-4632-ae29-f420078c4507:artifact_version:f87bd304-f9bc-45b9-92de-fd833df66302",
      "version" => "v1.0.0"
    },
    "binary_prn" =>
      "prn:1:92d0a3ed-9058-4632-ae29-f420078c4507:binary:3018924c-f367-4870-9c17-e25ec68c9494",
    "custom_metadata" => @custom_metadata_fwup,
    "hash" => "8bb7566846ae03b99e55b72d022d0f899404af8a22a335b4be8789cb997f0ea2",
    "signatures" => [
      %{
        "public_value" =>
          "-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAR/D9tfoPRSJi+pd+S6MQqjPfjfyXm9OO65n+RyJ1gbk=\n-----END PUBLIC KEY-----",
        "signature" =>
          "497520EF9CC34B5D94072C1D19B9DE6EC754A13A995673A0B11892D87415A7BB8B659D7CD57D23E503D4D611999A9EA654CE03302F81B9A411B78C3D78416E05",
        "signing_key_prn" =>
          "prn:1:92d0a3ed-9058-4632-ae29-f420078c4507:signing_key:da38c352-320e-4167-a10d-70bbc5d5fc16"
      }
    ],
    "size" => 270,
    "target" => "portable",
    "url" => "http://localhost:4001/fwup.fw"
  }

  @untrusted_release_binary %{
    "artifact" => %{
      "name" => "1M",
      "prn" =>
        "prn:1:92d0a3ed-9058-4632-ae29-f420078c4507:artifact:3367d524-6cfd-4456-8437-a4de4e44cd83"
    },
    "artifact_version" => %{
      "prn" =>
        "prn:1:92d0a3ed-9058-4632-ae29-f420078c4507:artifact_version:12fd0d27-6849-4b54-9e3b-2b57c3d6855f",
      "version" => "v1.0.0"
    },
    "binary_prn" =>
      "prn:1:92d0a3ed-9058-4632-ae29-f420078c4507:binary:efb1bf04-affd-4256-b959-d8d8fa2f9d78",
    "custom_metadata" => %{
      "peridiod" => %{
        "installer" => "file",
        "installer_opts" => %{
          "name" => "1M.bin",
          "path" => "test/workspace"
        },
        "reboot_required" => false
      }
    },
    "hash" => "a073ad730e540107fbb92ee48baab97c9bc16105333a42b15a53bcc183f6f5c2",
    "signatures" => [
      %{
        "public_value" =>
          "-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEATutyLjdRGvOWkjwJX3W3dpYkZNCsOCiFtAWocRtBIM0=\n-----END PUBLIC KEY-----",
        "signature" =>
          "9458E638946B359D35D7F01FD5F93C354F97F7148A6368961CA6212AE35F2804280503618FB0F4E3CF00CDB10597C193D7DF7BC875909C21FFB8D35E23CA6F09",
        "signing_key_prn" =>
          "prn:1:92d0a3ed-9058-4632-ae29-f420078c4507:signing_key:1b02f19b-7330-4be8-8895-8a5d66ebe7f2"
      }
    ],
    "size" => 1_048_576,
    "target" => "portable",
    "url" => "http://localhost:4001/1M.bin"
  }

  @release_manifest %{
    "bundle" => %{
      "prn" =>
        "prn:1:92d0a3ed-9058-4632-ae29-f420078c4507:bundle:d17c282e-9404-4613-b7b6-81d269d9fbd9"
    },
    "manifest" => [],
    "release" => %{
      "prn" =>
        "prn:1:92d0a3ed-9058-4632-ae29-f420078c4507:release:b4dcc0a1-b891-4375-895d-dc44d7ae0162",
      "version" => "2.0.0",
      "version_requirement" => "~> 1.0"
    },
    "status" => "update"
  }

  def trusted_key_pem, do: @trusted_key_pem
  def trusted_key_der, do: @trusted_key_der
  def trusted_key_base64, do: @trusted_key_raw
  def trusted_signing_key, do: SigningKey.new(:ed25519, trusted_key_pem()) |> elem(1)
  def untrusted_key_pem, do: @untrusted_key_pem
  def untrusted_signing_key, do: SigningKey.new(:ed25519, untrusted_key_pem()) |> elem(1)
  def untrusted_release_binary, do: @untrusted_release_binary
  def binary_fixture_path(), do: Path.expand("../fixtures/binaries", __DIR__)

  def binary_manifest_fwup(),
    do: @trusted_release_binary |> Map.put("custom_metadata", @custom_metadata_fwup)

  def binary_manifest_swupdate(),
    do: @trusted_release_binary |> Map.put("custom_metadata", @custom_metadata_swupdate)

  def binary_manifest_cache(),
    do: @trusted_release_binary |> Map.put("custom_metadata", @custom_metadata_cache)

  def custom_metadata_cache(), do: @custom_metadata_cache

  def release_manifest(install_dir) do
    manifest =
      update_in(
        @trusted_release_binary_file,
        ["custom_metadata", "peridiod", "installer_opts", "path"],
        fn _ -> install_dir end
      )

    %{@release_manifest | "manifest" => [manifest]}
  end

  def binary_manifest_avocado_os(version \\ "v1.0.0") do
    @trusted_release_binary
    |> Map.put("custom_metadata", @custom_metadata_avocado_os)
    |> put_in(["artifact_version", "version"], version)
  end

  def binary_manifest_avocado_extension(extension_name) do
    @trusted_release_binary_file
    |> Map.put("custom_metadata", @custom_metadata_avocado_extension)
    |> put_in(["custom_metadata", "peridiod", "avocado", "extension_name"], extension_name)
    |> put_in(["custom_metadata", "peridiod", "installer_opts", "name"], "#{extension_name}.raw")
  end

  def custom_metadata_avocado_os(), do: @custom_metadata_avocado_os
  def custom_metadata_avocado_extension(), do: @custom_metadata_avocado_extension
end
