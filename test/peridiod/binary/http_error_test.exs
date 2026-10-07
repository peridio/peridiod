defmodule Peridiod.Binary.HttpErrorTest do
  use ExUnit.Case, async: true

  alias Peridiod.Binary.HttpError

  defp s3_error(code, message) do
    ~s(<?xml version="1.0" encoding="UTF-8"?>\n) <>
      "<Error><Code>#{code}</Code><Message>#{message}</Message><RequestId>ABC</RequestId></Error>"
  end

  describe "parse/1" do
    test "extracts the code and message from an S3 error document" do
      body = s3_error("ExpiredToken", "The provided token has expired.")

      assert %{code: "ExpiredToken", message: "The provided token has expired."} =
               HttpError.parse(body)
    end

    test "returns nil for a body that isn't an S3 error" do
      assert HttpError.parse("Bad Request") == nil
      assert HttpError.parse("") == nil
    end

    test "tolerates a missing message" do
      assert %{code: "ExpiredToken", message: nil} =
               HttpError.parse("<Error><Code>ExpiredToken</Code></Error>")
    end
  end

  describe "parse/1 keeps response text out of the logs" do
    test "a code that isn't a plain word isn't an S3 error document" do
      assert HttpError.parse("<Error><Code>Bad\nCode</Code></Error>") == nil
      assert HttpError.parse("<Error><Code>Expired Token</Code></Error>") == nil

      assert HttpError.parse("<Error><Code>" <> String.duplicate("a", 65) <> "</Code></Error>") ==
               nil

      assert HttpError.parse("<Error><Code></Code></Error>") == nil
    end

    test "the message loses control characters and is capped" do
      body =
        "<Error><Code>AccessDenied</Code><Message>line one\nforged 2026 [error]\r\e[31m</Message></Error>"

      assert %{code: "AccessDenied", message: "line oneforged 2026 [error][31m"} =
               HttpError.parse(body)

      long =
        "<Error><Code>AccessDenied</Code><Message>" <>
          String.duplicate("m", 500) <> "</Message></Error>"

      assert %{message: message} = HttpError.parse(long)
      assert String.length(message) == 200
    end

    test "a message that isn't valid text doesn't crash the parser" do
      body = <<"<Error><Code>AccessDenied</Code><Message>caf", 255, 254, "</Message></Error>">>
      assert %{code: "AccessDenied", message: "caf"} = HttpError.parse(body)
    end
  end

  describe "expired_url?/1" do
    test "expired STS token" do
      assert HttpError.expired_url?(HttpError.parse(s3_error("ExpiredToken", "expired")))
    end

    test "expired request" do
      assert HttpError.expired_url?(HttpError.parse(s3_error("ExpiredRequest", "expired")))
    end

    test "access denied because the request expired" do
      detail = HttpError.parse(s3_error("AccessDenied", "Request has expired"))
      assert HttpError.expired_url?(detail)
    end

    test "errors a fresh URL can't fix" do
      refute HttpError.expired_url?(HttpError.parse(s3_error("AccessDenied", "Access Denied")))
      refute HttpError.expired_url?(HttpError.parse(s3_error("InvalidArgument", "bad")))
      refute HttpError.expired_url?(HttpError.parse(s3_error("SignatureDoesNotMatch", "bad")))
      refute HttpError.expired_url?(HttpError.parse(s3_error("NoSuchKey", "gone")))
    end

    test "no detail" do
      refute HttpError.expired_url?(nil)
    end
  end

  describe "append_body/2" do
    test "accumulates data" do
      assert HttpError.append_body("ab", "cd") == "abcd"
    end

    test "never keeps more than the cap" do
      body = HttpError.append_body("", String.duplicate("a", 10_000))
      assert byte_size(body) == 4096
      assert HttpError.append_body(body, "more") == body
    end
  end
end
