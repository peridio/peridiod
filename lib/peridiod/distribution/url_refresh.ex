defmodule Peridiod.Distribution.UrlRefresh do
  @moduledoc """
  Retry policy for a firmware download whose signed URL has stopped working.

  Firmware URLs are presigned by the cloud and can stop working before their
  advertised lifetime, for example when the credentials that signed them expire.
  Retrying the same URL can't succeed, so the device asks the cloud for a new one
  by rejoining the device channel while reporting the firmware it is downloading
  (`currently_downloading_uuid`). The cloud answers with the pending update and a
  freshly signed URL, and doesn't count that join as a failed attempt.

  This module only decides how many times to ask and how long to wait for each
  answer. `Peridiod.Distribution.Server` does the asking and the resuming.
  """

  alias Peridiod.Binary.HttpError

  @max_wait_ms 60_000

  defstruct max_attempts: 3,
            wait_ms: 5_000,
            attempts: 0

  @type t :: %__MODULE__{
          max_attempts: non_neg_integer(),
          wait_ms: non_neg_integer(),
          attempts: non_neg_integer()
        }

  @doc "Builds the policy from `Peridiod.Config`."
  @spec new(Peridiod.Config.t()) :: t()
  def new(config) do
    %__MODULE__{
      max_attempts: config.distributions_url_refresh_max_attempts,
      wait_ms: config.distributions_url_refresh_wait_ms
    }
  end

  @doc """
  Decides what to do about a download that failed with an HTTP error.

  Returns `{:retry, wait_ms, refresh}` when the URL expired and attempts remain.
  The caller should ask for a new URL and wait up to `wait_ms` for it. The wait
  doubles with each attempt, up to #{div(@max_wait_ms, 1000)}s. Returns
  `{:abort, reason}` otherwise.
  """
  @spec next(t(), non_neg_integer(), HttpError.detail() | nil) ::
          {:retry, non_neg_integer(), t()} | {:abort, term()}
  def next(%__MODULE__{} = refresh, status, detail) do
    cond do
      not HttpError.expired_url?(detail) ->
        {:abort, {:http_error, status, error_code(detail)}}

      refresh.attempts >= refresh.max_attempts ->
        {:abort, {:url_refresh_exhausted, refresh.attempts}}

      true ->
        {:retry, wait(refresh), %__MODULE__{refresh | attempts: refresh.attempts + 1}}
    end
  end

  @doc """
  Decides what to do when no new URL arrived within the wait.

  Same as `next/3` for an expired URL: ask again if attempts remain.
  """
  @spec next_after_timeout(t()) :: {:retry, non_neg_integer(), t()} | {:abort, term()}
  def next_after_timeout(%__MODULE__{attempts: attempts, max_attempts: max} = refresh)
      when attempts >= max,
      do: {:abort, {:url_refresh_exhausted, refresh.attempts}}

  def next_after_timeout(%__MODULE__{} = refresh),
    do: {:retry, wait(refresh), %__MODULE__{refresh | attempts: refresh.attempts + 1}}

  @doc "Forgets previous attempts, so the next expiry gets a full set of attempts."
  @spec reset(t()) :: t()
  def reset(%__MODULE__{attempts: 0} = refresh), do: refresh
  def reset(%__MODULE__{} = refresh), do: %__MODULE__{refresh | attempts: 0}

  defp wait(%__MODULE__{wait_ms: wait_ms, attempts: attempts}),
    do: min(wait_ms * Integer.pow(2, attempts), @max_wait_ms)

  defp error_code(%{code: code}), do: code
  defp error_code(_detail), do: nil
end
