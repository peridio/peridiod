defmodule PeridiodTest.StaticRouter do
  use Plug.Router

  plug(Plug.Static,
    at: "/",
    from: "test/fixtures/binaries"
  )

  plug(:match)
  plug(:dispatch)

  match _ do
    send_resp(conn, 404, "Not Found")
  end
end
