defmodule Peridiod.Cloud.Shadow do
  require Logger

  alias Peridiod.Cloud

  @doc """
  Validates the shadow configuration without executing the script.

  Returns `:ok` if valid, or `{:error, reason}` if invalid.
  """
  def validate(config) do
    with :ok <- validate_executable(config.shadow_executable),
         :ok <- validate_args(config.shadow_args) do
      :ok
    end
  end

  @doc """
  Updates the device shadow by executing the configured shadow script
  and uploading the result to the Peridio API.

  Returns `{:ok, response}` on success or `{:error, reason}` on failure.
  """
  def update(config) do
    with :ok <- validate_executable(config.shadow_executable),
         :ok <- validate_args(config.shadow_args),
         {output, 0} <- System.cmd(config.shadow_executable, config.shadow_args),
         {:ok, shadow_data} <- Jason.decode(output),
         client <- Cloud.get_client(),
         _ = Logger.info("[Cloud Server] Uploading shadow"),
         {:ok, response} <- PeridioSDK.DeviceAPI.Devices.shadow(client, shadow_data) do
      {:ok, response}
    else
      {:error, %Jason.DecodeError{} = error} ->
        Logger.error("[Cloud Server] Failed to decode shadow script output: #{inspect(error)}")
        {:error, error}

      {:error, reason} = error ->
        Logger.error("[Cloud Server] Shadow upload failed: #{inspect(reason)}")
        error

      {_output, code} ->
        Logger.error("[Cloud Server] Shadow script exited with code #{code}")
        {:error, :script_failed}
    end
  end

  defp validate_executable(nil) do
    {:error, "Shadow executable not configured"}
  end

  defp validate_executable(executable) when is_binary(executable) do
    cond do
      String.contains?(executable, [
        ";",
        "|",
        "&",
        "`",
        "$",
        "(",
        ")",
        "{",
        "}",
        "<",
        ">",
        "\n",
        "\r"
      ]) ->
        {:error, "Shadow executable contains invalid characters"}

      not String.starts_with?(executable, "/") ->
        {:error, "Shadow executable must be an absolute path"}

      true ->
        :ok
    end
  end

  defp validate_executable(_) do
    {:error, "Shadow executable must be a string"}
  end

  defp validate_args(args) when is_list(args) do
    if Enum.all?(args, &valid_arg?/1) do
      :ok
    else
      {:error, "Shadow args contain invalid values"}
    end
  end

  defp validate_args(_) do
    {:error, "Shadow args must be a list"}
  end

  defp valid_arg?(arg) when is_binary(arg), do: true
  defp valid_arg?(_), do: false
end
