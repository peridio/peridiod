defmodule Peridiod.Message.ReleaseManifest do
    @moduledoc """
    Structure containing metadata about a release.
    """

    defstruct [
      :prn,
      :version,
      :manifest
    ]

    @type t() :: %__MODULE__{
            prn: String.t(),
            version: Version.build(),
            manifest: List.t()
          }

    @spec parse(map()) :: {:ok, t()}
    def parse(%{"release" => release, "manifest" => manifest}) do
      {:ok,
       %__MODULE__{
         prn: release["prn"],
         version: release["version"],
         manifest: manifest
       }}
    end
  end
