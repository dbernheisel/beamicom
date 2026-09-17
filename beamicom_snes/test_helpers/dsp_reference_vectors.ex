defmodule Beamicom.SNES.DSPReferenceVectors do
  @moduledoc """
  Small, Beamicom-authored S-DSP vectors used by the trace harness.

  Active vectors capture the current scalar baseline for arithmetic, voice,
  noise, modulation, and echo behavior.
  """

  import Bitwise

  @active_features [
    :signed_arithmetic,
    :clamp_points,
    :interpolation,
    :envelope,
    :kon_koff,
    :endx,
    :brr_transition,
    :echo,
    :noise,
    :pmon
  ]

  @pending_features []

  def active do
    Enum.map(@active_features, &vector/1)
  end

  def pending do
    Enum.map(@pending_features, fn {feature, reason} ->
      vector(feature) |> Map.put(:skip, reason)
    end)
  end

  def vector(:signed_arithmetic) do
    %{
      id: "signed-arithmetic",
      version: 3,
      feature: :signed_arithmetic,
      setup: voice_setup(0xC3, List.duplicate(0x88, 8), 0x1000, 0x80, 0x7F),
      actions: [{:render_samples, 24}],
      inspect: [registers: [0x00, 0x01, 0x0C, 0x1C], voices: [0], ram: 0x200..0x208],
      golden: %{
        pcm: "0d0bd13946cf693f7922a02d88c76dde12411a0498e0b58d5302ffd2a1127984",
        state: "c03e95322ccbf5051714fcf0336b8b444a27992c3f888b0a5994aa76fadacde9"
      }
    }
  end

  def vector(:clamp_points) do
    %{
      id: "clamp-points",
      version: 3,
      feature: :clamp_points,
      setup: saturated_voice_setup(),
      actions: [{:render_samples, 24}],
      inspect: [registers: [0x0C, 0x1C, 0x4C], voices: Enum.to_list(0..7), ram: 0x200..0x208],
      golden: %{
        pcm: "036eb6048d3052e4ebe6a4e2113893266d29893a5c5b899b6be4340712225921",
        state: "dda7491168170893c10c500cbb9490526151f6bca80ec630d78fb8da2011b826"
      }
    }
  end

  def vector(:interpolation) do
    %{
      id: "gaussian-interpolation",
      version: 3,
      feature: :interpolation,
      setup: voice_setup(0xC3, [0x07, 0x70, 0, 0, 0, 0, 0, 0], 0x0400),
      actions: [{:render_samples, 21}],
      inspect: [registers: [0x02, 0x03, 0x4C], voices: [0], ram: 0x200..0x208],
      golden: %{
        pcm: "13134619f8b13e3705e6773fe38777433f1552f161854544a99a279250cebbc8",
        state: "97919237e35f9935fbb422923237c90b064a3c016bebafd1890b8c1e69c44991"
      }
    }
  end

  def vector(:envelope) do
    %{
      id: "adsr-envelope",
      version: 3,
      feature: :envelope,
      setup:
        voice_setup(0xC3, List.duplicate(0x77, 8), 0x0400) ++
          [{:write_register, 0x05, 0x8F}, {:write_register, 0x06, 0xE0}],
      actions: [{:render_samples, 8}],
      inspect: [registers: [0x05, 0x06], voices: [0], ram: 0x200..0x208],
      golden: %{
        pcm: "b8937c8b85ca32bca52f380e87fdfb109496d4aeac70870817b768b7dba069ac",
        state: "88be0fea77d87416b7939490c9405d9e6ac48a9b3105653c6a85b04012996b69"
      }
    }
  end

  def vector(:kon_koff) do
    %{
      id: "kon-koff",
      version: 3,
      feature: :kon_koff,
      setup: voice_setup(0xC3, List.duplicate(0x77, 8), 0x0400),
      actions: [
        {:render_samples, 7},
        {:write_register, 0x5C, 0x01},
        {:render_samples, 4}
      ],
      inspect: [registers: [0x4C, 0x5C], voices: [0], ram: 0x200..0x208],
      golden: %{
        pcm: "8196e155cbcb3b368a5bc164d09ff1350e6a42fb5a4694cfce90170d7f5c3784",
        state: "56502cc7d2602e5bc243f28a6d00ff8ab1126fd137fd0b2872dd74ed52b073e4"
      }
    }
  end

  def vector(:endx) do
    %{
      id: "endx-transition",
      version: 3,
      feature: :endx,
      setup: voice_setup(0xC1, List.duplicate(0x77, 8), 0x3FFF),
      actions: [{:render_samples, 12}],
      inspect: [registers: [0x4C, 0x7C], voices: [0], ram: 0x200..0x208],
      golden: %{
        pcm: "deac51101282ad069149961feeb54606b62b99d8018c1b84c6de73fd33b4c3e8",
        state: "e80e89215da480fec36612034569a2b5e6b1ccb0d515103ddb95fc9fa97c4aed"
      }
    }
  end

  def vector(:brr_transition) do
    second_block = [{0x209, 0xC1} | Enum.map(0x20A..0x211, &{&1, 0x88})]

    %{
      id: "brr-block-transition",
      version: 3,
      feature: :brr_transition,
      setup:
        voice_setup(0xC0, List.duplicate(0x77, 8), 0x3000) ++
          [{:write_ram, second_block}],
      actions: [{:render_samples, 14}],
      inspect: [registers: [0x02, 0x03], voices: [0], ram: 0x200..0x211],
      golden: %{
        pcm: "d44bf3e50fb6c6c3e20b28d0e84ce823bdd8f0b341c9f252fc478ddec79bdd99",
        state: "4ac4c0ef213c6de21a16cf6a2b9b68a424467749bb5a5a1a7dc766d959fdd1ff"
      }
    }
  end

  def vector(:echo) do
    %{
      id: "echo-impulse",
      version: 3,
      feature: :echo,
      setup: voice_setup(0xC3, List.duplicate(0x77, 8), 0x1000),
      actions: [
        {:write_registers,
         [
           {0x2C, 0x7F},
           {0x3C, 0x7F},
           {0x0D, 0x40},
           {0x4D, 0x01},
           {0x6D, 0x30},
           {0x7D, 0x01},
           {0x0F, 0x7F}
         ]},
        {:render_samples, 16}
      ],
      inspect: [
        registers: [0x0D, 0x0F, 0x2C, 0x3C, 0x4D, 0x6D, 0x7D],
        voices: [0],
        ram: 0x3000..0x3007
      ],
      golden: %{
        pcm: "a03436d1532a5db8d951f9f21862147bda33b15bf11d1ec4f305e3eeab3c8a6b",
        state: "9502fa0cde04aca5268a4aa64a3d48fc43f4b45c9045f5f3f63944913505b61c"
      }
    }
  end

  def vector(:noise) do
    %{
      id: "noise-sequence",
      version: 3,
      feature: :noise,
      setup: voice_setup(0xC3, List.duplicate(0, 8), 0x1000),
      actions: [
        {:write_register, 0x3D, 0x01},
        {:write_register, 0x6C, 0x1F},
        {:render_samples, 16}
      ],
      inspect: [registers: [0x3D, 0x6C], voices: [0], ram: []],
      golden: %{
        pcm: "57c8e30744f6163f67066e0d90d9a9493f1db5d56aa9bce3c50c6c83408f2c30",
        state: "3323af7652b576a229f30e10033384b6de7de9f2d75de78056a1e764e7a72b82"
      }
    }
  end

  def vector(:pmon) do
    %{
      id: "pitch-modulation",
      version: 3,
      feature: :pmon,
      setup: two_voice_setup(),
      actions: [{:write_register, 0x2D, 0x02}, {:render_samples, 16}],
      inspect: [registers: [0x2D, 0x4C], voices: [0, 1], ram: 0x200..0x208],
      golden: %{
        pcm: "13e79118fa7533446729f08fad2109fb66ad9dc12b29c7a47077712bb4e6c942",
        state: "5ca00f2cbf63f2913626fa6d7e0f403c6839bc509a84f18111dafd8e4b782f4d"
      }
    }
  end

  defp voice_setup(header, bytes, pitch, voice_volume \\ 0x7F, master_volume \\ 0x7F) do
    ram =
      [{0x100, 0x00}, {0x101, 0x02}, {0x102, 0x00}, {0x103, 0x02}, {0x200, header}] ++
        Enum.zip(0x201..0x208, bytes)

    registers = [
      {0x00, voice_volume},
      {0x01, voice_volume},
      {0x02, pitch &&& 0xFF},
      {0x03, pitch >>> 8},
      {0x04, 0x00},
      {0x07, 0x7F},
      {0x0C, master_volume},
      {0x1C, master_volume},
      {0x5D, 0x01},
      {0x4C, 0x01}
    ]

    [{:write_ram, ram}, {:write_registers, registers}]
  end

  defp saturated_voice_setup do
    directory =
      Enum.flat_map(0..7, fn index ->
        offset = 0x100 + index * 4
        [{offset, 0x00}, {offset + 1, 0x02}, {offset + 2, 0x00}, {offset + 3, 0x02}]
      end)

    voices =
      Enum.flat_map(0..7, fn index ->
        base = index * 0x10

        [
          {base, 0x7F},
          {base + 1, 0x7F},
          {base + 2, 0x00},
          {base + 3, 0x10},
          {base + 4, index},
          {base + 7, 0x7F}
        ]
      end)

    ram = directory ++ [{0x200, 0xC3}] ++ Enum.map(0x201..0x208, &{&1, 0x77})

    registers = voices ++ [{0x0C, 0x7F}, {0x1C, 0x7F}, {0x5D, 0x01}, {0x4C, 0xFF}]

    [{:write_ram, ram}, {:write_registers, registers}]
  end

  defp two_voice_setup do
    [{:write_ram, ram}, {:write_registers, registers}] =
      voice_setup(0xC3, List.duplicate(0x77, 8), 0x1000)

    ram = ram ++ [{0x104, 0x00}, {0x105, 0x02}, {0x106, 0x00}, {0x107, 0x02}]

    registers =
      registers ++
        [
          {0x10, 0x7F},
          {0x11, 0x7F},
          {0x12, 0x00},
          {0x13, 0x10},
          {0x14, 0x01},
          {0x17, 0x7F},
          {0x4C, 0x03}
        ]

    [{:write_ram, ram}, {:write_registers, registers}]
  end
end
