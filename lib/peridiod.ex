defmodule Peridiod do
  alias Peridiod.Socket
  alias Peridiod.Distribution

  @env Mix.env()

  @spec env_test? :: atom()
  def env_test?() do
    @env == :test
  end

  @spec config :: Peridiod.Config.t()
  def config() do
    application_config = Application.get_all_env(:peridiod)

    Peridiod.Config
    |> struct(application_config)
    |> Peridiod.Config.new()
  end

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
  @spec status :: Distribution.Server.State.status()
  defdelegate status(), to: Distribution.Server

  @doc """
  Restart the socket and device channel
  """
  @spec reconnect() :: :ok
  defdelegate reconnect(), to: Socket

  @doc """
  Send update progress percentage for display in web
  """
  @spec send_distribution_progress(non_neg_integer()) :: :ok
  defdelegate send_distribution_progress(progress), to: Socket

  @doc """
  Send an update status to web
  """
  @spec send_distribution_status(String.t() | atom()) :: :ok
  defdelegate send_distribution_status(status), to: Socket
end
