defmodule PeridiodTest.FakeS3 do
  @moduledoc """
  Stands in for S3 presigned URLs in simulations.

  A token is a signed URL. It is valid until it expires, and answers like S3 does
  once it has: HTTP 400 with an `ExpiredToken` error document. A token can have a
  byte budget: its first response then sends that many bytes and drops the
  connection, which is what a flapping link does, and the token expires, so the
  download that resumes finds a dead URL.

  Every request is reported to the process given to `notify/1` as
  `{:s3_request, token, range_header}`.
  """
  use Agent

  import Plug.Conn

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{tokens: %{}, test_pid: nil} end, name: __MODULE__)
  end

  def notify(pid), do: Agent.update(__MODULE__, &%{&1 | test_pid: pid})

  @doc """
  Registers a token. Options:

    * `:expired` - already expired (default `false`)
    * `:budget` - bytes sent by the first response before it ends early (default:
      send everything)
    * `:then` - what ends it early: `:drop` closes the connection and expires the
      token (default), `:stall` leaves the connection open and sends nothing more
  """
  def put_token(token, opts \\ []) do
    entry = %{
      expired?: Keyword.get(opts, :expired, false),
      budget: opts[:budget],
      then: Keyword.get(opts, :then, :drop)
    }

    Agent.update(__MODULE__, &put_in(&1, [:tokens, token], entry))
  end

  def serve(conn, token, file) do
    range = get_req_header(conn, "range")
    Agent.get(__MODULE__, & &1.test_pid) |> notify_request(token, range)

    case Agent.get(__MODULE__, & &1.tokens[token]) do
      nil ->
        send_resp(conn, 403, error("InvalidAccessKeyId", "The access key does not exist."))

      %{expired?: true} ->
        send_resp(conn, 400, error("ExpiredToken", "The provided token has expired."))

      %{budget: budget, then: ending} ->
        send_file_contents(conn, token, file, range, budget, ending)
    end
  end

  defp send_file_contents(conn, token, file, range, budget, ending) do
    data = File.read!(Path.join("test/fixtures/binaries", file))
    size = byte_size(data)

    {status, start} =
      case range do
        ["bytes=" <> spec] -> {206, spec |> String.split("-") |> hd() |> String.to_integer()}
        _ -> {200, 0}
      end

    body = binary_part(data, start, size - start)

    conn =
      conn
      |> put_resp_header("accept-ranges", "bytes")
      |> put_resp_header("content-range", "bytes #{start}-#{size - 1}/#{size}")

    if is_integer(budget) and budget < byte_size(body) do
      conn =
        conn
        |> put_resp_header("content-length", Integer.to_string(byte_size(body)))
        |> send_chunked(status)

      {:ok, conn} = chunk(conn, binary_part(body, 0, budget))
      end_early(ending, conn, token)
      conn
    else
      send_resp(conn, status, body)
    end
  end

  defp end_early(:stall, _conn, _token), do: Process.sleep(:infinity)

  defp end_early(:drop, conn, token) do
    expire(token)
    drop_connection(conn)
  end

  # Closes the socket with the body unfinished, like a link that went away. Killing
  # only the request process would leave the connection open.
  defp drop_connection(%Plug.Conn{adapter: {_adapter, %{pid: connection_pid}}}) do
    # let what was just sent reach the socket first
    Process.sleep(100)
    Process.exit(connection_pid, :kill)
    Process.sleep(:infinity)
  end

  defp expire(token), do: Agent.update(__MODULE__, &put_in(&1, [:tokens, token, :expired?], true))

  defp notify_request(nil, _token, _range), do: :ok

  defp notify_request(pid, token, range),
    do: send(pid, {:s3_request, token, List.first(range)})

  defp error(code, message) do
    ~s(<?xml version="1.0" encoding="UTF-8"?>\n) <>
      "<Error><Code>#{code}</Code><Message>#{message}</Message></Error>"
  end
end
