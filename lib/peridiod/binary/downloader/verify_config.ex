defmodule Peridiod.Binary.Downloader.VerifyConfig do
  @moduledoc """
  Optional integrity verification configuration for the Downloader.

  When provided to the Downloader, it will compute a SHA-256 hash during
  download and verify it (and optionally the file size) on completion.
  Any field set to `nil` skips that verification.

  Note: hash verification is skipped for resumed downloads because the
  Downloader only sees bytes from the resume point onward. Size verification
  still works for resumed downloads since `downloaded_length` tracks the total.
  """

  defstruct expected_hash: nil,
            expected_size: nil

  @type t :: %__MODULE__{
          expected_hash: binary() | nil,
          expected_size: non_neg_integer() | nil
        }
end
