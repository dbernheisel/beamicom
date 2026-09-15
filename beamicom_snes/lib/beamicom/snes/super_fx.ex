defmodule Beamicom.SNES.SuperFX do
  @moduledoc """
  Native implementation of the cartridge GSU used by SuperFX and SuperFX 2 games.

  The S-CPU-visible register and RAM windows are cycle-priced by `SNES.Bus`.
  GSU jobs currently execute atomically when the high byte of R15 is written;
  this preserves the observable GO/STOP/IRQ protocol while avoiding a second
  scheduler until instruction and pixel accuracy are established.
  """

  import Bitwise
  alias Beamicom.SNES.Cartridge

  @fallback_ram_size 0x8000
  @max_instructions 10_000_000
  @register_types [0x13, 0x14, 0x15, 0x1A]

  @flag_z 1 <<< 1
  @flag_cy 1 <<< 2
  @flag_s 1 <<< 3
  @flag_ov 1 <<< 4
  @flag_g 1 <<< 5
  @flag_r 1 <<< 6
  @flag_alt1 1 <<< 8
  @flag_alt2 1 <<< 9
  @flag_b 1 <<< 12
  @flag_irq 1 <<< 15
  @empty_pixel_data List.duplicate(0, 8) |> List.to_tuple()

  @enforce_keys [:regs, :ram, :ram_size, :ram_mask, :bram, :cache]
  defstruct regs: nil,
            ram: nil,
            ram_size: nil,
            ram_mask: nil,
            bram: nil,
            cache: nil,
            cache_valid: 0,
            sfr: 0,
            pbr: 0,
            rombr: 0,
            rambr: 0,
            cbr: 0,
            scbr: 0,
            scmr: 0,
            colr: 0,
            por: 0,
            pixel_cache: {{0xFFFF, 0, @empty_pixel_data}, {0xFFFF, 0, @empty_pixel_data}},
            bramr: 0,
            vcr: 0x04,
            cfgr: 0,
            clsr: 0,
            pipeline: 0x01,
            sreg: 0,
            dreg: 0,
            ramaddr: 0,
            romdr: 0,
            r14_modified?: false,
            r15_modified?: false,
            instruction_count: 0,
            job_count: 0,
            last_job_instructions: 0,
            halted_reason: nil

  @type t :: %__MODULE__{}

  @compile {:inline,
            [
              reg: 2,
              flag?: 2,
              memory_get: 2,
              memory_put: 3,
              u8: 1,
              u16: 1,
              s8: 1,
              s16: 1,
              set_flag: 3,
              source: 1,
              set_reg: 3,
              put_reg_raw: 3,
              set_dest: 2,
              reset_prefix: 1,
              logic_flags: 2,
              logic_flags: 3,
              finish_arithmetic_result: 4,
              finish_arithmetic_flags: 4,
              finish_logic_result: 2,
              finish_register_logic: 3,
              finish_merge_result: 2,
              arithmetic_sfr: 4,
              logic_sfr: 3,
              step_instruction: 2,
              peek_pipe: 2,
              pipe: 2,
              read_opcode: 3,
              update_rom_buffer: 2,
              gsu_read: 3,
              rom_at: 2,
              ram_read: 2,
              ram_write: 3,
              pack_pixel_plane: 2
            ]}

  @spec cartridge?(Cartridge.t()) :: boolean()
  def cartridge?(%Cartridge{header: %{cartridge_type: type}}), do: type in @register_types

  @spec new(Cartridge.t()) :: t()
  def new(%Cartridge{} = cartridge) do
    ram_size = expansion_ram_size(cartridge)
    ram = :atomics.new(ram_size, signed: false)
    Enum.each(0..(ram_size - 1), &memory_put(ram, &1, 0xFF))

    %__MODULE__{
      regs: List.duplicate(0, 16) |> List.to_tuple(),
      ram: ram,
      ram_size: ram_size,
      ram_mask: ram_size - 1,
      bram: ram,
      cache: :atomics.new(512, signed: false)
    }
  end

  @spec io_mapped?(non_neg_integer()) :: boolean()
  def io_mapped?(address) do
    bank = address >>> 16
    offset = address &&& 0xFFFF
    (bank in 0x00..0x3F or bank in 0x80..0xBF) and offset in 0x3000..0x32FF
  end

  @spec ram_mapped?(non_neg_integer()) :: boolean()
  def ram_mapped?(address) do
    bank = address >>> 16
    offset = address &&& 0xFFFF

    bank in 0x70..0x71 or bank in 0xF0..0xF1 or
      ((bank in 0x00..0x3F or bank in 0x80..0xBF) and offset in 0x6000..0x7FFF)
  end

  @spec cpu_rom_mapped?(non_neg_integer()) :: boolean()
  def cpu_rom_mapped?(address) do
    bank = address >>> 16
    offset = address &&& 0xFFFF

    ((bank in 0x00..0x3F or bank in 0x80..0xBF) and offset >= 0x8000) or
      bank in 0x40..0x5F or bank in 0xC0..0xDF
  end

  @spec cpu_rom_byte(Cartridge.t(), non_neg_integer(), byte()) :: byte()
  def cpu_rom_byte(%Cartridge{} = cartridge, address, default \\ 0) do
    bank = address >>> 16
    offset = address &&& 0xFFFF

    cond do
      (bank in 0x00..0x3F or bank in 0x80..0xBF) and offset >= 0x8000 ->
        rom_at(cartridge, (bank &&& 0x3F) <<< 15 ||| (offset &&& 0x7FFF))

      bank in 0x40..0x5F or bank in 0xC0..0xDF ->
        rom_at(cartridge, (bank &&& 0x1F) <<< 16 ||| offset)

      true ->
        default
    end
  end

  @spec peek(t(), non_neg_integer(), byte()) :: byte()
  def peek(%__MODULE__{} = sfx, address, default \\ 0) do
    cond do
      backup_ram_mapped?(address) -> memory_get(sfx.ram, address &&& 0x1FFF)
      work_ram_mapped?(address) -> memory_get(sfx.ram, address &&& sfx.ram_mask)
      io_mapped?(address) -> peek_io(sfx, 0x3000 ||| (address &&& 0x03FF), default)
      true -> default
    end
  end

  @spec read(t(), non_neg_integer(), byte()) :: {byte(), t()}
  def read(%__MODULE__{} = sfx, address, default \\ 0) do
    io = 0x3000 ||| (address &&& 0x03FF)
    value = peek(sfx, address, default)

    if io_mapped?(address) and io == 0x3031 do
      {value, %{sfx | sfr: sfx.sfr &&& bnot(@flag_irq)}}
    else
      {value, sfx}
    end
  end

  @spec write(t(), non_neg_integer(), byte(), Cartridge.t()) :: t()
  def write(%__MODULE__{} = sfx, address, value, %Cartridge{} = cartridge) do
    value = value &&& 0xFF

    cond do
      backup_ram_mapped?(address) ->
        memory_put(sfx.ram, address &&& 0x1FFF, value)
        sfx

      work_ram_mapped?(address) ->
        index = address &&& sfx.ram_mask
        memory_put(sfx.ram, index, value)
        sfx

      io_mapped?(address) ->
        write_io(sfx, 0x3000 ||| (address &&& 0x03FF), value, cartridge)

      true ->
        sfx
    end
  end

  @spec irq_pending?(t()) :: boolean()
  def irq_pending?(%__MODULE__{} = sfx), do: flag?(sfx, @flag_irq)

  defp backup_ram_mapped?(address) do
    bank = address >>> 16
    offset = address &&& 0xFFFF
    (bank in 0x00..0x3F or bank in 0x80..0xBF) and offset in 0x6000..0x7FFF
  end

  defp work_ram_mapped?(address),
    do: (address >>> 16) in 0x70..0x71 or (address >>> 16) in 0xF0..0xF1

  defp peek_io(sfx, address, _default) when address in 0x3100..0x32FF do
    cache_offset = address - 0x3100
    memory_get(sfx.cache, cache_offset + sfx.cbr &&& 0x1FF)
  end

  defp peek_io(sfx, address, _default) when address in 0x3000..0x301F do
    value = reg(sfx, address >>> 1 &&& 0x0F)
    value >>> ((address &&& 1) * 8) &&& 0xFF
  end

  defp peek_io(sfx, address, _default) do
    case address do
      0x3030 -> sfx.sfr &&& 0x7E
      0x3031 -> sfx.sfr >>> 8 &&& 0x9F
      0x3034 -> sfx.pbr
      0x3036 -> sfx.rombr
      0x303B -> sfx.vcr
      0x303C -> sfx.rambr
      0x303E -> sfx.cbr &&& 0xFF
      0x303F -> sfx.cbr >>> 8
      _ -> 0
    end
  end

  defp write_io(sfx, address, value, _cartridge) when address in 0x3100..0x32FF do
    cache_offset = address - 0x3100
    index = cache_offset + sfx.cbr &&& 0x1FF
    memory_put(sfx.cache, index, value)

    valid =
      if (index &&& 0x0F) == 0x0F,
        do: sfx.cache_valid ||| 1 <<< (index >>> 4),
        else: sfx.cache_valid

    %{sfx | cache_valid: valid}
  end

  defp write_io(sfx, address, value, cartridge) when address in 0x3000..0x301F do
    n = address >>> 1 &&& 0x0F
    old = reg(sfx, n)

    word =
      if((address &&& 1) == 0,
        do: (old &&& 0xFF00) ||| value,
        else: value <<< 8 ||| (old &&& 0xFF)
      )

    sfx = set_reg(sfx, n, word)
    sfx = if n == 14, do: update_rom_buffer(sfx, cartridge), else: sfx

    if address == 0x301F do
      sfx
      |> Map.put(:sfr, sfx.sfr ||| @flag_g)
      |> run_job(cartridge)
    else
      sfx
    end
  end

  defp write_io(sfx, address, value, _cartridge) do
    case address do
      0x3030 ->
        was_running? = flag?(sfx, @flag_g)
        sfr = (sfx.sfr &&& 0xFF00) ||| value
        sfx = %{sfx | sfr: sfr}

        if was_running? and not flag?(sfx, @flag_g),
          do: %{sfx | cbr: 0, cache_valid: 0},
          else: sfx

      0x3031 ->
        %{sfx | sfr: value <<< 8 ||| (sfx.sfr &&& 0x00FF)}

      0x3033 ->
        %{sfx | bramr: value &&& 1}

      0x3034 ->
        %{sfx | pbr: value &&& 0x7F, cache_valid: 0}

      0x3037 ->
        %{sfx | cfgr: value &&& 0xA0}

      0x3038 ->
        %{sfx | scbr: value}

      0x3039 ->
        %{sfx | clsr: value &&& 1}

      0x303A ->
        %{sfx | scmr: value &&& 0x3F}

      _ ->
        sfx
    end
  end

  defp run_job(sfx, cartridge) do
    instruction_count = sfx.instruction_count
    sfx = %{sfx | job_count: sfx.job_count + 1, halted_reason: nil}
    {sfx, job_instructions} = run_loop(sfx, cartridge, @max_instructions, 0)

    %{
      sfx
      | instruction_count: instruction_count + job_instructions,
        last_job_instructions: job_instructions
    }
  end

  defp run_loop(sfx, _cartridge, 0, executed) do
    {%{sfx | sfr: sfx.sfr &&& bnot(@flag_g), halted_reason: :instruction_limit}, executed}
  end

  defp run_loop(sfx, cartridge, remaining, executed) do
    if flag?(sfx, @flag_g) do
      case fast_plot_loop(sfx, cartridge, remaining) do
        {:ok, sfx, instructions} ->
          run_loop(sfx, cartridge, remaining - instructions, executed + instructions)

        :no ->
          sfx
          |> step_instruction(cartridge)
          |> run_loop(cartridge, remaining - 1, executed + 1)
      end
    else
      {sfx, executed}
    end
  end

  # Yoshi's Island and other GSU software use this pixel pipeline as a tight
  # loop. Recognize the instruction bytes, rather than a cartridge address,
  # and fold one or more iterations while preserving the branch delay slot.
  defp fast_plot_loop(sfx, cartridge, remaining) when remaining >= 8 do
    pc = reg(sfx, 15)

    cond do
      sfx.pipeline == 0x4C and
          opcode_sequence?(
            sfx,
            cartridge,
            pc,
            <<0x70, 0x1E, 0x54, 0x28, 0x65, 0xDF, 0x0A, 0xF8>>
          ) ->
        run_fast_plot_loop(
          sfx,
          cartridge,
          pc,
          remaining,
          0,
          reg(sfx, 0),
          reg(sfx, 1),
          reg(sfx, 8),
          reg(sfx, 14),
          sfx.sfr,
          sfx.colr,
          sfx.romdr,
          sfx.pixel_cache
        )

      sfx.pipeline == 0x4C and remaining >= 10 and
          opcode_sequence?(
            sfx,
            cartridge,
            pc,
            <<0x70, 0x1E, 0x54, 0x28, 0x55, 0xB3, 0x68, 0xDF, 0x0A, 0xF6>>
          ) ->
        run_fast_add_plot_loop(
          sfx,
          cartridge,
          pc,
          remaining,
          0,
          reg(sfx, 0),
          reg(sfx, 1),
          reg(sfx, 8),
          reg(sfx, 14),
          sfx.sfr,
          sfx.colr,
          sfx.romdr,
          sfx.pixel_cache
        )

      true ->
        :no
    end
  end

  defp fast_plot_loop(_sfx, _cartridge, _remaining), do: :no

  defp run_fast_plot_loop(
         sfx,
         _cartridge,
         pc,
         remaining,
         executed,
         r0,
         r1,
         r8,
         r14,
         sfr,
         colr,
         romdr,
         pixel_cache
       )
       when remaining < 8 do
    {:ok, finish_fast_plot_loop(sfx, pc, r0, r1, r8, r14, sfr, colr, romdr, pixel_cache),
     executed}
  end

  defp run_fast_plot_loop(
         sfx,
         cartridge,
         pc,
         remaining,
         executed,
         _r0,
         r1,
         r8,
         _r14,
         sfr,
         colr,
         _romdr,
         pixel_cache
       ) do
    pixel_cache = fast_plot_pixel(sfx, pixel_cache, r1, reg(sfx, 2), colr)
    merged = (reg(sfx, 7) &&& 0xFF00) ||| r8 >>> 8
    rom_address = u16(merged + reg(sfx, 4))
    romdr = gsu_read(sfx, sfx.rombr <<< 16 ||| rom_address, cartridge)
    right = reg(sfx, 5)
    result = r8 - right
    overflow? = (bxor(r8, right) &&& bxor(r8, result) &&& 0x8000) != 0

    sfr =
      arithmetic_sfr(sfr, result, overflow?, result >= 0) &&&
        bnot(@flag_b ||| @flag_alt1 ||| @flag_alt2 ||| @flag_r)

    continue? = (result &&& 0x8000) == 0
    colr = fast_color(sfx.por, colr, romdr)

    if continue? do
      run_fast_plot_loop(
        sfx,
        cartridge,
        pc,
        remaining - 8,
        executed + 8,
        merged,
        u16(r1 + 1),
        u16(result),
        rom_address,
        sfr,
        colr,
        romdr,
        pixel_cache
      )
    else
      sfx =
        finish_fast_plot_loop(
          sfx,
          pc + 9,
          merged,
          u16(r1 + 1),
          u16(result),
          rom_address,
          sfr,
          colr,
          romdr,
          pixel_cache
        )

      {:ok, sfx, executed + 8}
    end
  end

  defp run_fast_add_plot_loop(
         sfx,
         _cartridge,
         pc,
         remaining,
         executed,
         r0,
         r1,
         r8,
         r14,
         sfr,
         colr,
         romdr,
         pixel_cache
       )
       when remaining < 10 do
    {:ok, finish_fast_plot_loop(sfx, pc, r0, r1, r8, r14, sfr, colr, romdr, pixel_cache),
     executed}
  end

  defp run_fast_add_plot_loop(
         sfx,
         cartridge,
         pc,
         remaining,
         executed,
         _r0,
         r1,
         r8,
         _r14,
         sfr,
         colr,
         _romdr,
         pixel_cache
       ) do
    pixel_cache = fast_plot_pixel(sfx, pixel_cache, r1, reg(sfx, 2), colr)
    merged = (reg(sfx, 7) &&& 0xFF00) ||| r8 >>> 8
    rom_address = u16(merged + reg(sfx, 4))
    romdr = gsu_read(sfx, sfx.rombr <<< 16 ||| rom_address, cartridge)
    next_r8 = u16(r8 + reg(sfx, 5))
    left = reg(sfx, 3)
    result = left - next_r8
    overflow? = (bxor(left, next_r8) &&& bxor(left, result) &&& 0x8000) != 0

    sfr =
      arithmetic_sfr(sfr, result, overflow?, result >= 0) &&&
        bnot(@flag_b ||| @flag_alt1 ||| @flag_alt2 ||| @flag_r)

    continue? = (result &&& 0x8000) == 0
    colr = fast_color(sfx.por, colr, romdr)

    if continue? do
      run_fast_add_plot_loop(
        sfx,
        cartridge,
        pc,
        remaining - 10,
        executed + 10,
        u16(result),
        u16(r1 + 1),
        next_r8,
        rom_address,
        sfr,
        colr,
        romdr,
        pixel_cache
      )
    else
      sfx =
        finish_fast_plot_loop(
          sfx,
          pc + 11,
          u16(result),
          u16(r1 + 1),
          next_r8,
          rom_address,
          sfr,
          colr,
          romdr,
          pixel_cache
        )

      {:ok, sfx, executed + 10}
    end
  end

  defp finish_fast_plot_loop(sfx, pc, r0, r1, r8, r14, sfr, colr, romdr, pixel_cache) do
    regs =
      sfx.regs
      |> put_elem(0, r0)
      |> put_elem(1, r1)
      |> put_elem(8, r8)
      |> put_elem(14, r14)
      |> put_elem(15, u16(pc))

    %{
      sfx
      | regs: regs,
        sfr: sfr,
        colr: colr,
        romdr: romdr,
        pipeline: 0x4C,
        pixel_cache: pixel_cache,
        sreg: 0,
        dreg: 0,
        r14_modified?: false,
        r15_modified?: false
    }
  end

  defp fast_plot_pixel(sfx, pixel_cache, x, y, color) do
    transparent? = (sfx.por &&& 1) == 0
    mode = sfx.scmr &&& 3
    freeze? = (sfx.por &&& 8) != 0

    invisible? =
      transparent? and
        if(mode == 3 and not freeze?, do: color == 0, else: (color &&& 0x0F) == 0)

    if invisible? do
      pixel_cache
    else
      color =
        if (sfx.por &&& 2) != 0 and mode != 3 do
          if (bxor(x, y) &&& 1) != 0, do: color >>> 4 &&& 0x0F, else: color &&& 0x0F
        else
          color
        end

      x = x &&& 0xFF
      y = y &&& 0xFF
      offset = u16(y <<< 5 ||| x >>> 3)
      {current, pending} = pixel_cache

      {current, pending} =
        if elem(current, 0) == offset do
          {current, pending}
        else
          flush_pixel_cache(sfx, pending)
          {{offset, 0, elem(current, 2)}, current}
        end

      bit = bxor(x &&& 7, 7)
      current = {offset, elem(current, 1) ||| 1 <<< bit, put_elem(elem(current, 2), bit, color)}

      if elem(current, 1) == 0xFF do
        flush_pixel_cache(sfx, pending)
        {{offset, 0, elem(current, 2)}, current}
      else
        {current, pending}
      end
    end
  end

  defp fast_color(por, current, source) do
    cond do
      (por &&& 4) != 0 -> (current &&& 0xF0) ||| (source >>> 4 &&& 0x0F)
      (por &&& 8) != 0 -> (current &&& 0xF0) ||| (source &&& 0x0F)
      true -> source &&& 0xFF
    end
  end

  defp opcode_sequence?(sfx, cartridge, address, bytes) do
    bytes
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.all?(fn {expected, offset} ->
      opcode_at(sfx, u16(address + offset), cartridge) == expected
    end)
  end

  defp opcode_at(sfx, address, cartridge) do
    offset = u16(address - sfx.cbr)

    if offset < 512 and (sfx.cache_valid &&& 1 <<< (offset >>> 4)) != 0,
      do: memory_get(sfx.cache, offset),
      else: gsu_read(sfx, sfx.pbr <<< 16 ||| address, cartridge)
  end

  defp step_instruction(sfx, cartridge) do
    {opcode, sfx} = peek_pipe(sfx, cartridge)
    sfx = execute(sfx, opcode, cartridge)
    sfx = if sfx.r14_modified?, do: update_rom_buffer(sfx, cartridge), else: sfx

    regs =
      if sfx.r15_modified?,
        do: sfx.regs,
        else: put_elem(sfx.regs, 15, u16(reg(sfx, 15) + 1))

    %{
      sfx
      | regs: regs,
        r14_modified?: false,
        r15_modified?: false
    }
  end

  defp peek_pipe(sfx, cartridge) do
    opcode = sfx.pipeline
    {next, sfx} = read_opcode(%{sfx | r15_modified?: false}, reg(sfx, 15), cartridge)
    {opcode, %{sfx | pipeline: next, r15_modified?: false}}
  end

  defp pipe(sfx, cartridge) do
    address = u16(reg(sfx, 15) + 1)
    {next, sfx} = read_opcode(put_reg_raw(sfx, 15, address), address, cartridge)
    {sfx.pipeline, %{sfx | pipeline: next, r15_modified?: false}}
  end

  defp read_opcode(sfx, address, cartridge) do
    offset = u16(address - sfx.cbr)

    if offset < 512 do
      line = offset >>> 4

      sfx =
        if (sfx.cache_valid &&& 1 <<< line) == 0 do
          base = offset &&& 0x1F0

          Enum.each(0..15, fn n ->
            byte = gsu_read(sfx, sfx.pbr <<< 16 ||| u16(sfx.cbr + base + n), cartridge)
            memory_put(sfx.cache, base + n, byte)
          end)

          %{sfx | cache_valid: sfx.cache_valid ||| 1 <<< line}
        else
          sfx
        end

      {memory_get(sfx.cache, offset), sfx}
    else
      {gsu_read(sfx, sfx.pbr <<< 16 ||| address, cartridge), sfx}
    end
  end

  defp execute(sfx, opcode, cartridge) when opcode in 0x05..0x0F do
    take? =
      case opcode do
        0x05 -> true
        0x06 -> flag?(sfx, @flag_s) == flag?(sfx, @flag_ov)
        0x07 -> flag?(sfx, @flag_s) != flag?(sfx, @flag_ov)
        0x08 -> not flag?(sfx, @flag_z)
        0x09 -> flag?(sfx, @flag_z)
        0x0A -> not flag?(sfx, @flag_s)
        0x0B -> flag?(sfx, @flag_s)
        0x0C -> not flag?(sfx, @flag_cy)
        0x0D -> flag?(sfx, @flag_cy)
        0x0E -> not flag?(sfx, @flag_ov)
        0x0F -> flag?(sfx, @flag_ov)
      end

    {displacement, sfx} = pipe(sfx, cartridge)
    if take?, do: set_reg(sfx, 15, reg(sfx, 15) + s8(displacement)), else: sfx
  end

  defp execute(sfx, opcode, _cartridge) when opcode in 0x10..0x1F do
    n = opcode &&& 0x0F

    if flag?(sfx, @flag_b) do
      sfx |> set_reg(n, source(sfx)) |> reset_prefix()
    else
      %{sfx | dreg: n}
    end
  end

  defp execute(sfx, opcode, _cartridge) when opcode in 0x20..0x2F do
    n = opcode &&& 0x0F
    %{sfx | sreg: n, dreg: n, sfr: sfx.sfr ||| @flag_b}
  end

  defp execute(sfx, opcode, _cartridge) when opcode in 0x30..0x3B do
    address = reg(sfx, opcode &&& 0x0F)
    sfx = ram_write(sfx, address, source(sfx))

    sfx =
      if flag?(sfx, @flag_alt1),
        do: sfx,
        else: ram_write(sfx, bxor(address, 1), source(sfx) >>> 8)

    reset_prefix(%{sfx | ramaddr: address})
  end

  defp execute(sfx, opcode, _cartridge) when opcode in 0x40..0x4B do
    address = reg(sfx, opcode &&& 0x0F)
    value = ram_read(sfx, address)

    value =
      if flag?(sfx, @flag_alt1),
        do: value,
        else: value ||| ram_read(sfx, bxor(address, 1)) <<< 8

    sfx |> set_dest(value) |> Map.put(:ramaddr, address) |> reset_prefix()
  end

  defp execute(sfx, opcode, _cartridge) when opcode in 0x50..0x5F do
    n = if flag?(sfx, @flag_alt2), do: opcode &&& 0x0F, else: reg(sfx, opcode &&& 0x0F)
    carry = if flag?(sfx, @flag_alt1) and flag?(sfx, @flag_cy), do: 1, else: 0
    a = source(sfx)
    result = a + n + carry
    overflow? = (bnot(bxor(a, n)) &&& bxor(n, result) &&& 0x8000) != 0

    finish_arithmetic_result(sfx, result, overflow?, result >= 0x10000)
  end

  defp execute(sfx, opcode, _cartridge) when opcode in 0x60..0x6F do
    alt1? = flag?(sfx, @flag_alt1)
    alt2? = flag?(sfx, @flag_alt2)
    n = if not alt2? or alt1?, do: reg(sfx, opcode &&& 0x0F), else: opcode &&& 0x0F
    borrow = if not alt2? and alt1? and not flag?(sfx, @flag_cy), do: 1, else: 0
    a = source(sfx)
    result = a - n - borrow
    overflow? = (bxor(a, n) &&& bxor(a, result) &&& 0x8000) != 0

    if not alt2? or not alt1?,
      do: finish_arithmetic_result(sfx, result, overflow?, result >= 0),
      else: finish_arithmetic_flags(sfx, result, overflow?, result >= 0)
  end

  defp execute(sfx, opcode, _cartridge) when opcode in 0x71..0x7F do
    n = if flag?(sfx, @flag_alt2), do: opcode &&& 0x0F, else: reg(sfx, opcode &&& 0x0F)
    value = source(sfx) &&& if(flag?(sfx, @flag_alt1), do: bnot(n), else: n)
    finish_logic_result(sfx, value)
  end

  defp execute(sfx, opcode, _cartridge) when opcode in 0x80..0x8F do
    n = if flag?(sfx, @flag_alt2), do: opcode &&& 0x0F, else: reg(sfx, opcode &&& 0x0F)

    value =
      if flag?(sfx, @flag_alt1),
        do: (source(sfx) &&& 0xFF) * (n &&& 0xFF),
        else: s8(source(sfx)) * s8(n)

    finish_logic_result(sfx, value)
  end

  defp execute(sfx, opcode, _cartridge) when opcode in 0x91..0x94 do
    sfx |> set_reg(11, reg(sfx, 15) + (opcode &&& 0x0F)) |> reset_prefix()
  end

  defp execute(sfx, opcode, _cartridge) when opcode in 0x98..0x9D do
    n = opcode &&& 0x0F

    if flag?(sfx, @flag_alt1) do
      %{sfx | pbr: reg(sfx, n) &&& 0x7F, cbr: source(sfx) &&& 0xFFF0, cache_valid: 0}
      |> set_reg(15, source(sfx))
      |> reset_prefix()
    else
      sfx |> set_reg(15, reg(sfx, n)) |> reset_prefix()
    end
  end

  defp execute(sfx, opcode, cartridge) when opcode in 0xA0..0xAF do
    n = opcode &&& 0x0F

    cond do
      flag?(sfx, @flag_alt1) ->
        {address, sfx} = pipe(sfx, cartridge)
        address = address <<< 1
        value = ram_read(sfx, address) ||| ram_read(sfx, bxor(address, 1)) <<< 8
        sfx |> set_reg(n, value) |> Map.put(:ramaddr, address) |> reset_prefix()

      flag?(sfx, @flag_alt2) ->
        {address, sfx} = pipe(sfx, cartridge)
        address = address <<< 1
        sfx = ram_write(sfx, address, reg(sfx, n))
        sfx = ram_write(sfx, bxor(address, 1), reg(sfx, n) >>> 8)
        reset_prefix(%{sfx | ramaddr: address})

      true ->
        {value, sfx} = pipe(sfx, cartridge)
        sfx |> set_reg(n, s8(value)) |> reset_prefix()
    end
  end

  defp execute(sfx, opcode, _cartridge) when opcode in 0xB0..0xBF do
    n = opcode &&& 0x0F

    if flag?(sfx, @flag_b) do
      value = reg(sfx, n)
      sfx = sfx |> set_dest(value) |> set_flag(@flag_ov, (value &&& 0x80) != 0)
      sfx |> logic_flags(value) |> reset_prefix()
    else
      %{sfx | sreg: n}
    end
  end

  defp execute(sfx, opcode, _cartridge) when opcode in 0xC1..0xCF do
    n = if flag?(sfx, @flag_alt2), do: opcode &&& 0x0F, else: reg(sfx, opcode &&& 0x0F)
    value = if flag?(sfx, @flag_alt1), do: bxor(source(sfx), n), else: source(sfx) ||| n
    finish_logic_result(sfx, value)
  end

  defp execute(sfx, opcode, _cartridge) when opcode in 0xD0..0xDE do
    n = opcode &&& 0x0F
    value = reg(sfx, n) + 1
    finish_register_logic(sfx, n, value)
  end

  defp execute(sfx, opcode, _cartridge) when opcode in 0xE0..0xEE do
    n = opcode &&& 0x0F
    value = reg(sfx, n) - 1
    finish_register_logic(sfx, n, value)
  end

  defp execute(sfx, opcode, cartridge) when opcode in 0xF0..0xFF do
    n = opcode &&& 0x0F

    cond do
      flag?(sfx, @flag_alt1) ->
        {low, sfx} = pipe(sfx, cartridge)
        {high, sfx} = pipe(sfx, cartridge)
        address = low ||| high <<< 8
        value = ram_read(sfx, address) ||| ram_read(sfx, bxor(address, 1)) <<< 8
        sfx |> set_reg(n, value) |> Map.put(:ramaddr, address) |> reset_prefix()

      flag?(sfx, @flag_alt2) ->
        {low, sfx} = pipe(sfx, cartridge)
        {high, sfx} = pipe(sfx, cartridge)
        address = low ||| high <<< 8
        sfx = ram_write(sfx, address, reg(sfx, n))
        sfx = ram_write(sfx, bxor(address, 1), reg(sfx, n) >>> 8)
        reset_prefix(%{sfx | ramaddr: address})

      true ->
        {low, sfx} = pipe(sfx, cartridge)
        {high, sfx} = pipe(sfx, cartridge)
        sfx |> set_reg(n, low ||| high <<< 8) |> reset_prefix()
    end
  end

  defp execute(sfx, opcode, _cartridge) do
    case opcode do
      0x00 ->
        irq = if (sfx.cfgr &&& 0x80) == 0, do: @flag_irq, else: 0
        %{reset_prefix(sfx) | sfr: (sfx.sfr &&& bnot(@flag_g)) ||| irq, pipeline: 0x01}

      0x01 ->
        reset_prefix(sfx)

      0x02 ->
        cache(sfx)

      0x03 ->
        logical_shift_right(sfx)

      0x04 ->
        rotate_left(sfx)

      0x3C ->
        value = u16(reg(sfx, 12) - 1)
        sfx = sfx |> set_reg(12, value) |> logic_flags(value)
        sfx = if value != 0, do: set_reg(sfx, 15, reg(sfx, 13)), else: sfx
        reset_prefix(sfx)

      0x3D ->
        %{sfx | sfr: (sfx.sfr &&& bnot(@flag_b)) ||| @flag_alt1}

      0x3E ->
        %{sfx | sfr: (sfx.sfr &&& bnot(@flag_b)) ||| @flag_alt2}

      0x3F ->
        %{sfx | sfr: (sfx.sfr &&& bnot(@flag_b)) ||| @flag_alt1 ||| @flag_alt2}

      0x4C ->
        if flag?(sfx, @flag_alt1) do
          {value, sfx} = read_pixel(sfx, reg(sfx, 1), reg(sfx, 2))
          finish_logic_result(sfx, value)
        else
          x = reg(sfx, 1)
          sfx = plot_pixel(sfx, x, reg(sfx, 2))

          %{
            sfx
            | regs: put_elem(sfx.regs, 1, u16(x + 1)),
              sfr: sfx.sfr &&& bnot(@flag_b ||| @flag_alt1 ||| @flag_alt2),
              sreg: 0,
              dreg: 0
          }
        end

      0x4D ->
        value = source(sfx) >>> 8 ||| source(sfx) <<< 8
        sfx |> set_dest(value) |> logic_flags(value) |> reset_prefix()

      0x4E ->
        if flag?(sfx, @flag_alt1) do
          reset_prefix(%{sfx | por: source(sfx) &&& 0x1F})
        else
          reset_prefix(%{sfx | colr: color(sfx, source(sfx))})
        end

      0x4F ->
        value = bnot(source(sfx))
        sfx |> set_dest(value) |> logic_flags(value) |> reset_prefix()

      0x70 ->
        value = (reg(sfx, 7) &&& 0xFF00) ||| reg(sfx, 8) >>> 8
        finish_merge_result(sfx, value)

      0x90 ->
        sfx
        |> ram_write(sfx.ramaddr, source(sfx))
        |> ram_write(bxor(sfx.ramaddr, 1), source(sfx) >>> 8)
        |> reset_prefix()

      0x95 ->
        value = s8(source(sfx))
        sfx |> set_dest(value) |> logic_flags(value) |> reset_prefix()

      0x96 ->
        arithmetic_shift_right(sfx, flag?(sfx, @flag_alt1))

      0x97 ->
        rotate_right(sfx)

      0x9E ->
        value = source(sfx) &&& 0xFF
        sfx |> set_dest(value) |> logic_flags(value, 0x80) |> reset_prefix()

      0x9F ->
        product = s16(source(sfx)) * s16(reg(sfx, 6))
        sfx = if flag?(sfx, @flag_alt1), do: set_reg(sfx, 4, product), else: sfx
        value = product >>> 16

        sfx
        |> set_dest(value)
        |> set_flag(@flag_cy, (product &&& 0x8000) != 0)
        |> logic_flags(value)
        |> reset_prefix()

      0xC0 ->
        value = source(sfx) >>> 8
        sfx |> set_dest(value) |> logic_flags(value, 0x80) |> reset_prefix()

      0xDF ->
        getc_ramb_romb(sfx)

      0xEF ->
        getb(sfx)
    end
  end

  defp cache(sfx) do
    cbr = reg(sfx, 15) &&& 0xFFF0

    if cbr == sfx.cbr,
      do: reset_prefix(sfx),
      else: reset_prefix(%{sfx | cbr: cbr, cache_valid: 0})
  end

  defp logical_shift_right(sfx) do
    source = source(sfx)
    value = source >>> 1

    sfx
    |> set_dest(value)
    |> set_flag(@flag_cy, (source &&& 1) != 0)
    |> logic_flags(value)
    |> reset_prefix()
  end

  defp arithmetic_shift_right(sfx, divide?) do
    source = source(sfx)
    value = s16(source) >>> 1
    value = if divide?, do: value + ((source + 1) >>> 16), else: value

    sfx
    |> set_dest(value)
    |> set_flag(@flag_cy, (source &&& 1) != 0)
    |> logic_flags(value)
    |> reset_prefix()
  end

  defp rotate_left(sfx) do
    source = source(sfx)
    value = source <<< 1 ||| if(flag?(sfx, @flag_cy), do: 1, else: 0)

    sfx
    |> set_dest(value)
    |> set_flag(@flag_cy, (source &&& 0x8000) != 0)
    |> logic_flags(value)
    |> reset_prefix()
  end

  defp rotate_right(sfx) do
    source = source(sfx)
    value = source >>> 1 ||| if(flag?(sfx, @flag_cy), do: 0x8000, else: 0)

    sfx
    |> set_dest(value)
    |> set_flag(@flag_cy, (source &&& 1) != 0)
    |> logic_flags(value)
    |> reset_prefix()
  end

  defp getc_ramb_romb(sfx) do
    sfr = sfx.sfr &&& bnot(@flag_b ||| @flag_alt1 ||| @flag_alt2)

    cond do
      not flag?(sfx, @flag_alt2) ->
        %{sfx | colr: color(sfx, sfx.romdr), sfr: sfr, sreg: 0, dreg: 0}

      not flag?(sfx, @flag_alt1) ->
        %{sfx | rambr: source(sfx) &&& 1, sfr: sfr, sreg: 0, dreg: 0}

      true ->
        %{sfx | rombr: source(sfx) &&& 0x7F, sfr: sfr, sreg: 0, dreg: 0}
    end
  end

  defp getb(sfx) do
    value =
      case {flag?(sfx, @flag_alt2), flag?(sfx, @flag_alt1)} do
        {false, false} -> sfx.romdr
        {false, true} -> sfx.romdr <<< 8 ||| (source(sfx) &&& 0xFF)
        {true, false} -> (source(sfx) &&& 0xFF00) ||| sfx.romdr
        {true, true} -> s8(sfx.romdr)
      end

    sfx |> set_dest(value) |> reset_prefix()
  end

  defp update_rom_buffer(sfx, cartridge) do
    value = gsu_read(sfx, sfx.rombr <<< 16 ||| reg(sfx, 14), cartridge)
    %{sfx | romdr: value, sfr: sfx.sfr &&& bnot(@flag_r), r14_modified?: false}
  end

  defp gsu_read(sfx, address, cartridge) do
    bank = address >>> 16 &&& 0xFF
    offset = address &&& 0xFFFF

    cond do
      bank <= 0x3F -> rom_at(cartridge, (bank &&& 0x3F) <<< 15 ||| (offset &&& 0x7FFF))
      bank <= 0x5F -> rom_at(cartridge, address &&& 0x3FFFFF)
      bank in 0x70..0x71 -> memory_get(sfx.ram, address &&& sfx.ram_mask)
      true -> 0
    end
  end

  defp rom_at(%Cartridge{rom: rom, size: size}, offset) do
    offset = if offset < size, do: offset, else: Cartridge.mirror_offset(offset, size)
    :binary.at(rom, offset)
  end

  defp ram_read(sfx, address),
    do: memory_get(sfx.ram, (sfx.rambr <<< 16 ||| u16(address)) &&& sfx.ram_mask)

  defp ram_write(sfx, address, value) do
    index = (sfx.rambr <<< 16 ||| u16(address)) &&& sfx.ram_mask
    memory_put(sfx.ram, index, u8(value))
    sfx
  end

  defp plot_pixel(sfx, x, y) do
    color = sfx.colr
    transparent? = (sfx.por &&& 1) == 0
    mode = sfx.scmr &&& 3
    freeze? = (sfx.por &&& 8) != 0

    invisible? =
      transparent? and
        if(mode == 3 and not freeze?, do: color == 0, else: (color &&& 0x0F) == 0)

    if invisible? do
      sfx
    else
      color =
        if (sfx.por &&& 2) != 0 and mode != 3 do
          if (bxor(x, y) &&& 1) != 0, do: color >>> 4 &&& 0x0F, else: color &&& 0x0F
        else
          color
        end

      x = x &&& 0xFF
      y = y &&& 0xFF
      offset = u16(y <<< 5 ||| x >>> 3)
      {current, pending} = sfx.pixel_cache

      {sfx, current, pending} =
        if elem(current, 0) == offset do
          {sfx, current, pending}
        else
          sfx = flush_pixel_cache(sfx, pending)
          {sfx, {offset, 0, elem(current, 2)}, current}
        end

      bit = bxor(x &&& 7, 7)
      current = {offset, elem(current, 1) ||| 1 <<< bit, put_elem(elem(current, 2), bit, color)}

      if elem(current, 1) == 0xFF do
        sfx = flush_pixel_cache(sfx, pending)
        %{sfx | pixel_cache: {{offset, 0, elem(current, 2)}, current}}
      else
        %{sfx | pixel_cache: {current, pending}}
      end
    end
  end

  defp read_pixel(sfx, x, y) do
    {current, pending} = sfx.pixel_cache
    sfx = sfx |> flush_pixel_cache(pending) |> flush_pixel_cache(current)
    sfx = %{sfx | pixel_cache: {put_elem(current, 1, 0), put_elem(pending, 1, 0)}}
    {base, bit, bpp} = pixel_address(sfx, x, y)

    value =
      Enum.reduce(0..(bpp - 1), 0, fn plane, color ->
        address = base + (plane >>> 1) * 16 + (plane &&& 1)
        if (pixel_ram_read(sfx, address) &&& bit) != 0, do: color ||| 1 <<< plane, else: color
      end)

    {value, sfx}
  end

  defp flush_pixel_cache(sfx, {_offset, 0, _data}), do: sfx

  defp flush_pixel_cache(sfx, {offset, bitpend, pixels}) do
    x = u8(offset <<< 3)
    y = u8(offset >>> 5)
    {base, _bit, bpp} = pixel_address(sfx, x, y)

    flush_pixel_planes(sfx, base, bitpend, pixels, 0, bpp)
  end

  defp flush_pixel_planes(sfx, _base, _bitpend, _pixels, plane, plane), do: sfx

  defp flush_pixel_planes(sfx, base, bitpend, pixels, plane, bpp) do
    address = base + (plane >>> 1) * 16 + (plane &&& 1)
    data = pack_pixel_plane(pixels, plane)

    data =
      if bitpend == 0xFF,
        do: data,
        else: (data &&& bitpend) ||| (pixel_ram_read(sfx, address) &&& bnot(bitpend))

    pixel_ram_write(sfx, address, data)
    flush_pixel_planes(sfx, base, bitpend, pixels, plane + 1, bpp)
  end

  defp pack_pixel_plane(pixels, plane) do
    (elem(pixels, 0) >>> plane &&& 1) |||
      (elem(pixels, 1) >>> plane &&& 1) <<< 1 |||
      (elem(pixels, 2) >>> plane &&& 1) <<< 2 |||
      (elem(pixels, 3) >>> plane &&& 1) <<< 3 |||
      (elem(pixels, 4) >>> plane &&& 1) <<< 4 |||
      (elem(pixels, 5) >>> plane &&& 1) <<< 5 |||
      (elem(pixels, 6) >>> plane &&& 1) <<< 6 |||
      (elem(pixels, 7) >>> plane &&& 1) <<< 7
  end

  # PLOT/RPIX form a full $70xxxx address from SCBR and the pixel coordinates.
  # RAMBR only affects LD/ST and the explicit RAM buffer instructions.
  defp pixel_ram_read(sfx, address), do: memory_get(sfx.ram, address &&& sfx.ram_mask)

  defp pixel_ram_write(sfx, address, value) do
    index = address &&& sfx.ram_mask
    memory_put(sfx.ram, index, u8(value))
    sfx
  end

  # Expanded-header byte $FFBD describes the GSU's Game Pak RAM as 1 << N
  # KiB. Early SuperFX cartridges omit the expanded header but still provide
  # 32 KiB, which is also the safest fallback for homebrew images.
  defp expansion_ram_size(%Cartridge{rom: rom, header: header}) do
    code_offset = header.offset - 3

    if header.developer_id == 0x33 and code_offset >= 0 and code_offset < byte_size(rom) do
      case :binary.at(rom, code_offset) &&& 0x07 do
        0 -> @fallback_ram_size
        code -> 1024 <<< code
      end
    else
      @fallback_ram_size
    end
  end

  defp pixel_address(sfx, x, y) do
    x = x &&& 0xFF
    y = y &&& 0xFF
    height = (sfx.scmr >>> 2 &&& 1) ||| (sfx.scmr >>> 4 &&& 2)
    height = if (sfx.por &&& 0x10) != 0, do: 3, else: height

    character =
      case height do
        0 ->
          ((x &&& 0xF8) <<< 1) + ((y &&& 0xF8) >>> 3)

        1 ->
          ((x &&& 0xF8) <<< 1) + ((x &&& 0xF8) >>> 1) + ((y &&& 0xF8) >>> 3)

        2 ->
          ((x &&& 0xF8) <<< 1) + (x &&& 0xF8) + ((y &&& 0xF8) >>> 3)

        3 ->
          ((y &&& 0x80) <<< 2) + ((x &&& 0x80) <<< 1) + ((y &&& 0x78) <<< 1) +
            ((x &&& 0x78) >>> 3)
      end

    bpp = elem({2, 4, 4, 8}, sfx.scmr &&& 3)
    base = character * bpp * 8 + sfx.scbr * 1024 + (y &&& 7) * 2
    {base, 1 <<< (7 - (x &&& 7)), bpp}
  end

  defp color(sfx, source) do
    cond do
      (sfx.por &&& 4) != 0 -> (sfx.colr &&& 0xF0) ||| (source >>> 4 &&& 0x0F)
      (sfx.por &&& 8) != 0 -> (sfx.colr &&& 0xF0) ||| (source &&& 0x0F)
      true -> source &&& 0xFF
    end
  end

  defp finish_arithmetic_result(sfx, result, overflow?, carry?) do
    n = sfx.dreg

    %{
      sfx
      | regs: put_elem(sfx.regs, n, u16(result)),
        sfr:
          arithmetic_sfr(sfx.sfr, result, overflow?, carry?) &&&
            bnot(@flag_b ||| @flag_alt1 ||| @flag_alt2),
        sreg: 0,
        dreg: 0,
        r14_modified?: sfx.r14_modified? or n == 14,
        r15_modified?: sfx.r15_modified? or n == 15
    }
  end

  defp finish_arithmetic_flags(sfx, result, overflow?, carry?) do
    %{
      sfx
      | sfr:
          arithmetic_sfr(sfx.sfr, result, overflow?, carry?) &&&
            bnot(@flag_b ||| @flag_alt1 ||| @flag_alt2),
        sreg: 0,
        dreg: 0
    }
  end

  defp finish_logic_result(sfx, value) do
    n = sfx.dreg

    %{
      sfx
      | regs: put_elem(sfx.regs, n, u16(value)),
        sfr: logic_sfr(sfx.sfr, value, 0x8000) &&& bnot(@flag_b ||| @flag_alt1 ||| @flag_alt2),
        sreg: 0,
        dreg: 0,
        r14_modified?: sfx.r14_modified? or n == 14,
        r15_modified?: sfx.r15_modified? or n == 15
    }
  end

  defp finish_register_logic(sfx, n, value) do
    %{
      sfx
      | regs: put_elem(sfx.regs, n, u16(value)),
        sfr: logic_sfr(sfx.sfr, value, 0x8000) &&& bnot(@flag_b ||| @flag_alt1 ||| @flag_alt2),
        sreg: 0,
        dreg: 0,
        r14_modified?: sfx.r14_modified? or n == 14,
        r15_modified?: sfx.r15_modified? or n == 15
    }
  end

  defp finish_merge_result(sfx, value) do
    n = sfx.dreg
    cleared = sfx.sfr &&& bnot(@flag_ov ||| @flag_s ||| @flag_cy ||| @flag_z)
    sfr = if (value &&& 0xC0C0) != 0, do: cleared ||| @flag_ov, else: cleared
    sfr = if (value &&& 0x8080) != 0, do: sfr ||| @flag_s, else: sfr
    sfr = if (value &&& 0xE0E0) != 0, do: sfr ||| @flag_cy, else: sfr
    sfr = if (value &&& 0xF0F0) != 0, do: sfr ||| @flag_z, else: sfr

    %{
      sfx
      | regs: put_elem(sfx.regs, n, value),
        sfr: sfr &&& bnot(@flag_b ||| @flag_alt1 ||| @flag_alt2),
        sreg: 0,
        dreg: 0,
        r14_modified?: sfx.r14_modified? or n == 14,
        r15_modified?: sfx.r15_modified? or n == 15
    }
  end

  defp arithmetic_sfr(sfr, result, overflow?, carry?) do
    sfr = sfr &&& bnot(@flag_ov ||| @flag_s ||| @flag_cy ||| @flag_z)
    sfr = if overflow?, do: sfr ||| @flag_ov, else: sfr
    sfr = if (result &&& 0x8000) != 0, do: sfr ||| @flag_s, else: sfr
    sfr = if carry?, do: sfr ||| @flag_cy, else: sfr
    if u16(result) == 0, do: sfr ||| @flag_z, else: sfr
  end

  defp logic_sfr(sfr, value, sign_mask) do
    sfr = sfr &&& bnot(@flag_s ||| @flag_z)
    sfr = if (value &&& sign_mask) != 0, do: sfr ||| @flag_s, else: sfr
    if u16(value) == 0, do: sfr ||| @flag_z, else: sfr
  end

  defp logic_flags(sfx, value, sign_mask \\ 0x8000) do
    %{sfx | sfr: logic_sfr(sfx.sfr, value, sign_mask)}
  end

  defp reset_prefix(sfx),
    do: %{sfx | sfr: sfx.sfr &&& bnot(@flag_b ||| @flag_alt1 ||| @flag_alt2), sreg: 0, dreg: 0}

  defp set_dest(sfx, value), do: set_reg(sfx, sfx.dreg, value)
  defp source(sfx), do: reg(sfx, sfx.sreg)
  defp reg(sfx, n), do: elem(sfx.regs, n)

  defp set_reg(sfx, n, value) do
    sfx = %{sfx | regs: put_elem(sfx.regs, n, u16(value))}

    case n do
      14 -> %{sfx | r14_modified?: true}
      15 -> %{sfx | r15_modified?: true}
      _ -> sfx
    end
  end

  defp put_reg_raw(sfx, n, value), do: %{sfx | regs: put_elem(sfx.regs, n, u16(value))}
  defp flag?(sfx, mask), do: (sfx.sfr &&& mask) != 0

  defp set_flag(sfx, mask, true), do: %{sfx | sfr: sfx.sfr ||| mask}
  defp set_flag(sfx, mask, false), do: %{sfx | sfr: sfx.sfr &&& bnot(mask)}

  defp u8(value), do: value &&& 0xFF
  defp u16(value), do: value &&& 0xFFFF
  defp s8(value) when (value &&& 0x80) != 0, do: (value &&& 0xFF) - 0x100
  defp s8(value), do: value &&& 0xFF
  defp s16(value) when (value &&& 0x8000) != 0, do: (value &&& 0xFFFF) - 0x10000
  defp s16(value), do: value &&& 0xFFFF

  defp memory_get(memory, index), do: :atomics.get(memory, index + 1)
  defp memory_put(memory, index, value), do: :atomics.put(memory, index + 1, value)
end
