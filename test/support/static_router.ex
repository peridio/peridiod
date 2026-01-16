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

  match _ do
    send_resp(conn, 404, "Not Found")
  end
end
