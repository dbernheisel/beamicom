defmodule BeamicomPhx.EmulatorTest do
  use ExUnit.Case, async: false
  # Runs the real NES Runtime (publishes into the shared Beamicom.NES.Output), so
  # it's excluded from the default suite to avoid contaminating the source tests.
  @moduletag :integration

  @rom "test/support/fixtures/01.basics.nes"

  setup do
    on_exit(&BeamicomPhx.Emulator.stop/0)
    :ok
  end

  test "load/1 starts a Runtime that produces frames; stop/0 tears it down" do
    refute BeamicomPhx.Emulator.loaded?()

    assert :ok = BeamicomPhx.Emulator.load(@rom)
    assert BeamicomPhx.Emulator.loaded?()

    Process.sleep(500)
    assert %Beamicom.NES.Framebuffer{} = Beamicom.NES.Output.latest()

    assert :ok = BeamicomPhx.Emulator.stop()
    refute BeamicomPhx.Emulator.loaded?()
  end
end
