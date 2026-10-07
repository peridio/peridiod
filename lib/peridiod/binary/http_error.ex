defmodule Peridiod.Binary.HttpError do
  @moduledoc """
  Helpers for the body of a failed (4xx) download response.

  S3 reports why it rejected a request in an XML body. The status code alone is
  ambiguous: a presigned URL signed with an expired STS token is a 400
  `ExpiredToken`, which a fresh URL fixes, while a 400 `InvalidArgument` is a
  malformed request that it does not.
  """

  # Error bodies are small. Cap what we keep so a misbehaving server can't make
  # us buffer an arbitrary amount.
  @max_body_bytes 4096

  @type detail :: %{code: String.t() | nil, message: String.t() | nil}

  @doc "Appends `data` to the buffered error body, keeping at most #{@max_body_bytes} bytes."
  @spec append_body(binary(), binary()) :: binary()
  def append_body(body, data) when is_binary(body) and is_binary(data) do
    remaining = @max_body_bytes - byte_size(body)

    cond do
      remaining <= 0 -> body
      byte_size(data) <= remaining -> body <> data
      true -> body <> binary_part(data, 0, remaining)
    end
  end

  @doc """
  Extracts the S3 error code and message from an error body.

  Returns `nil` when the body isn't an S3 error document.
  """
  @spec parse(binary()) :: detail() | nil
  def parse(body) when is_binary(body) do
    case xml_field(body, "Code") do
      nil -> nil
      code -> %{code: code, message: xml_field(body, "Message")}
    end
  end

  @doc """
  Whether the failure means the signed URL is no longer usable, so asking the
  cloud for a fresh one can succeed.
  """
  @spec expired_url?(detail() | nil) :: boolean()
  def expired_url?(%{code: code}) when code in ["ExpiredToken", "ExpiredRequest"], do: true

  def expired_url?(%{code: "AccessDenied", message: message}) when is_binary(message),
    do: String.contains?(String.downcase(message), "expired")

  def expired_url?(_detail), do: false

  defp xml_field(body, tag) do
    case Regex.run(~r/<#{tag}>([^<]*)<\/#{tag}>/, body) do
      [_, value] -> value
      _ -> nil
    end
  end
end
