defmodule Peridiod.Cloud.NetworkMonitor do
  use GenServer

  require Logger

  alias Peridio.NetMon
  alias Peridiod.Cloud

  @moduledoc """
  Cloud Monitor will take a list of network interfaces in order of priority
  If a network interface
  """

  defstruct interfaces: %{},
            priorities: []

  defmodule InterfaceInfo do
    defstruct status: nil,
              weight: 0,
              opts: %{}
  end

  def config(%{"interface_priority" => interface_priority}),
    do: config(%{interface_priority: interface_priority})

  def config(%{interface_priority: interface_priority}) do
    {interfaces, priorities, _weight_counter} =
      Enum.reduce(interface_priority, {%{}, [], 0}, fn
        %{} = kv, {acc, priorities, weight} ->
          [ifname] = Map.keys(kv)
          acc = Map.put(acc, ifname, %InterfaceInfo{opts: Map.get(kv, ifname), weight: weight})
          {acc, [ifname | priorities], weight + 1}

        ifname, {acc, priorities, weight} when is_binary(ifname) ->
          acc = Map.put(acc, ifname, %InterfaceInfo{weight: weight})
          {acc, [ifname | priorities], weight + 1}
      end)

    %__MODULE__{interfaces: interfaces, priorities: Enum.reverse(priorities)}
  end

  def config(_) do
    %__MODULE__{}
  end

  def start_link(opts, genserver_opts \\ [name: __MODULE__]) do
    GenServer.start_link(__MODULE__, opts, genserver_opts)
  end

  def init(%__MODULE__{interfaces: interfaces, priorities: priorities}) do
    setup_monitor_priority(interfaces)
    interfaces = interfaces_initial_state(interfaces)

    {:ok,
     %{
       interfaces: interfaces,
       priorities: priorities,
       bound_to_interface: nil
     }}
  end

  def setup_monitor_priority(interfaces) do
    Enum.each(interfaces, &do_monitor_interface/1)
  end

  def interfaces_initial_state(interfaces) do
    interfaces
    |> Enum.reduce(%{}, &init_interface_status/2)
  end

  # A Priority interface is online, lets bind to it
  def handle_info(
        {NetMon, ["interface", ifname, "connection"], _, :internet, _timestamps},
        %{bound_to_interface: nil} = state
      ) do
    interfaces = update_in(state.interfaces, [ifname, Access.key(:status)], fn _ -> :internet end)
    bound_to_interface = update_bind_to_device({ifname, Map.get(interfaces, ifname)})
    Cloud.Socket.stop()
    {:noreply, %{state | bound_to_interface: bound_to_interface, interfaces: interfaces}}
  end

  def handle_info(
        {NetMon, ["interface", ifname, "connection"], _, :internet, _timestamps},
        %{bound_to_interface: {bound, %{opts: %{"disconnect_on_higher_priority" => true}}}} =
          state
      ) do
    interfaces = update_in(state.interfaces, [ifname, Access.key(:status)], fn _ -> :internet end)
    new_priority = Enum.find_index(state.priorities, &(&1 == ifname))
    current_priority = Enum.find_index(state.priorities, &(&1 == bound))

    bound_to_interface =
      if current_priority > new_priority do
        Logger.info("[Cloud Monitor] Disconnecting from #{bound} for higher priority #{ifname}")
        bound = update_bind_to_device({ifname, interfaces[ifname]})
        Cloud.Socket.stop()
        bound
      else
        Logger.info("[Cloud Monitor] Keeping bound interface #{bound}")
        bound
      end

    {:noreply, %{state | bound_to_interface: bound_to_interface, interfaces: interfaces}}
  end

  def handle_info(
        {NetMon, ["interface", ifname, "connection"], _, :internet, _timestamps},
        %{bound_to_interface: {ifname, interface}} = state
      ) do
    Logger.info("[Cloud Monitor] Already bound #{ifname}")
    interfaces = Map.put(state.interfaces, ifname, %{interface | status: :internet})
    {:noreply, %{state | interfaces: interfaces}}
  end

  # Lost connection to current bound device
  def handle_info(
        {NetMon, ["interface", ifname, "connection"], _, status, _timestamps},
        %{bound_to_interface: {ifname, interface}} = state
      ) do
    Logger.info("[Cloud Monitor] Connection lost with current interface #{ifname}")
    interfaces = Map.put(state.interfaces, ifname, %{interface | status: status})

    next_interface =
      Enum.find(state.priorities, fn
        ifname ->
          Enum.find(interfaces, &(elem(&1, 0) == ifname and elem(&1, 1).status == :internet))
      end)

    bound_to_interface = update_bind_to_device({next_interface, interfaces[next_interface]})
    Cloud.Socket.stop()
    {:noreply, %{state | bound_to_interface: bound_to_interface, interfaces: interfaces}}
  end

  def handle_info(
        {NetMon, ["interface", ifname, "connection"], _, status, _timestamps},
        state
      ) do
    Logger.info("[Cloud Monitor] Updating interface #{ifname}")
    interfaces = update_in(state.interfaces, [ifname, Access.key(:status)], fn _ -> status end)
    state = %{state | interfaces: interfaces}
    {:noreply, state}
  end

  def handle_info(message, state) do
    Logger.debug("Unhandled Message #{inspect(message)}")
    {:noreply, state}
  end

  defp do_monitor_interface({ifname, _interface}) do
    NetMon.subscribe(["interface", ifname, "connection"])
    NetMon.Connectivity.InternetChecker.start_link(ifname)
  end

  defp init_interface_status({ifname, interface}, acc) do
    status = NetMon.get(["interface", ifname, "connection"])
    Map.put(acc, ifname, %{interface | status: status})
  end

  defp update_bind_to_device({nil, _}) do
    Logger.info("[Cloud Monitor] Network interface unbound")

    tls_opts =
      Cloud.get_tls_opts()
      |> Keyword.drop([:bind_to_device])

    Cloud.update_tls_opts(tls_opts)
    nil
  end

  defp update_bind_to_device({ifname, interface}) do
    Logger.info("[Cloud Monitor] Network interface binding to #{ifname}")

    tls_opts =
      Cloud.get_tls_opts()
      |> Keyword.put(:bind_to_device, ifname)

    Cloud.update_tls_opts(tls_opts)
    {ifname, interface}
  end
end
