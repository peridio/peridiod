defmodule Peridiod.Distribution do
  @moduledoc false

  alias Peridiod.Binary.Installer.Fwup

  defstruct [:firmware_url, :firmware_meta]

  @typedoc """
  Payload that gets dispatched down to devices upon an update

  `firmware_url` and `firmware_meta` are only available
  when `update_available` is true.
  """
  @type t() :: %__MODULE__{
          firmware_url: URI.t(),
          firmware_meta: Fwup.Metadata.t()
        }

  @doc "Parse an update message from Peridio"
  @spec parse(map()) :: {:ok, t()} | {:error, :invalid_params}
  def parse(%{"firmware_meta" => %{} = meta, "firmware_url" => url}) do
    with {:ok, firmware_meta} <- Fwup.Metadata.parse(meta) do
      {:ok,
       %__MODULE__{
         firmware_url: URI.parse(url),
         firmware_meta: firmware_meta
       }}
    end
  end

  def parse(_), do: {:error, :invalid_params}
end
