defmodule Peridiod.LogSanitizer do
  @moduledoc """
  Sanitizes sensitive data before it is written to log output.

  Use these functions at Logger call sites to strip auth tokens, key material,
  and other confidential values while preserving enough context for debugging.
  """

  @doc """
  Strips query params and fragment from a URI, replacing the query with `[FILTERED]`.

  Firmware download URIs often contain pre-signed S3 tokens in query parameters.
  The scheme/host/path are preserved for debugging.
  """
  def sanitize_uri(%URI{query: nil, fragment: nil} = uri), do: URI.to_string(uri)

  def sanitize_uri(%URI{} = uri) do
    %URI{uri | query: (if uri.query, do: "[FILTERED]"), fragment: nil}
    |> URI.to_string()
  end

  def sanitize_uri(uri) when is_binary(uri) do
    uri |> URI.parse() |> sanitize_uri()
  end

  def sanitize_uri(nil), do: "[nil]"

  @doc """
  Redacts key material entirely. No partial display — there is no debugging
  value in showing part of a PEM key or other secret.
  """
  def sanitize_key(_key), do: "[FILTERED KEY]"

  @doc """
  Redacts the org UUID and resource UUID from a PRN while preserving its
  structural type segments for debugging.

  Example: `"prn:1:abc-123:device:xyz-456"` → `"prn:1:***:device:***"`
  """
  def sanitize_prn(prn) when is_binary(prn) do
    case String.split(prn, ":") do
      ["prn", version, _org_id, resource_type, _resource_id | _] ->
        "prn:#{version}:***:#{resource_type}:***"

      _ ->
        "[FILTERED PRN]"
    end
  end

  def sanitize_prn(nil), do: "[nil]"

  @doc """
  Partially redacts an IPv4 address, keeping the first two octets for
  network-level debugging while masking the host portion.

  Example: `"192.168.1.100"` → `"192.168.xxx.xxx"`
  """
  def sanitize_ip(address) when is_binary(address) do
    case String.split(address, ".") do
      [a, b, _, _] -> "#{a}.#{b}.xxx.xxx"
      _ -> "[FILTERED IP]"
    end
  end

  def sanitize_ip(nil), do: "[nil]"

  @doc """
  Sanitizes the `"firmware_url"` field in an update payload map.
  Other keys are passed through unchanged.
  """
  def sanitize_update(%{"firmware_url" => url} = update) do
    Map.put(update, "firmware_url", sanitize_uri(url))
  end

  def sanitize_update(update), do: update

  @doc """
  Redacts the `:key_id` from an engine key map while preserving the rest of
  the map for debugging PKCS#11 configuration issues.
  """
  def sanitize_engine_key(%{key_id: _} = key) do
    Map.put(key, :key_id, "[FILTERED]")
  end

  def sanitize_engine_key(key), do: key
end
