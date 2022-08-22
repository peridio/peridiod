defmodule Peridiod.Log do
  @typedoc """
  A binary or a function that evaluates to a binary.
  """

  @type payload :: binary() | fun() | map()

  @typedoc """
  A `{module, function, args}` tuple like `{String, :replace_suffix, ["\n", ""]}` or an anonymous function of any arity that returns a binary. If the function takes any arguments the first it will be passed will be the binary result of the relevant log_msg.
  """
  @type option :: (... -> msg :: binary()) | {module(), atom(), list()}

  defmacro __using__(_opts) do
    quote do
      import Peridiod.Log

      @default_options [{String, :replace_suffix, ["\n", ""]}]

      deflog(:debug)
      deflog(:info)
      deflog(:warn)
      deflog(:error)
    end
  end

  defmacro deflog(fun_name) do
    quote do
      @doc false
      def unquote(fun_name)(payload, options \\ @default_options) do
        Peridiod.Log.__log__({unquote(fun_name), __MODULE__, payload}, options)
      end
    end
  end

  def __log__({fun_name, module, payload}, options) do
    require Logger

    payload
    |> expand()
    |> encode(fun_name, module, options)
    |> case do
      {:debug, log_string} -> Logger.debug(log_string)
      {:info, log_string} -> Logger.info(log_string)
      {:warn, log_string} -> Logger.warn(log_string)
      {:error, log_string} -> Logger.error(log_string)
    end
  end

  defp expand(payload) when is_function(payload), do: expand(payload.())

  defp expand(payload) when is_binary(payload) or is_map(payload), do: payload

  defp encode(payload, fun_name, module, options) do
    log = %{module: module, pid: "#{inspect(self())}"}

    {fun_name, log_string} =
      log
      |> Map.put(:payload, payload)
      |> Jason.encode(log)
      |> case do
        {:ok, log_string} ->
          {fun_name, log_string}

        {:error, _} ->
          log_string =
            log
            |> Map.put(:failed_payload, "#{inspect(payload, structs: false)}")
            |> Map.put(:payload, "failed to encode application payload")
            |> Jason.encode!()

          {:error, log_string}
      end

    log_string = apply_options(log_string, options)
    {fun_name, log_string}
  end

  defp apply_options(msg, []), do: msg

  defp apply_options(msg, options), do: Enum.reduce(options, msg, &apply_option/2)

  defp apply_option({fun, args}, msg), do: apply(fun, [msg | args])

  defp apply_option({module, fun, args}, msg), do: apply(module, fun, [msg | args])
end
