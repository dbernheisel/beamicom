defmodule Beamicom.SNES.Cx4 do
  @moduledoc """
  Capcom Cx4 cartridge coprocessor state and high-level command interface.

  The host-visible window is mirrored into banks `$00-$3f` and `$80-$bf` at
  `$6000-$7fff`. Commands execute synchronously for now, so the busy register
  reads as zero after every CPU access.
  """

  import Bitwise
  alias Beamicom.SNES.Cartridge

  @ram_size 0x2000
  @command_offset 0x1F4F
  @mode_offset 0x1F4D
  @busy_offset 0x1F5E
  @load_offset 0x1F47
  @test_pattern <<
    0x00,
    0x00,
    0x00,
    0xFF,
    0xFF,
    0xFF,
    0x00,
    0xFF,
    0x00,
    0x00,
    0x00,
    0xFF,
    0xFF,
    0xFF,
    0x00,
    0x00,
    0xFF,
    0xFF,
    0x00,
    0x00,
    0x80,
    0xFF,
    0xFF,
    0x7F,
    0x00,
    0x80,
    0x00,
    0xFF,
    0x7F,
    0x00,
    0xFF,
    0x7F,
    0xFF,
    0x7F,
    0xFF,
    0xFF,
    0x00,
    0x00,
    0x01,
    0xFF,
    0xFF,
    0xFE,
    0x00,
    0x01,
    0x00,
    0xFF,
    0xFE,
    0x00
  >>

  @enforce_keys [:ram]
  defstruct ram: nil,
            command_counts: %{},
            unknown_commands: MapSet.new(),
            load_count: 0,
            last_command: nil

  @type t :: %__MODULE__{}

  @spec new() :: t()
  def new, do: %__MODULE__{ram: :array.new(@ram_size, default: 0, fixed: true)}

  @spec cartridge?(Cartridge.t()) :: boolean()
  def cartridge?(%Cartridge{header: %{cartridge_type: 0xF3}}), do: true
  def cartridge?(%Cartridge{}), do: false

  @spec mapped?(non_neg_integer()) :: boolean()
  def mapped?(address) do
    bank = address >>> 16
    offset = address &&& 0xFFFF
    (bank in 0x00..0x3F or bank in 0x80..0xBF) and offset in 0x6000..0x7FFF
  end

  @spec read(t(), non_neg_integer()) :: byte()
  def read(%__MODULE__{} = cx4, address) do
    offset = ram_offset(address)
    if offset == @busy_offset, do: 0, else: :array.get(offset, cx4.ram)
  end

  @spec write(t(), non_neg_integer(), byte(), Cartridge.t()) :: t()
  def write(%__MODULE__{} = cx4, address, value, %Cartridge{} = cartridge) do
    offset = ram_offset(address)
    cx4 = %{cx4 | ram: :array.set(offset, value &&& 0xFF, cx4.ram)}

    case offset do
      @load_offset -> load_memory(cx4, cartridge)
      @command_offset -> execute(cx4, value &&& 0xFF, cartridge)
      _ -> cx4
    end
  end

  defp load_memory(cx4, cartridge) do
    source = unsigned(cx4, 0x1F40, 3)
    length = unsigned(cx4, 0x1F43, 2)
    destination = unsigned(cx4, 0x1F45, 2) &&& 0x1FFF

    ram =
      if length == 0 do
        cx4.ram
      else
        Enum.reduce(0..(length - 1), cx4.ram, fn index, ram ->
          value = Cartridge.read_or(cartridge, source + index &&& 0xFFFFFF, 0xFF)
          :array.set(destination + index &&& 0x1FFF, value, ram)
        end)
      end

    %{cx4 | ram: ram, load_count: cx4.load_count + 1}
  end

  defp execute(cx4, command, cartridge) do
    count = Map.get(cx4.command_counts, command, 0) + 1

    cx4 = %{
      cx4
      | command_counts: Map.put(cx4.command_counts, command, count),
        last_command: command
    }

    mode = unsigned(cx4, @mode_offset, 1)

    cond do
      mode == 0x0E and command < 0x40 and (command &&& 3) == 0 ->
        put_unsigned(cx4, 0x1F80, command >>> 2, 1)

      command == 0x00 ->
        execute_sprite(cx4, mode, cartridge)

      true ->
        execute_command(cx4, command)
    end
  end

  defp execute_sprite(cx4, 0x00, cartridge), do: build_oam(cx4, cartridge)

  defp execute_sprite(cx4, _mode, _cartridge) do
    %{cx4 | unknown_commands: MapSet.put(cx4.unknown_commands, 0x00)}
  end

  defp build_oam(cx4, cartridge) do
    first_sprite = unsigned(cx4, 0x626, 1)
    first_oam_offset = first_sprite * 4
    ram = clear_oam_y(cx4.ram, 0x1FD, first_oam_offset)
    object_count = :array.get(0x620, ram)

    ram =
      if object_count == 0 or first_sprite >= 128 do
        ram
      else
        global_x = array_unsigned(ram, 0x621, 2)
        global_y = array_unsigned(ram, 0x623, 2)

        state = %{
          ram: ram,
          oam_offset: first_oam_offset,
          high_offset: 0x200 + (first_sprite >>> 2),
          high_shift: (first_sprite &&& 3) * 2,
          remaining: 128 - first_sprite
        }

        process_objects(state, cartridge, object_count, 0x220, global_x, global_y).ram
      end

    %{cx4 | ram: ram}
  end

  defp clear_oam_y(ram, offset, first_oam_offset) when offset > first_oam_offset do
    ram
    |> then(&:array.set(offset, 0xE0, &1))
    |> clear_oam_y(offset - 4, first_oam_offset)
  end

  defp clear_oam_y(ram, _offset, _first_oam_offset), do: ram

  defp process_objects(state, _cartridge, 0, _source, _global_x, _global_y), do: state
  defp process_objects(%{remaining: 0} = state, _cartridge, _count, _source, _x, _y), do: state

  defp process_objects(state, cartridge, count, source, global_x, global_y) do
    ram = state.ram
    sprite_x = signed_width(array_unsigned(ram, source, 2) - global_x, 16)
    sprite_y = signed_width(array_unsigned(ram, source + 2, 2) - global_y, 16)
    name = :array.get(source + 5, ram)
    attributes = :array.get(source + 4, ram) ||| :array.get(source + 6, ram)
    descriptor = array_unsigned(ram, source + 7, 3)
    part_count = Cartridge.read_or(cartridge, descriptor, 0)

    state =
      if part_count == 0 do
        append_oam(
          state,
          sprite_x,
          sprite_y,
          name,
          attributes,
          if((sprite_x &&& 0x100) != 0, do: 3, else: 2)
        )
      else
        process_parts(
          state,
          cartridge,
          part_count,
          descriptor + 1,
          sprite_x,
          sprite_y,
          name,
          attributes
        )
      end

    process_objects(state, cartridge, count - 1, source + 16, global_x, global_y)
  end

  defp process_parts(state, _cartridge, 0, _descriptor, _x, _y, _name, _attributes),
    do: state

  defp process_parts(
         %{remaining: 0} = state,
         _cartridge,
         _count,
         _descriptor,
         _x,
         _y,
         _name,
         _attributes
       ),
       do: state

  defp process_parts(state, cartridge, count, descriptor, sprite_x, sprite_y, name, attributes) do
    flags = Cartridge.read_or(cartridge, descriptor, 0)
    part_x = Cartridge.read_or(cartridge, descriptor + 1, 0) |> signed_width(8)
    part_y = Cartridge.read_or(cartridge, descriptor + 2, 0) |> signed_width(8)
    tile = Cartridge.read_or(cartridge, descriptor + 3, 0)
    size = if (flags &&& 0x20) != 0, do: 16, else: 8
    part_x = if (attributes &&& 0x40) != 0, do: -part_x - size, else: part_x
    part_y = if (attributes &&& 0x80) != 0, do: -part_y - size, else: part_y
    x = part_x + sprite_x
    y = part_y + sprite_y

    state =
      if x in -16..272 and y in -16..224 do
        high =
          if((x &&& 0x100) != 0, do: 1, else: 0) ||| if((flags &&& 0x20) != 0, do: 2, else: 0)

        append_oam(state, x, y, name + tile, bxor(attributes, flags &&& 0xC0), high)
      else
        state
      end

    process_parts(
      state,
      cartridge,
      count - 1,
      descriptor + 4,
      sprite_x,
      sprite_y,
      name,
      attributes
    )
  end

  defp append_oam(state, x, y, name, attributes, high_bits) do
    offset = state.oam_offset

    ram =
      state.ram
      |> then(&:array.set(offset, x &&& 0xFF, &1))
      |> then(&:array.set(offset + 1, y &&& 0xFF, &1))
      |> then(&:array.set(offset + 2, name &&& 0xFF, &1))
      |> then(&:array.set(offset + 3, attributes &&& 0xFF, &1))

    high = :array.get(state.high_offset, ram)
    high = (high &&& bnot(3 <<< state.high_shift)) ||| high_bits <<< state.high_shift
    ram = :array.set(state.high_offset, high &&& 0xFF, ram)
    next_shift = state.high_shift + 2 &&& 6

    %{
      state
      | ram: ram,
        oam_offset: offset + 4,
        high_offset: state.high_offset + if(next_shift == 0, do: 1, else: 0),
        high_shift: next_shift,
        remaining: state.remaining - 1
    }
  end

  # Immediate ROM signature used by software to identify a Cx4.
  defp execute_command(cx4, 0x89), do: put_unsigned(cx4, 0x1F80, 0x054336, 3)

  defp execute_command(cx4, 0x5C) do
    ram =
      @test_pattern
      |> :binary.bin_to_list()
      |> Enum.with_index()
      |> Enum.reduce(cx4.ram, fn {value, offset}, ram -> :array.set(offset, value, ram) end)

    %{cx4 | ram: ram}
  end

  defp execute_command(cx4, 0x05) do
    numerator = unsigned(cx4, 0x1F81, 2)
    denominator = unsigned(cx4, 0x1F83, 2)

    result =
      if denominator == 0, do: 0x10000, else: div(div(0x10000, denominator) * numerator, 0x100)

    put_unsigned(cx4, 0x1F80, result, 2)
  end

  defp execute_command(cx4, 0x15) do
    x = signed(cx4, 0x1F80, 2)
    y = signed(cx4, 0x1F83, 2)
    put_unsigned(cx4, 0x1F80, trunc(:math.sqrt(x * x + y * y)), 2)
  end

  defp execute_command(cx4, 0x1F) do
    x = signed(cx4, 0x1F80, 2)
    y = signed(cx4, 0x1F83, 2)

    angle =
      cond do
        x == 0 and y > 0 -> 0x80
        x == 0 -> 0x180
        true -> trunc(:math.atan(y / x) / (2 * :math.pi()) * 512) + if(x < 0, do: 0x100, else: 0)
      end

    put_unsigned(cx4, 0x1F86, angle &&& 0x1FF, 2)
  end

  defp execute_command(cx4, 0x22) do
    tangent_left = fixed_tangent(unsigned(cx4, 0x1F8C, 2) &&& 0x1FF)
    tangent_right = fixed_tangent(unsigned(cx4, 0x1F8F, 2) &&& 0x1FF)
    origin_x = unsigned(cx4, 0x1F80, 2)
    origin_y = unsigned(cx4, 0x1F83, 2)
    screen_x = unsigned(cx4, 0x1F86, 2)
    screen_y = unsigned(cx4, 0x1F89, 2)
    width = unsigned(cx4, 0x1F93, 2)
    initial_y = signed_width(origin_y - screen_y, 16)

    ram =
      Enum.reduce(0..224, cx4.ram, fn row, ram ->
        y = initial_y + row

        {left, right} =
          if y < 0 do
            {1, 0}
          else
            left = signed_width(((tangent_left * y) >>> 16) - origin_x + screen_x, 16)
            right = signed_width(((tangent_right * y) >>> 16) - origin_x + screen_x + width, 16)
            clamp_trapezoid(left, right)
          end

        ram = :array.set(0x800 + row, left, ram)
        :array.set(0x900 + row, right, ram)
      end)

    %{cx4 | ram: ram}
  end

  defp execute_command(cx4, 0x25) do
    result = unsigned(cx4, 0x1F80, 3) * unsigned(cx4, 0x1F83, 3)
    put_unsigned(cx4, 0x1F80, result, 3)
  end

  defp execute_command(cx4, 0x40) do
    sum = Enum.reduce(0..0x7FF, 0, fn offset, acc -> acc + :array.get(offset, cx4.ram) end)
    put_unsigned(cx4, 0x1F80, sum, 2)
  end

  defp execute_command(cx4, 0x54) do
    value = signed(cx4, 0x1F80, 3)
    square = value * value
    cx4 |> put_unsigned(0x1F83, square, 3) |> put_unsigned(0x1F86, square >>> 24, 3)
  end

  defp execute_command(cx4, command) do
    %{cx4 | unknown_commands: MapSet.put(cx4.unknown_commands, command)}
  end

  defp unsigned(cx4, offset, bytes) do
    array_unsigned(cx4.ram, offset, bytes)
  end

  defp array_unsigned(ram, offset, bytes) do
    Enum.reduce(0..(bytes - 1), 0, fn index, value ->
      value ||| :array.get(offset + index, ram) <<< (index * 8)
    end)
  end

  defp signed(cx4, offset, bytes) do
    value = unsigned(cx4, offset, bytes)
    sign = 1 <<< (bytes * 8 - 1)
    if (value &&& sign) == 0, do: value, else: value - (1 <<< (bytes * 8))
  end

  defp fixed_tangent(angle) do
    radians = angle * :math.pi() / 256
    sine = round(:math.sin(radians) * 32_767)
    cosine = round(:math.cos(radians) * 32_767)
    if cosine == 0, do: -0x80000000, else: div(sine <<< 16, cosine)
  end

  defp signed_width(value, bits) do
    mask = (1 <<< bits) - 1
    value = value &&& mask
    sign = 1 <<< (bits - 1)
    if (value &&& sign) == 0, do: value, else: value - (1 <<< bits)
  end

  defp clamp_trapezoid(left, right) do
    {left, right} =
      cond do
        left < 0 and right < 0 -> {1, 0}
        left < 0 -> {0, right}
        right < 0 -> {left, 0}
        true -> {left, right}
      end

    cond do
      left > 255 and right > 255 -> {255, 254}
      left > 255 -> {255, right}
      right > 255 -> {left, 255}
      true -> {left, right}
    end
  end

  defp put_unsigned(cx4, offset, value, bytes) do
    ram =
      Enum.reduce(0..(bytes - 1), cx4.ram, fn index, ram ->
        :array.set(offset + index, value >>> (index * 8) &&& 0xFF, ram)
      end)

    %{cx4 | ram: ram}
  end

  defp ram_offset(address), do: (address &&& 0xFFFF) - 0x6000
end
