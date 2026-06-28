defmodule AgentOSTest do
  use ExUnit.Case
  doctest AgentOS

  test "greets the world" do
    assert AgentOS.hello() == :world
  end
end
