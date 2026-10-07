defmodule Peridiod.Distribution.UrlRefreshTest do
  use ExUnit.Case, async: true

  alias Peridiod.Distribution.UrlRefresh

  @expired %{code: "ExpiredToken", message: "The provided token has expired."}

  describe "new/1" do
    test "takes the policy from the config" do
      config = %Peridiod.Config{
        distributions_url_refresh_max_attempts: 7,
        distributions_url_refresh_wait_ms: 250
      }

      assert %UrlRefresh{max_attempts: 7, wait_ms: 250, attempts: 0} = UrlRefresh.new(config)
    end

    test "defaults" do
      assert %UrlRefresh{max_attempts: 3, wait_ms: 5_000} = UrlRefresh.new(%Peridiod.Config{})
    end
  end

  describe "next/3" do
    test "asks again for an expired URL and counts the attempt" do
      refresh = %UrlRefresh{max_attempts: 2, wait_ms: 100}

      assert {:retry, 100, refresh} = UrlRefresh.next(refresh, 400, @expired)
      assert refresh.attempts == 1
      assert {:retry, 200, refresh} = UrlRefresh.next(refresh, 400, @expired)
      assert refresh.attempts == 2
    end

    test "gives up once attempts are used" do
      refresh = %UrlRefresh{max_attempts: 1, wait_ms: 0}
      assert {:retry, _, refresh} = UrlRefresh.next(refresh, 400, @expired)
      assert {:abort, {:url_refresh_exhausted, 1}} = UrlRefresh.next(refresh, 400, @expired)
    end

    test "max_attempts of 0 never asks" do
      refresh = %UrlRefresh{max_attempts: 0}
      assert {:abort, {:url_refresh_exhausted, 0}} = UrlRefresh.next(refresh, 400, @expired)
    end

    test "doesn't ask for errors a new URL can't fix" do
      refresh = %UrlRefresh{}

      assert {:abort, {:http_error, 400, "InvalidArgument"}} =
               UrlRefresh.next(refresh, 400, %{code: "InvalidArgument", message: "x"})

      assert {:abort, {:http_error, 404, nil}} = UrlRefresh.next(refresh, 404, nil)
    end

    test "the wait doubles with each attempt, up to a cap" do
      refresh = %UrlRefresh{max_attempts: 20, wait_ms: 1_000}

      {waits, _} =
        Enum.map_reduce(1..9, refresh, fn _, refresh ->
          {:retry, wait, refresh} = UrlRefresh.next(refresh, 400, @expired)
          {wait, refresh}
        end)

      assert waits == [1_000, 2_000, 4_000, 8_000, 16_000, 32_000, 60_000, 60_000, 60_000]
    end
  end

  describe "next_after_timeout/1" do
    test "asks again while attempts remain" do
      refresh = %UrlRefresh{max_attempts: 2, wait_ms: 100, attempts: 1}

      assert {:retry, 200, %UrlRefresh{attempts: 2}} = UrlRefresh.next_after_timeout(refresh)
    end

    test "gives up once attempts are used" do
      refresh = %UrlRefresh{max_attempts: 2, attempts: 2}

      assert {:abort, {:url_refresh_exhausted, 2}} = UrlRefresh.next_after_timeout(refresh)
    end
  end

  describe "reset/1" do
    test "gives back the full set of attempts" do
      refresh = %UrlRefresh{max_attempts: 2, attempts: 2}
      assert UrlRefresh.reset(refresh).attempts == 0
    end
  end
end
