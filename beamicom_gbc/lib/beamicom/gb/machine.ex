defmodule Beamicom.GB.Machine do
  @moduledoc """
  Coherent CPU and mapped-device ownership boundary for Game Boy emulation.

  The bus contains the sole PPU and APU instances, so their registers, memory,
  and timing have one authoritative copy. CPU memory cycles advance timer
  T-cycles and base hardware dots in their hardware order. Instruction
  boundaries also execute pending OAM/GDMA work and HBlank-qualified HDMA
  blocks, reporting their CPU stall cost to callers.
  """

  alias Beamicom.GB.{APU, Bus, CPU, Cartridge, PPU}

  @max_instructions_per_frame 1_000_000

  @enforce_keys [:cpu, :bus, :model]
  defstruct @enforce_keys

  @type t :: %__MODULE__{cpu: CPU.t(), bus: Bus.t(), model: Bus.model()}

  @doc """
  Loads cartridge media and constructs a machine.

  Boot-ROM skipping is the default. It initializes CPU registers and the LCD to
  a stable post-boot state and begins execution at 0100. Set skip_boot: false
  and supply boot_rom: binary to execute a boot ROM from address zero.
  """
  @spec load(binary(), keyword()) :: {:ok, t()} | {:error, term()}
  def load(media, opts \\ []) when is_binary(media) and is_list(opts) do
    with {:ok, cartridge} <- Cartridge.load(media, opts),
         {:ok, model} <- model_for(cartridge.header.cgb_mode, Keyword.get(opts, :model)),
         {:ok, skip_boot, boot_rom} <- boot_options(opts) do
      bus = Bus.new(cartridge, model: model, boot_rom: boot_rom)

      if skip_boot do
        {:ok,
         %__MODULE__{
           cpu: post_boot_cpu(model, cartridge.header, media),
           bus: post_boot_bus(bus, model),
           model: model
         }}
      else
        {:ok, %__MODULE__{cpu: CPU.new(), bus: bus, model: model}}
      end
    end
  end

  @doc "Executes one SM83 instruction plus any DMA stall it triggers."
  @spec step(t()) :: {t(), pos_integer()}
  def step(%__MODULE__{cpu: cpu, bus: bus} = machine) do
    {cpu, bus, m_cycles} = CPU.step(cpu, bus)

    {bus, dma_cycles} =
      case bus do
        %Bus{oam_dma: nil, hdma_request: nil, hblank_pending: 0} ->
          {bus, 0}

        _ ->
          Bus.run_dma(bus, cpu.run_state != :halted)
      end

    {%{machine | cpu: cpu, bus: bus}, m_cycles + dma_cycles}
  end

  @doc "Replaces the complete handheld button state."
  @spec set_buttons(t(), [atom()] | byte()) :: t()
  def set_buttons(%__MODULE__{bus: bus} = machine, buttons),
    do: %{machine | bus: Bus.set_buttons(bus, buttons)}

  @doc "Runs until the next completed LCD frame."
  @spec run_until_frame(t(), pos_integer()) ::
          {:ok, t(), non_neg_integer(), Beamicom.GB.PPU.frame()} | {:error, :frame_timeout, t()}
  def run_until_frame(%__MODULE__{} = machine, limit \\ @max_instructions_per_frame)
      when is_integer(limit) and limit > 0 do
    target = machine.bus.ppu.frame_number
    next_frame(machine, target, limit)
  end

  defp next_frame(machine, _target, 0), do: {:error, :frame_timeout, machine}

  defp next_frame(machine, target, remaining) do
    {machine, _m_cycles} = step(machine)

    case machine.bus.ppu do
      %PPU{frame_number: number, frame: frame} when number > target ->
        {:ok, machine, number - 1, frame}

      _ppu ->
        next_frame(machine, target, remaining - 1)
    end
  end

  defp boot_options(opts) do
    skip_boot = Keyword.get(opts, :skip_boot, true)
    boot_rom = Keyword.get(opts, :boot_rom, <<>>)

    cond do
      not is_boolean(skip_boot) -> {:error, :invalid_skip_boot}
      not is_binary(boot_rom) -> {:error, :invalid_boot_rom}
      not skip_boot and boot_rom == <<>> -> {:error, :boot_rom_required}
      skip_boot -> {:ok, true, <<>>}
      true -> {:ok, false, boot_rom}
    end
  end

  defp model_for(:dmg_only, nil), do: {:ok, :dmg}
  defp model_for(:cgb_compatible, nil), do: {:ok, :cgb}
  defp model_for(:cgb_only, nil), do: {:ok, :cgb}
  defp model_for(:cgb_only, :dmg), do: {:error, :cgb_required}
  defp model_for(_mode, model) when model in [:dmg, :cgb], do: {:ok, model}
  defp model_for(_mode, _model), do: {:error, :invalid_model}

  defp post_boot_cpu(:dmg, header, _media) do
    CPU.new(
      a: 0x01,
      f: if(header.header_checksum == 0, do: 0x80, else: 0xB0),
      b: 0x00,
      c: 0x13,
      d: 0x00,
      e: 0xD8,
      h: 0x01,
      l: 0x4D,
      sp: 0xFFFE,
      pc: 0x0100
    )
  end

  defp post_boot_cpu(:cgb, %{cgb_mode: :dmg_only}, media) do
    b = cgb_compatibility_b(media)
    {h, l} = if b in [0x43, 0x58], do: {0x99, 0x1A}, else: {0x00, 0x7C}

    CPU.new(
      a: 0x11,
      f: 0x80,
      b: b,
      c: 0x00,
      d: 0x00,
      e: 0x08,
      h: h,
      l: l,
      sp: 0xFFFE,
      pc: 0x0100
    )
  end

  defp post_boot_cpu(:cgb, _header, _media) do
    CPU.new(
      a: 0x11,
      f: 0x80,
      b: 0x00,
      c: 0x00,
      d: 0xFF,
      e: 0x56,
      h: 0x00,
      l: 0x0D,
      sp: 0xFFFE,
      pc: 0x0100
    )
  end

  defp cgb_compatibility_b(media) do
    old_licensee = :binary.at(media, 0x014B)

    if old_licensee == 0x01 or
         (old_licensee == 0x33 and binary_part(media, 0x0144, 2) == "01") do
      media
      |> binary_part(0x0134, 16)
      |> :binary.bin_to_list()
      |> Enum.sum()
      |> rem(256)
    else
      0
    end
  end

  # Stable values observed at the boot-ROM handoff are documented at
  # https://gbdev.io/pandocs/Power_Up_Sequence.html. CGB DIV is deliberately
  # zeroed because its handoff value depends on the cartridge header and input;
  # software must not rely on it when the boot ROM is skipped.
  defp post_boot_bus(bus, :dmg) do
    bus
    |> Map.put(:divider, 0xAB00)
    |> Map.put(:joyp_select, 0)
    |> Map.put(:serial_data, 0)
    |> Map.put(:serial_control, 0)
    |> Map.put(:interrupt_flags, 0x01)
    |> Map.put(:ie, 0)
    |> Map.put(:apu, %{APU.post_boot(model: :dmg) | sequencer_phase: 0x0B00})
    |> Bus.write(0xFF40, 0x91)
  end

  defp post_boot_bus(bus, :cgb) do
    bus
    |> Map.put(:divider, 0)
    |> Map.put(:joyp_select, 0)
    |> Map.put(:serial_data, 0)
    |> Map.put(:serial_control, 0x03)
    |> Map.put(:interrupt_flags, 0x01)
    |> Map.put(:ie, 0)
    |> Map.put(:svbk, 0)
    |> Map.put(:hdma, {0xFF, 0xF0, 0x1F, 0xF0, 0xFF})
    |> Map.put(:apu, APU.post_boot(model: :cgb))
    |> Bus.write(0xFF40, 0x91)
  end
end
