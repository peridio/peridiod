defmodule Peridiod.CertificateTest do
  use ExUnit.Case

  alias Peridiod.Certificate
  alias Peridiod.Certificate.ParseError

  @cert_pem File.read!(Path.expand("../fixtures/device/device-certificate.pem", __DIR__))
  @key_pem File.read!(Path.expand("../fixtures/device/device-private-key.pem", __DIR__))
  @cert_path Path.expand("../fixtures/device/device-certificate.pem", __DIR__)
  @key_path Path.expand("../fixtures/device/device-private-key.pem", __DIR__)
  @corrupt_cert_pem File.read!(Path.expand("../fixtures/device/corrupt-certificate.pem", __DIR__))
  @corrupt_key_pem File.read!(Path.expand("../fixtures/device/corrupt-private-key.pem", __DIR__))
  @corrupt_cert_path Path.expand("../fixtures/device/corrupt-certificate.pem", __DIR__)
  @corrupt_key_path Path.expand("../fixtures/device/corrupt-private-key.pem", __DIR__)

  describe "certificate_from_pem!/2" do
    test "returns an X509 certificate struct for valid PEM" do
      cert = Certificate.certificate_from_pem!(@cert_pem)
      assert is_tuple(cert)
    end

    test "raises ParseError for malformed PEM body" do
      assert_raise ParseError, fn ->
        Certificate.certificate_from_pem!(@corrupt_cert_pem, source: "env", path: "MY_CERT")
      end
    end

    test "raises ParseError for empty string" do
      assert_raise ParseError, fn ->
        Certificate.certificate_from_pem!("", source: "file", path: "/dev/null")
      end
    end

    test "ParseError has correct field, source, path, and reason" do
      error =
        assert_raise ParseError, fn ->
          Certificate.certificate_from_pem!(@corrupt_cert_pem, source: "env", path: "MY_CERT")
        end

      assert error.field == :certificate
      assert error.source == "env"
      assert error.path == "MY_CERT"
      assert error.reason != nil
    end

    test "ParseError message includes field, source, path, and reason" do
      error =
        assert_raise ParseError, fn ->
          Certificate.certificate_from_pem!(@corrupt_cert_pem, source: "file", path: "/bad.pem")
        end

      msg = Exception.message(error)
      assert msg =~ "certificate"
      assert msg =~ "file"
      assert msg =~ "/bad.pem"
    end
  end

  describe "private_key_from_pem!/2" do
    test "returns a private key for valid PEM" do
      key = Certificate.private_key_from_pem!(@key_pem)
      assert is_tuple(key)
    end

    test "raises ParseError for malformed PEM body" do
      assert_raise ParseError, fn ->
        Certificate.private_key_from_pem!(@corrupt_key_pem, source: "env", path: "MY_KEY")
      end
    end

    test "raises ParseError for empty string" do
      assert_raise ParseError, fn ->
        Certificate.private_key_from_pem!("", source: "uboot-env", path: "peridio_private_key")
      end
    end

    test "ParseError has correct field, source, path, and reason" do
      error =
        assert_raise ParseError, fn ->
          Certificate.private_key_from_pem!(@corrupt_key_pem, source: "env", path: "MY_KEY")
        end

      assert error.field == :private_key
      assert error.source == "env"
      assert error.path == "MY_KEY"
    end

    test "ParseError message includes field, source, path, and reason" do
      error =
        assert_raise ParseError, fn ->
          Certificate.private_key_from_pem!(@corrupt_key_pem, source: "file", path: "/bad.pem")
        end

      msg = Exception.message(error)
      assert msg =~ "private_key"
      assert msg =~ "file"
      assert msg =~ "/bad.pem"
    end
  end

  describe "certificate_from_pem_file!/2" do
    test "returns an X509 certificate struct for valid file" do
      cert = Certificate.certificate_from_pem_file!(@cert_path, source: "file")
      assert is_tuple(cert)
    end

    test "raises ParseError for malformed PEM file" do
      assert_raise ParseError, fn ->
        Certificate.certificate_from_pem_file!(@corrupt_cert_path, source: "file")
      end
    end

    test "raises ParseError with :file_read_error for nonexistent file" do
      error =
        assert_raise ParseError, fn ->
          Certificate.certificate_from_pem_file!("/nonexistent/path.pem", source: "file")
        end

      assert {:file_read_error, :enoent} = error.reason
    end
  end

  describe "private_key_from_pem_file!/2" do
    test "returns a private key for valid file" do
      key = Certificate.private_key_from_pem_file!(@key_path, source: "file")
      assert is_tuple(key)
    end

    test "raises ParseError for malformed PEM file" do
      assert_raise ParseError, fn ->
        Certificate.private_key_from_pem_file!(@corrupt_key_path, source: "file")
      end
    end

    test "raises ParseError with :file_read_error for nonexistent file" do
      error =
        assert_raise ParseError, fn ->
          Certificate.private_key_from_pem_file!("/nonexistent/path.pem", source: "file")
        end

      assert {:file_read_error, :enoent} = error.reason
    end
  end

  describe "certificate_from_pem/2 (non-bang)" do
    test "returns {:ok, cert} for valid PEM" do
      assert {:ok, _cert} = Certificate.certificate_from_pem(@cert_pem)
    end

    test "returns {:error, {:parse_error, _}} for malformed PEM" do
      assert {:error, {:parse_error, _}} = Certificate.certificate_from_pem(@corrupt_cert_pem)
    end

    test "returns {:error, {:parse_error, _}} for empty string" do
      assert {:error, {:parse_error, _}} = Certificate.certificate_from_pem("")
    end
  end

  describe "private_key_from_pem/2 (non-bang)" do
    test "returns {:ok, key} for valid PEM" do
      assert {:ok, _key} = Certificate.private_key_from_pem(@key_pem)
    end

    test "returns {:error, {:parse_error, _}} for malformed PEM" do
      assert {:error, {:parse_error, _}} = Certificate.private_key_from_pem(@corrupt_key_pem)
    end

    test "returns {:error, {:parse_error, _}} for empty string" do
      assert {:error, {:parse_error, _}} = Certificate.private_key_from_pem("")
    end
  end

  describe "ParseError.message/1" do
    test "identity_not_configured message mentions source and check instruction" do
      msg =
        ParseError.exception(
          field: :certificate,
          source: "env",
          path: nil,
          reason: :identity_not_configured
        )
        |> Exception.message()

      assert msg =~ "env"
      assert msg =~ "identity_not_configured"
      assert msg =~ "peridio-config.json"
    end

    test "parse failure message includes path clause for env source" do
      msg =
        ParseError.exception(
          field: :certificate,
          source: "env",
          path: "MY_CERT_VAR",
          reason: :not_found
        )
        |> Exception.message()

      assert msg =~ "env var: MY_CERT_VAR"
    end

    test "parse failure message includes path clause for file source" do
      msg =
        ParseError.exception(
          field: :private_key,
          source: "file",
          path: "/path/to/key.pem",
          reason: :not_found
        )
        |> Exception.message()

      assert msg =~ "file: /path/to/key.pem"
    end

    test "parse failure message includes path clause for uboot-env source" do
      msg =
        ParseError.exception(
          field: :certificate,
          source: "uboot-env",
          path: "peridio_certificate",
          reason: :not_found
        )
        |> Exception.message()

      assert msg =~ "KV key: peridio_certificate"
    end
  end
end
