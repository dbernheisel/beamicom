defmodule Beamicom.SNES.SA1 do
  @moduledoc """
  Native SA-1 cartridge memory controller and peripheral state.

  This layer implements the S-CPU-visible Super MMC windows, I-RAM/BW-RAM,
  interrupt handshakes, vectors, and the SA-1 arithmetic unit. The second
  65C816 execution scheduler and DMA/character conversion engines build on
  this state without changing the host-side mapping API.
  """

  import Bitwise
  alias Beamicom.SNES.Cartridge

  @iram_size 0x800
  @result_mask (1 <<< 40) - 1

  @enforce_keys [:iram, :bwram, :bwram_size]
  defstruct iram: nil,
            bwram: nil,
            bwram_size: 0,
            ccnt: 0x20,
            sie: 0,
            cpu_irq_flags: 0,
            sa1_irq_flags: 0,
            crv: 0,
            cnv: 0,
            civ: 0,
            snv: 0,
            siv: 0,
            banks: {0, 1, 2, 3},
            bank_modes: 0,
            sbm: 0,
            swen?: false,
            cwen?: false,
            bwp: 0x0F,
            siwp: 0,
            ciwp: 0,
            math_control: 0,
            ma: 0,
            mb: 0,
            math_result: 0,
            math_overflow?: false

  @type t :: %__MODULE__{}

  @spec cartridge?(Cartridge.t()) :: boolean()
  def cartridge?(%Cartridge{header: %{cartridge_type: type, map_mode: map_mode}}),
    do: type in [0x34, 0x35] and (map_mode &&& 0x2F) == 0x23

  @spec new(Cartridge.t()) :: t()
  def new(%Cartridge{header: %{declared_ram_size: size}}) do
    bwram_size = if is_integer(size), do: size, else: 0

    %__MODULE__{
      iram: :atomics.new(@iram_size, signed: false),
      bwram: if(bwram_size > 0, do: :atomics.new(bwram_size, signed: false), else: nil),
      bwram_size: bwram_size
    }
  end

  @spec mapped?(t(), non_neg_integer()) :: boolean()
  def mapped?(%__MODULE__{}, address),
    do: io_mapped?(address) or iram_mapped?(address) or bwram_mapped?(address)

  @spec rom_mapped?(non_neg_integer()) :: boolean()
  def rom_mapped?(address) do
    bank = address >>> 16
    offset = address &&& 0xFFFF
    ((bank in 0x00..0x3F or bank in 0x80..0xBF) and offset >= 0x8000) or bank >= 0xC0
  end

  @spec rom_byte(t(), Cartridge.t(), non_neg_integer(), byte()) :: byte()
  def rom_byte(%__MODULE__{} = sa1, %Cartridge{} = cartridge, address, default \\ 0xFF) do
    if rom_mapped?(address) do
      bank = address >>> 16
      offset = address &&& 0xFFFF

      {raw, low_window?} =
        if bank >= 0xC0 do
          {(bank - 0xC0) <<< 16 ||| offset, false}
        else
          high_half = if bank >= 0x80, do: 0x20_0000, else: 0
          {high_half + ((bank &&& 0x3F) <<< 15) + (offset &&& 0x7FFF), true}
        end

      block = raw >>> 20 &&& 3
      mode? = (sa1.bank_modes &&& 1 <<< block) != 0
      physical_block = elem(sa1.banks, block)

      physical =
        if low_window? and not mode?, do: raw, else: physical_block <<< 20 ||| (raw &&& 0xFFFFF)

      rom_at(cartridge, physical)
    else
      default
    end
  end

  @spec peek(t(), non_neg_integer(), byte()) :: byte()
  def peek(%__MODULE__{} = sa1, address, default \\ 0xFF) do
    cond do
      io_mapped?(address) -> peek_cpu_io(sa1, address, default)
      iram_mapped?(address) -> memory_get(sa1.iram, address &&& 0x7FF)
      bwram_mapped?(address) -> bwram_read(sa1, bwram_offset(sa1, address), default)
      true -> default
    end
  end

  @spec read(t(), non_neg_integer(), byte()) :: {byte(), t()}
  def read(%__MODULE__{} = sa1, address, default \\ 0xFF), do: {peek(sa1, address, default), sa1}

  @spec write(t(), non_neg_integer(), byte()) :: t()
  def write(%__MODULE__{} = sa1, address, value) do
    value = value &&& 0xFF

    cond do
      io_mapped?(address) -> write_cpu_io(sa1, address &&& 0xFFFF, value)
      iram_mapped?(address) -> write_cpu_iram(sa1, address &&& 0x7FF, value)
      bwram_mapped?(address) -> write_cpu_bwram(sa1, bwram_offset(sa1, address), value)
      true -> sa1
    end
  end

  @doc "Executes an MMIO write from the SA-1 CPU side."
  @spec write_sa1_io(t(), non_neg_integer(), byte()) :: t()
  def write_sa1_io(%__MODULE__{} = sa1, address, value) do
    register = 0x2200 ||| (address &&& 0x1FF)
    value = value &&& 0xFF

    case register do
      0x2209 ->
        flags = if (value &&& 0x80) != 0, do: sa1.cpu_irq_flags ||| 0x80, else: sa1.cpu_irq_flags
        %{sa1 | cpu_irq_flags: flags}

      0x220A ->
        %{sa1 | sa1_irq_flags: sa1.sa1_irq_flags &&& value}

      0x220B ->
        %{sa1 | sa1_irq_flags: sa1.sa1_irq_flags &&& bnot(value)}

      0x220C ->
        %{sa1 | snv: put_low(sa1.snv, value)}

      0x220D ->
        %{sa1 | snv: put_high(sa1.snv, value)}

      0x220E ->
        %{sa1 | siv: put_low(sa1.siv, value)}

      0x220F ->
        %{sa1 | siv: put_high(sa1.siv, value)}

      0x2227 ->
        %{sa1 | cwen?: (value &&& 0x80) != 0}

      0x222A ->
        %{sa1 | ciwp: value}

      0x2250 ->
        %{
          sa1
          | math_control: value &&& 3,
            math_result: if((value &&& 2) != 0, do: 0, else: sa1.math_result)
        }

      0x2251 ->
        %{sa1 | ma: put_low(sa1.ma, value)}

      0x2252 ->
        %{sa1 | ma: put_high(sa1.ma, value)}

      0x2253 ->
        %{sa1 | mb: put_low(sa1.mb, value)}

      0x2254 ->
        sa1 |> Map.put(:mb, put_high(sa1.mb, value)) |> execute_math()

      _ ->
        sa1
    end
  end

  @doc "Reads an MMIO register from the SA-1 CPU side."
  @spec read_sa1_io(t(), non_neg_integer(), byte()) :: byte()
  def read_sa1_io(%__MODULE__{} = sa1, address, default \\ 0xFF) do
    case 0x2200 ||| (address &&& 0x1FF) do
      0x2301 ->
        sa1.sa1_irq_flags

      register when register in 0x2306..0x230A ->
        sa1.math_result >>> ((register - 0x2306) * 8) &&& 0xFF

      0x230B ->
        if(sa1.math_overflow?, do: 0x80, else: 0)

      _ ->
        default
    end
  end

  @spec irq_pending?(t()) :: boolean()
  def irq_pending?(%__MODULE__{} = sa1),
    do: (sa1.cpu_irq_flags &&& sa1.sie &&& 0xA0) != 0

  defp io_mapped?(address) do
    bank = address >>> 16
    offset = address &&& 0xFFFF
    (bank in 0x00..0x3F or bank in 0x80..0xBF) and offset in 0x2200..0x23FF
  end

  defp iram_mapped?(address) do
    bank = address >>> 16
    offset = address &&& 0xFFFF
    (bank in 0x00..0x3F or bank in 0x80..0xBF) and offset in 0x3000..0x37FF
  end

  defp bwram_mapped?(address) do
    bank = address >>> 16
    offset = address &&& 0xFFFF

    bank in 0x40..0x4F or
      ((bank in 0x00..0x3F or bank in 0x80..0xBF) and offset in 0x6000..0x7FFF)
  end

  defp bwram_offset(sa1, address) do
    bank = address >>> 16

    if bank in 0x40..0x4F,
      do: (bank - 0x40) <<< 16 ||| (address &&& 0xFFFF),
      else: sa1.sbm * 0x2000 + (address &&& 0x1FFF)
  end

  defp bwram_read(%{bwram_size: 0}, _offset, default), do: default
  defp bwram_read(sa1, offset, _default), do: memory_get(sa1.bwram, rem(offset, sa1.bwram_size))

  defp write_cpu_iram(sa1, offset, value) do
    if (sa1.siwp &&& 1 <<< (offset >>> 8)) != 0, do: memory_put(sa1.iram, offset, value)
    sa1
  end

  defp write_cpu_bwram(%{bwram_size: 0} = sa1, _offset, _value), do: sa1

  defp write_cpu_bwram(sa1, offset, value) do
    protected? = not sa1.swen? and not sa1.cwen? and offset < 0x100 <<< sa1.bwp
    if not protected?, do: memory_put(sa1.bwram, rem(offset, sa1.bwram_size), value)
    sa1
  end

  defp peek_cpu_io(sa1, address, default) do
    case address &&& 0xFFFF do
      0x2300 -> (default &&& 0x0F) ||| sa1.cpu_irq_flags
      _ -> default
    end
  end

  defp write_cpu_io(sa1, register, value) do
    case register do
      0x2200 ->
        flags = if (value &&& 0x80) != 0, do: sa1.sa1_irq_flags ||| 0x80, else: sa1.sa1_irq_flags
        %{sa1 | ccnt: value, sa1_irq_flags: flags}

      0x2201 ->
        %{sa1 | sie: value &&& 0xA0}

      0x2202 ->
        %{sa1 | cpu_irq_flags: sa1.cpu_irq_flags &&& bnot(value &&& 0xA0)}

      0x2203 ->
        %{sa1 | crv: put_low(sa1.crv, value)}

      0x2204 ->
        %{sa1 | crv: put_high(sa1.crv, value)}

      0x2205 ->
        %{sa1 | cnv: put_low(sa1.cnv, value)}

      0x2206 ->
        %{sa1 | cnv: put_high(sa1.cnv, value)}

      0x2207 ->
        %{sa1 | civ: put_low(sa1.civ, value)}

      0x2208 ->
        %{sa1 | civ: put_high(sa1.civ, value)}

      register when register in 0x2220..0x2223 ->
        write_bank(sa1, register - 0x2220, value)

      0x2224 ->
        %{sa1 | sbm: value &&& 0x1F}

      0x2226 ->
        %{sa1 | swen?: (value &&& 0x80) != 0}

      0x2228 ->
        %{sa1 | bwp: value &&& 0x0F}

      0x2229 ->
        %{sa1 | siwp: value}

      _ ->
        sa1
    end
  end

  defp write_bank(sa1, block, value) do
    banks = put_elem(sa1.banks, block, value &&& 7)

    modes =
      if (value &&& 0x80) != 0,
        do: sa1.bank_modes ||| 1 <<< block,
        else: sa1.bank_modes &&& bnot(1 <<< block)

    %{sa1 | banks: banks, bank_modes: modes}
  end

  defp execute_math(%{math_control: control} = sa1) when (control &&& 2) != 0 do
    product = s16(sa1.ma) * s16(sa1.mb)
    signed = signed40(sa1.math_result) + product
    overflow? = signed < -(1 <<< 39) or signed >= 1 <<< 39
    %{sa1 | mb: 0, math_result: signed &&& @result_mask, math_overflow?: overflow?}
  end

  defp execute_math(%{math_control: control} = sa1) when (control &&& 1) == 0 do
    product = s16(sa1.ma) * s16(sa1.mb)
    %{sa1 | mb: 0, math_result: product &&& 0xFFFF_FFFF, math_overflow?: false}
  end

  defp execute_math(sa1) do
    dividend = s16(sa1.ma)
    divisor = sa1.mb &&& 0xFFFF

    result =
      if divisor == 0 do
        0
      else
        remainder = Integer.mod(dividend, divisor)
        quotient = div(dividend - remainder, divisor)
        remainder <<< 16 ||| (quotient &&& 0xFFFF)
      end

    %{sa1 | ma: 0, mb: 0, math_result: result, math_overflow?: false}
  end

  defp rom_at(%Cartridge{rom: rom, size: size}, offset) do
    offset = if offset < size, do: offset, else: Cartridge.mirror_offset(offset, size)
    :binary.at(rom, offset)
  end

  defp put_low(word, value), do: (word &&& 0xFF00) ||| value
  defp put_high(word, value), do: value <<< 8 ||| (word &&& 0x00FF)
  defp s16(value) when (value &&& 0x8000) != 0, do: (value &&& 0xFFFF) - 0x10000
  defp s16(value), do: value &&& 0xFFFF
  defp signed40(value) when (value &&& 1 <<< 39) != 0, do: value - (1 <<< 40)
  defp signed40(value), do: value
  defp memory_get(memory, index), do: :atomics.get(memory, index + 1)
  defp memory_put(memory, index, value), do: :atomics.put(memory, index + 1, value)
end
