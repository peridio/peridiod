defmodule PeridioAgentTest do
  use ExUnit.Case
  doctest PeridioAgent

  test "greets the world" do
    assert PeridioAgent.hello() == :world
  end
end
