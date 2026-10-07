defmodule PeridiodTest.StaticRouter do
  use Plug.Router

  plug(Plug.Static,
    at: "/",
    from: "test/fixtures/binaries"
  )

  plug(:match)
  plug(:dispatch)

  # Error routes for testing HTTP error handling
  get "/error/400" do
    send_resp(conn, 400, "Bad Request - Expired Token")
  end

  get "/error/403" do
    send_resp(conn, 403, "Forbidden")
  end

  get "/error/404" do
    send_resp(conn, 404, "Not Found")
  end

  # A presigned URL that can expire, see PeridiodTest.FakeS3
  get "/sim/:token/:file" do
    PeridiodTest.FakeS3.serve(conn, token, file)
  end

  # Sends a 4xx and then never finishes the body
  get "/s3/stall-4xx" do
    conn = conn |> put_resp_header("content-length", "100") |> send_chunked(400)
    Process.sleep(:infinity)
    conn
  end

  # S3 style error documents
  get "/s3/expired-token" do
    send_resp(
      conn,
      400,
      s3_error("ExpiredToken", "The provided token has expired.")
    )
  end

  get "/s3/request-expired" do
    send_resp(conn, 403, s3_error("AccessDenied", "Request has expired"))
  end

  get "/s3/invalid-argument" do
    send_resp(conn, 400, s3_error("InvalidArgument", "Invalid argument."))
  end

  defp s3_error(code, message) do
    ~s(<?xml version="1.0" encoding="UTF-8"?>\n) <>
      "<Error><Code>#{code}</Code><Message>#{message}</Message></Error>"
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end
end
