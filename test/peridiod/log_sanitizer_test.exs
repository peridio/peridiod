defmodule Peridiod.LogSanitizerTest do
  use ExUnit.Case, async: true

  alias Peridiod.LogSanitizer

  describe "sanitize_uri/1" do
    test "strips query params and fragment from URI struct" do
      uri = URI.parse("https://s3.amazonaws.com/bucket/firmware.fw?X-Amz-Signature=abc123&X-Amz-Credential=key#frag")
      result = LogSanitizer.sanitize_uri(uri)
      assert result == "https://s3.amazonaws.com/bucket/firmware.fw?[FILTERED]"
      refute String.contains?(result, "abc123")
      refute String.contains?(result, "key")
      refute String.contains?(result, "frag")
    end

    test "preserves scheme, host, port, and path" do
      uri = URI.parse("https://example.com:8443/path/to/file?token=secret")
      result = LogSanitizer.sanitize_uri(uri)
      assert result == "https://example.com:8443/path/to/file?[FILTERED]"
    end

    test "leaves URIs without query params unchanged" do
      uri = URI.parse("https://example.com/path/to/file")
      result = LogSanitizer.sanitize_uri(uri)
      assert result == "https://example.com/path/to/file"
    end

    test "strips fragment even when no query params" do
      uri = URI.parse("https://example.com/path#section")
      result = LogSanitizer.sanitize_uri(uri)
      assert result == "https://example.com/path"
    end

    test "accepts binary URLs" do
      result = LogSanitizer.sanitize_uri("https://example.com/fw?token=secret")
      assert result == "https://example.com/fw?[FILTERED]"
      refute String.contains?(result, "secret")
    end

    test "accepts binary URL without query" do
      result = LogSanitizer.sanitize_uri("https://example.com/fw")
      assert result == "https://example.com/fw"
    end

    test "handles nil" do
      assert LogSanitizer.sanitize_uri(nil) == "[nil]"
    end
  end

  describe "sanitize_key/1" do
    test "redacts PEM key string" do
      pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAK...\n-----END RSA PRIVATE KEY-----"
      assert LogSanitizer.sanitize_key(pem) == "[FILTERED KEY]"
    end

    test "redacts any value" do
      assert LogSanitizer.sanitize_key("anything") == "[FILTERED KEY]"
      assert LogSanitizer.sanitize_key(nil) == "[FILTERED KEY]"
      assert LogSanitizer.sanitize_key(12345) == "[FILTERED KEY]"
    end
  end

  describe "sanitize_prn/1" do
    test "redacts org UUID and resource UUID" do
      prn = "prn:1:abc-123-org:device:xyz-456-resource"
      result = LogSanitizer.sanitize_prn(prn)
      assert result == "prn:1:***:device:***"
      refute String.contains?(result, "abc-123-org")
      refute String.contains?(result, "xyz-456-resource")
    end

    test "preserves PRN version and resource type" do
      prn = "prn:2:some-org:bundle:some-bundle-id"
      result = LogSanitizer.sanitize_prn(prn)
      assert result == "prn:2:***:bundle:***"
    end

    test "handles invalid PRN format" do
      assert LogSanitizer.sanitize_prn("not-a-prn") == "[FILTERED PRN]"
      assert LogSanitizer.sanitize_prn("prn:1") == "[FILTERED PRN]"
      assert LogSanitizer.sanitize_prn("prn:1:org:device") == "[FILTERED PRN]"
    end

    test "handles nil" do
      assert LogSanitizer.sanitize_prn(nil) == "[nil]"
    end
  end

  describe "sanitize_ip/1" do
    test "redacts last two octets of IPv4 address" do
      result = LogSanitizer.sanitize_ip("192.168.1.100")
      assert result == "192.168.xxx.xxx"
    end

    test "preserves first two octets" do
      result = LogSanitizer.sanitize_ip("10.20.30.40")
      assert result == "10.20.xxx.xxx"
    end

    test "handles non-IPv4 format" do
      assert LogSanitizer.sanitize_ip("not-an-ip") == "[FILTERED IP]"
      assert LogSanitizer.sanitize_ip("::1") == "[FILTERED IP]"
    end

    test "handles nil" do
      assert LogSanitizer.sanitize_ip(nil) == "[nil]"
    end
  end

  describe "sanitize_update/1" do
    test "sanitizes firmware_url in update map" do
      update = %{"firmware_url" => "https://s3.amazonaws.com/fw?token=secret", "other" => "value"}
      result = LogSanitizer.sanitize_update(update)
      assert result["firmware_url"] == "https://s3.amazonaws.com/fw?[FILTERED]"
      assert result["other"] == "value"
    end

    test "passes through maps without firmware_url" do
      update = %{"status" => "ok", "version" => "1.0"}
      assert LogSanitizer.sanitize_update(update) == update
    end

    test "passes through non-map values" do
      assert LogSanitizer.sanitize_update("string") == "string"
      assert LogSanitizer.sanitize_update(nil) == nil
      assert LogSanitizer.sanitize_update(42) == 42
    end
  end

  describe "sanitize_engine_key/1" do
    test "redacts key_id, preserves all other fields" do
      key = %{engine: :pkcs11, key_id: "slot=0:label=device-key", algorithm: :ecdsa, extra: "context"}
      result = LogSanitizer.sanitize_engine_key(key)
      assert result == %{engine: :pkcs11, key_id: "[FILTERED]", algorithm: :ecdsa, extra: "context"}
      refute inspect(result) =~ "device-key"
    end

    test "passes through non-matching values" do
      assert LogSanitizer.sanitize_engine_key(:unknown) == :unknown
      assert LogSanitizer.sanitize_engine_key(%{other: "key"}) == %{other: "key"}
    end
  end
end
