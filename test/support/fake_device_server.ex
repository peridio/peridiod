defmodule PeridiodTest.FakeDeviceServer do
  @moduledoc """
  A stand-in for the Peridio device channel, for simulations.

  Serves `wss://localhost:PORT/socket/websocket` over TLS with a throwaway
  certificate and speaks the Phoenix channel protocol (V2 JSON arrays), enough for
  peridiod's real `Cloud.Socket` to connect, join the `device` topic, leave it and
  join it again.

  What a join answers is decided by the function given to `set_join_handler/1`. It
  gets the join params and returns the reply payload. Joins and leaves are reported
  to the process given to `start/1` as `{:fake_device, :join, topic, params}` and
  `{:fake_device, :leave, topic}`.
  """
  use Agent

  @ref :peridiod_fake_device_server

  defmodule Socket do
    @moduledoc false
    @behaviour :cowboy_websocket

    @impl true
    def init(req, state), do: {:cowboy_websocket, req, state, %{idle_timeout: 60_000}}

    @impl true
    def websocket_init(_state) do
      PeridiodTest.FakeDeviceServer.register_connection()
      {:ok, %{join_refs: %{}}}
    end

    @impl true
    def websocket_handle({:text, text}, state) do
      [join_ref, ref, topic, event, payload] = Jason.decode!(text)
      handle(event, join_ref, ref, topic, payload, state)
    end

    def websocket_handle(_frame, state), do: {:ok, state}

    # the cloud ends a joined channel
    @impl true
    def websocket_info({:end_topic, topic, event}, state) do
      # Phoenix sets the ref of these to the join ref
      join_ref = state.join_refs[topic]
      frame = Jason.encode!([join_ref, join_ref, topic, event, %{}])
      {:reply, {:text, frame}, state}
    end

    def websocket_info(_message, state), do: {:ok, state}

    defp handle("phx_join", join_ref, ref, topic, params, state) do
      PeridiodTest.FakeDeviceServer.report({:fake_device, :join, topic, params})
      response = PeridiodTest.FakeDeviceServer.join_reply(topic, params)
      state = put_in(state, [:join_refs, topic], join_ref)
      {:reply, {:text, reply(join_ref, ref, topic, response)}, state}
    end

    defp handle("phx_leave", join_ref, ref, topic, _payload, state) do
      PeridiodTest.FakeDeviceServer.report({:fake_device, :leave, topic})

      frames = [
        {:text, reply(join_ref, ref, topic, %{})},
        {:text, Jason.encode!([join_ref, join_ref, topic, "phx_close", %{}])}
      ]

      {:reply, frames, state}
    end

    defp handle("heartbeat", join_ref, ref, topic, _payload, state) do
      {:reply, {:text, reply(join_ref, ref, topic, %{})}, state}
    end

    defp handle(_event, _join_ref, _ref, _topic, _payload, state), do: {:ok, state}

    defp reply(join_ref, ref, topic, response) do
      Jason.encode!([
        join_ref,
        ref,
        topic,
        "phx_reply",
        %{"status" => "ok", "response" => response}
      ])
    end
  end

  def start_link(_opts \\ []) do
    Agent.start_link(
      fn -> %{test_pid: nil, join_handler: &default_join_handler/1, connections: []} end,
      name: __MODULE__
    )
  end

  @doc """
  Starts the TLS listener and returns its port. Reports to `test_pid`.
  """
  def start(test_pid) do
    Agent.update(__MODULE__, &%{&1 | test_pid: test_pid})

    # peridiod speaks TLS 1.3, which refuses the small keys and SHA-1 signatures that
    # :public_key.pkix_test_data/1 generates by default
    chain = [digest: :sha256, key: {:rsa, 2048, 65537}]

    %{server_config: server_config} =
      :public_key.pkix_test_data(%{
        server_chain: %{root: chain, peer: chain},
        client_chain: %{root: chain, peer: chain}
      })

    dispatch =
      :cowboy_router.compile([{:_, [{"/socket/websocket", Socket, []}]}])

    {:ok, _pid} =
      :cowboy.start_tls(
        @ref,
        [{:port, 0} | server_config],
        %{env: %{dispatch: dispatch}}
      )

    :ranch.get_port(@ref)
  end

  def stop, do: :cowboy.stop_listener(@ref)

  @doc """
  Ends the channel on every connection.

  `"phx_error"` is what the cloud sends when the channel process crashes or the
  server restarts, and the client rejoins. `"phx_close"` is a clean close, which the
  client treats as having left.
  """
  def end_topic(topic, event \\ "phx_error") do
    Agent.get(__MODULE__, & &1.connections) |> Enum.each(&send(&1, {:end_topic, topic, event}))
  end

  @doc false
  def register_connection do
    # self() inside the function would be the agent
    connection = self()
    Agent.update(__MODULE__, &%{&1 | connections: [connection | &1.connections]})
  end

  @doc "Sets what a join answers. The function gets the join params."
  def set_join_handler(fun) when is_function(fun, 1),
    do: Agent.update(__MODULE__, &%{&1 | join_handler: fun})

  @doc false
  def join_reply("device", params), do: Agent.get(__MODULE__, & &1.join_handler).(params)
  def join_reply(_topic, _params), do: %{}

  @doc false
  def report(message) do
    case Agent.get(__MODULE__, & &1.test_pid) do
      nil -> :ok
      pid -> send(pid, message)
    end
  end

  # nothing pending
  defp default_join_handler(_params), do: %{"update_available" => false}
end
