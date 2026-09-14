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
      @command_offset -> execute(cx4, value &&& 0xFF)
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

  defp execute(cx4, command) do
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

      true ->
        execute_command(cx4, command)
    end
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
    Enum.reduce(0..(bytes - 1), 0, fn index, value ->
      value ||| :array.get(offset + index, cx4.ram) <<< (index * 8)
    end)
  end

  defp signed(cx4, offset, bytes) do
    value = unsigned(cx4, offset, bytes)
    sign = 1 <<< (bytes * 8 - 1)
    if (value &&& sign) == 0, do: value, else: value - (1 <<< (bytes * 8))
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
