defmodule Peridiod.Binary.Downloader.VerifyConfig do
  @moduledoc """
  Optional integrity verification configuration for the Downloader.

  When provided to the Downloader, it will compute a SHA-256 hash during
  download and verify it (and optionally the file size) on completion.
  Any field set to `nil` skips that verification.

  Note: hash verification is skipped only for partial resumed downloads where
  bytes already exist locally (`existing_size > 0`), because the Downloader
  only sees bytes from the resume point onward. A resume from byte 0 is treated
  as a full download and hash verification applies normally. Size verification
  works for all downloads since `downloaded_length` tracks the running total.
  """

  defstruct expected_hash: nil,
            expected_size: nil

  @type t :: %__MODULE__{
          expected_hash: binary() | nil,
          expected_size: non_neg_integer() | nil
        }
end
