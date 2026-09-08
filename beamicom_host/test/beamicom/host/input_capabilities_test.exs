defmodule Beamicom.Host.InputCapabilitiesTest do
  use ExUnit.Case, async: true

  alias Beamicom.Host.{Input, InputCapabilities}

  test "accepts only known ports and controls" do
    capabilities = InputCapabilities.new(%{1 => [:a, :b], 2 => [:a]})

    assert InputCapabilities.accepts?(capabilities, Input.new(1, [:a, :b]))
    refute InputCapabilities.accepts?(capabilities, Input.new(2, [:b]))
    refute InputCapabilities.accepts?(capabilities, Input.new(3, []))
  end
end
