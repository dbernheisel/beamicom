defmodule Beamicom.SNES.APUDependencyCacheTest do
  use ExUnit.Case, async: true

  alias Beamicom.SNES.{APU, DSP}
  alias Beamicom.SNES.APU.RAM

  @empty_dependencies MapSet.new()
  @echo_dependencies {:regions, MapSet.new(), [{0x2000, 0x800}]}

  test "retains a fence for repeated values and pitch decreases" do
    dsp = DSP.new() |> DSP.write(0x02, 0x00) |> DSP.write(0x03, 0x20)

    assert APU.dependency_fence_survives_dsp_write?(dsp, 0x02, 0x00, @empty_dependencies)
    assert APU.dependency_fence_survives_dsp_write?(dsp, 0x03, 0x10, @empty_dependencies)
    refute APU.dependency_fence_survives_dsp_write?(dsp, 0x02, 0x01, @empty_dependencies)
  end

  test "invalidates a fence for new BRR routes and echo-ring addresses" do
    dsp = DSP.new()

    for {address, value} <- [
          {0x04, 1},
          {0x2D, 2},
          {0x4C, 1},
          {0x5D, 1},
          {0x6D, 1},
          {0x7D, 1}
        ] do
      refute APU.dependency_fence_survives_dsp_write?(
               dsp,
               address,
               value,
               @empty_dependencies
             )
    end
  end

  test "retains an existing echo fence across mixer and FIR writes" do
    dsp = DSP.new()

    for address <- [0x0D, 0x2C, 0x3C, 0x4D, 0x0F, 0x7F] do
      assert APU.dependency_fence_survives_dsp_write?(
               dsp,
               address,
               0x7F,
               @echo_dependencies
             )

      refute APU.dependency_fence_survives_dsp_write?(
               dsp,
               address,
               0x7F,
               @empty_dependencies
             )
    end
  end

  test "retains non-expanding voice controls" do
    dsp = DSP.new()

    for address <- [0x00, 0x01, 0x05, 0x06, 0x07, 0x3D, 0x5C, 0x6C] do
      assert APU.dependency_fence_survives_dsp_write?(
               dsp,
               address,
               0xFF,
               @empty_dependencies
             )
    end
  end

  test "invalidates only changed directory and BRR-header RAM writes" do
    ram = RAM.new(:array) |> RAM.put(0x1000, 0x44) |> RAM.put(0x2000, 0x11)
    addresses = MapSet.new([0x1000])
    dependencies = {:dependencies, addresses, [{0x2000, 18}], []}

    assert APU.dependency_fence_survives_ram_write?(ram, 0x1000, 0x44, dependencies)
    refute APU.dependency_fence_survives_ram_write?(ram, 0x1000, 0x45, dependencies)
    refute APU.dependency_fence_survives_ram_write?(ram, 0x2000, 0x12, dependencies)
    assert APU.dependency_fence_survives_ram_write?(ram, 0x2001, 0x12, dependencies)
    assert APU.dependency_fence_survives_ram_write?(ram, 0x3000, 0x12, dependencies)
  end
end
