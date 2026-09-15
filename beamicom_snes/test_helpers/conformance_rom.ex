defmodule Beamicom.SNES.ConformanceROM do
  @moduledoc false

  alias Beamicom.SNES.Machine

  @fixture_root Path.expand("../test/fixtures/snes_conformance", __DIR__)

  @fixtures [
    spc_dsp6: %{
      suite: :blargg_spc6,
      path: "blargg-spc-6/spc_dsp6.sfc",
      sha256: "b12038f865536a33003c9887e6f86fcbcb526b7f1766526ab30cb74b7380aa9a"
    },
    spc_smp: %{
      suite: :blargg_spc6,
      path: "blargg-spc-6/spc_smp.sfc",
      sha256: "2ed302c5b989675d4ab6b40001fd5166ac4c6e0188a6b1b6df878e4608999c03"
    },
    spc_timer: %{
      suite: :blargg_spc6,
      path: "blargg-spc-6/spc_timer.sfc",
      sha256: "f4799b994a91d78689073f4e31c3668ae46c100abd78177b9f4813506d6c9629"
    },
    spc_mem_access_times: %{
      suite: :blargg_spc6,
      path: "blargg-spc-6/spc_mem_access_times.sfc",
      sha256: "53dc8005959d54ccfc95b8d4222e1d51d21e3d9f3491058320f105edc1a4454a"
    },
    gilyon_cpu_basic: %{
      suite: :gilyon,
      path: "gilyon-snes-tests/cputest-basic.sfc",
      sha256: "d479bde706b9e16d76c0dfe98e2b2d3f5348f9dcb911e6a36b898f4201fc98bb"
    },
    gilyon_cpu_full: %{
      suite: :gilyon,
      path: "gilyon-snes-tests/cputest-full.sfc",
      sha256: "f61de78d346a68c166d67472a414e5d207368889d37b977d1338f9221ca6400e"
    },
    gilyon_spc: %{
      suite: :gilyon,
      path: "gilyon-snes-tests/spctest.sfc",
      sha256: "3909f03d55b07081a4e9ac437ba5179731ec6c8ac3c715f712daec0f398dde63"
    },
    neser_m7_identity: %{
      suite: :neser_mode7,
      path: "neser-mode7-tests/m7-identity.sfc",
      sha256: "2dfb27282618bae57c171d58f57f5f3f5a7ad738fdf63a341aad073b09dca6aa",
      frame_crc32: 0x7EDC_DD3D,
      load_opts: [native_ipl: true]
    },
    neser_m7_scale_wrap: %{
      suite: :neser_mode7,
      path: "neser-mode7-tests/m7-scale-wrap.sfc",
      sha256: "c7b7172288910c78105ab905207b3bbb7497ff0335e7231e09c6ca5da0063680",
      frame_crc32: 0xB431_6EA2,
      load_opts: [native_ipl: true]
    },
    neser_m7_scale_color0: %{
      suite: :neser_mode7,
      path: "neser-mode7-tests/m7-scale-color0.sfc",
      sha256: "a00f907e185dfbd676c9881aefc0999472eb701036ee966319215a0a97ac3925",
      frame_crc32: 0xE5AB_774A,
      load_opts: [native_ipl: true]
    },
    neser_m7_scale_tile0: %{
      suite: :neser_mode7,
      path: "neser-mode7-tests/m7-scale-tile0.sfc",
      sha256: "785ed8de4665b8d2fc2d51c49d659e87e382357018b5356b911e2b62d8968bd5",
      frame_crc32: 0x5D47_8D7E,
      load_opts: [native_ipl: true]
    },
    neser_m7_rot30: %{
      suite: :neser_mode7,
      path: "neser-mode7-tests/m7-rot30.sfc",
      sha256: "64538022583ec155864f7555cd6fb8ca92e1409d062dbfc4fa24eef98fc9076b",
      frame_crc32: 0x9A58_AB93,
      load_opts: [native_ipl: true]
    },
    neser_m7_flip_h: %{
      suite: :neser_mode7,
      path: "neser-mode7-tests/m7-flip-h.sfc",
      sha256: "53765393a202730ea91a33aa42bd40439bd74b840daa501528ecb3870c5f85f3",
      frame_crc32: 0x3C92_8CE7,
      load_opts: [native_ipl: true]
    },
    neser_m7_flip_v: %{
      suite: :neser_mode7,
      path: "neser-mode7-tests/m7-flip-v.sfc",
      sha256: "4f19c3b75e3da330a3cedbab9990f64b5883a434e9dcf2b43186450571e665c4",
      frame_crc32: 0x7DB8_DCC0,
      load_opts: [native_ipl: true]
    },
    neser_m7_mosaic: %{
      suite: :neser_mode7,
      path: "neser-mode7-tests/m7-mosaic.sfc",
      sha256: "0c6a3cdfc5825d5f2d7b192318f45166ced8fc3fea669f5279360edd7a9071e6",
      frame_crc32: 0x27C9_C012,
      load_opts: [native_ipl: true]
    }
  ]

  def fixture_names, do: Keyword.keys(@fixtures)

  def fixture_names(suite) do
    for {name, fixture} <- @fixtures, fixture.suite == suite, do: name
  end

  def fixture_available?(name), do: File.regular?(fixture_path(name))

  def fixtures_available?(names), do: Enum.all?(names, &fixture_available?/1)

  def expected_frame_crc32(name), do: Map.fetch!(fixture!(name), :frame_crc32)

  def fixture_path(name) do
    @fixture_root
    |> Path.join(fixture!(name).path)
  end

  def verify_fixture!(name) do
    fixture = fixture!(name)
    media = File.read!(fixture_path(name))
    actual = :crypto.hash(:sha256, media) |> Base.encode16(case: :lower)

    if actual != fixture.sha256 do
      raise "#{fixture.path} SHA-256 mismatch: expected #{fixture.sha256}, got #{actual}"
    end

    media
  end

  def load!(name) do
    fixture = fixture!(name)

    case name |> verify_fixture!() |> Machine.load(Map.get(fixture, :load_opts, [])) do
      {:ok, machine} -> machine
      {:error, reason} -> raise "could not load #{name}: #{inspect(reason)}"
    end
  end

  def run_frames!(name, frames) when is_integer(frames) and frames > 0 do
    name
    |> load!()
    |> run_frames(frames, nil)
  end

  def run_until_gilyon_result!(name, max_frames)
      when is_integer(max_frames) and max_frames > 0 do
    name
    |> load!()
    |> run_until_gilyon_result(max_frames, nil, 0)
  end

  # Gilyon's harness writes ASCII tile numbers directly to the BG1 tilemap.
  # Reading that protocol is both faster and less brittle than OCR or a frame
  # hash, while still exercising the emulated CPU, APU, DMA, and PPU registers.
  def gilyon_status(%{bus: %{ppu: %{vram: vram}}}) do
    test_number = gilyon_test_number(vram)

    case tilemap_text(vram, 0x32, 7) do
      "Success" -> {:passed, test_number}
      "Failed" -> {:failed, test_number}
      _other -> :running
    end
  end

  # Blargg's harness changes the backdrop from black to red when a case fails.
  # Compare the backdrop rather than an entire frame so text/progress changes do
  # not make the conformance signal brittle.
  def failure_screen?(%{data: <<red, green, blue, _::binary>>}),
    do: red > 0 and green == 0 and blue == 0

  def success_screen?(%{data: <<red, green, blue, _::binary>>}),
    do: red == 0 and green == 0 and blue > 0

  defp run_frames(machine, 0, frame), do: %{machine: machine, frame: frame}

  defp run_frames(machine, remaining, _frame) do
    case Machine.run_until_frame(machine) do
      {:ok, machine, frame} ->
        run_frames(machine, remaining - 1, frame)

      {:error, reason, machine} ->
        raise "conformance ROM stopped at frame #{machine.bus.ppu.frame_number}: #{inspect(reason)}"
    end
  end

  defp run_until_gilyon_result(machine, 0, frame, frames) do
    %{machine: machine, frame: frame, frames: frames, status: gilyon_status(machine)}
  end

  defp run_until_gilyon_result(machine, remaining, _frame, frames) do
    case Machine.run_until_frame(machine) do
      {:ok, machine, frame} ->
        case gilyon_status(machine) do
          :running -> run_until_gilyon_result(machine, remaining - 1, frame, frames + 1)
          status -> %{machine: machine, frame: frame, frames: frames + 1, status: status}
        end

      {:error, reason, machine} ->
        raise "conformance ROM stopped at frame #{machine.bus.ppu.frame_number}: #{inspect(reason)}"
    end
  end

  defp gilyon_test_number(vram) do
    case vram |> tilemap_text(0x6E, 4) |> Integer.parse(16) do
      {number, ""} -> number
      :error -> nil
    end
  end

  defp tilemap_text(vram, word_address, length) do
    for word <- word_address..(word_address + length - 1), into: "" do
      <<:array.get(word * 2, vram)>>
    end
    |> String.trim_trailing(<<0>>)
  end

  defp fixture!(name) do
    case Keyword.fetch(@fixtures, name) do
      {:ok, fixture} -> fixture
      :error -> raise ArgumentError, "unknown conformance fixture: #{inspect(name)}"
    end
  end
end
