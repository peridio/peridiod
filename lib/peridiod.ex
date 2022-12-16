defmodule Peridiod do
  alias Peridiod.Socket

  @doc """
  Checks if the device is connected to the Peridio device channel.
  """
  @spec connected? :: boolean()
  def connected?() do
    Socket.check_connection(:device)
  end

  def console_connected?() do
    Socket.check_connection(:console)
  end

  @doc """
  Checks if the device has a socket connection with Peridio
  """
  def socket_connected?() do
    Socket.check_connection(:socket)
  end

  @doc """
  Current status of the update manager
  """
  @spec status :: Peridiod.UpdateManager.State.status()
  defdelegate status(), to: Peridiod.UpdateManager

  @doc """
  Restart the socket and device channel
  """
  @spec reconnect() :: :ok
  defdelegate reconnect(), to: Socket

  @doc """
  Send update progress percentage for display in web
  """
  @spec send_update_progress(non_neg_integer()) :: :ok
  defdelegate send_update_progress(progress), to: Socket

  @doc """
  Send an update status to web
  """
  @spec send_update_status(String.t() | atom()) :: :ok
  defdelegate send_update_status(status), to: Socket
end
