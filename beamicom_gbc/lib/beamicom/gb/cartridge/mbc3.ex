defmodule Beamicom.GB.Cartridge.MBC3.RTC do
  @moduledoc "Deterministic MBC3 real-time clock register state."

  import Bitwise

  defstruct seconds: 0, minutes: 0, hours: 0, days: 0, halt: false, carry: false

  @type t :: %__MODULE__{
          seconds: 0..59,
          minutes: 0..59,
          hours: 0..23,
          days: 0..511,
          halt: boolean(),
          carry: boolean()
        }

  @compile {:inline, read: 2}

  @spec new(t() | map()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = rtc), do: validate(rtc)

  def new(values) when is_map(values) do
    validate(%__MODULE__{
      seconds: Map.get(values, :seconds, 0),
      minutes: Map.get(values, :minutes, 0),
      hours: Map.get(values, :hours, 0),
      days: Map.get(values, :days, 0),
      halt: Map.get(values, :halt, false),
      carry: Map.get(values, :carry, false)
    })
  end

  def new(_values), do: {:error, :invalid_rtc_data}

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = rtc),
    do: Map.from_struct(rtc)

  @spec read(t(), 0x08..0x0C) :: byte()
  def read(%__MODULE__{seconds: value}, 0x08), do: value
  def read(%__MODULE__{minutes: value}, 0x09), do: value
  def read(%__MODULE__{hours: value}, 0x0A), do: value
  def read(%__MODULE__{days: value}, 0x0B), do: value &&& 0xFF

  def read(%__MODULE__{} = rtc, 0x0C),
    do: rtc.days >>> 8 ||| if(rtc.halt, do: 0x40, else: 0) ||| if(rtc.carry, do: 0x80, else: 0)

  @spec write(t(), 0x08..0x0C, byte()) :: t()
  def write(%__MODULE__{seconds: current} = rtc, 0x08, value) do
    value = min(value &&& 0x3F, 59)
    if value == current, do: rtc, else: %{rtc | seconds: value}
  end

  def write(%__MODULE__{minutes: current} = rtc, 0x09, value) do
    value = min(value &&& 0x3F, 59)
    if value == current, do: rtc, else: %{rtc | minutes: value}
  end

  def write(%__MODULE__{hours: current} = rtc, 0x0A, value) do
    value = min(value &&& 0x1F, 23)
    if value == current, do: rtc, else: %{rtc | hours: value}
  end

  def write(%__MODULE__{days: days} = rtc, 0x0B, value) do
    next = (days &&& 0x100) ||| value
    if next == days, do: rtc, else: %{rtc | days: next}
  end

  def write(%__MODULE__{} = rtc, 0x0C, value) do
    days = (rtc.days &&& 0xFF) ||| (value &&& 0x01) <<< 8
    halt = (value &&& 0x40) != 0
    carry = (value &&& 0x80) != 0

    if days == rtc.days and halt == rtc.halt and carry == rtc.carry,
      do: rtc,
      else: %{rtc | days: days, halt: halt, carry: carry}
  end

  @spec advance(t(), non_neg_integer()) :: t()
  def advance(%__MODULE__{} = rtc, 0), do: rtc
  def advance(%__MODULE__{halt: true} = rtc, seconds) when seconds >= 0, do: rtc

  def advance(%__MODULE__{} = rtc, seconds) when seconds > 0 do
    total = rtc.seconds + rtc.minutes * 60 + rtc.hours * 3600 + rtc.days * 86_400 + seconds
    days = div(total, 86_400)
    day_seconds = rem(total, 86_400)

    %{
      rtc
      | seconds: rem(day_seconds, 60),
        minutes: div(day_seconds, 60) |> rem(60),
        hours: div(day_seconds, 3600),
        days: rem(days, 512),
        carry: rtc.carry or days >= 512
    }
  end

  defp validate(%__MODULE__{} = rtc) do
    if rtc.seconds in 0..59 and rtc.minutes in 0..59 and rtc.hours in 0..23 and
         rtc.days in 0..511 and is_boolean(rtc.halt) and is_boolean(rtc.carry) do
      {:ok, rtc}
    else
      {:error, :invalid_rtc_data}
    end
  end
end

defmodule Beamicom.GB.Cartridge.MBC3 do
  @moduledoc "MBC3 ROM/RAM banking and deterministic latchable RTC state."

  import Bitwise

  alias Beamicom.GB.Header
  alias Beamicom.GB.Cartridge.MBC3.RTC
  alias Beamicom.GB.Cartridge.RAM

  @enforce_keys [
    :header,
    :rom,
    :ram,
    :rom_banks,
    :ram_banks,
    :romx_offset,
    :ram_page_offset,
    :rtc
  ]
  defstruct @enforce_keys ++
              [
                ram_enabled: false,
                rom_bank: 1,
                selection: :none,
                rtc_register: 0x08,
                latched_rtc: nil,
                latch_value: 0xFF
              ]

  @type t :: %__MODULE__{}

  @spec new(Header.t(), binary(), RAM.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(%Header{} = header, rom, ram, opts) do
    timer? = :timer in header.features

    cond do
      header.rom_banks > 128 ->
        {:error, {:unsupported_mbc3_rom_banks, header.rom_banks}}

      RAM.size(ram) not in [0, 8 * 1024, 32 * 1024] ->
        {:error, {:unsupported_mbc3_ram_size, RAM.size(ram)}}

      true ->
        with {:ok, rtc} <- initial_rtc(timer?, opts) do
          {:ok,
           %__MODULE__{
             header: header,
             rom: rom,
             ram: ram,
             rom_banks: header.rom_banks,
             ram_banks: div(RAM.size(ram), 0x2000),
             romx_offset: rem(1, header.rom_banks) * 0x4000,
             ram_page_offset: 0,
             rtc: rtc,
             selection: if(RAM.empty?(ram), do: :none, else: :ram)
           }}
        end
    end
  end

  @spec write(t(), 0..0xFFFF, byte()) :: t()
  def write(%__MODULE__{ram: %RAM{size: 0}, rtc: nil} = cartridge, address, _value)
      when address in 0x0000..0x1FFF,
      do: cartridge

  def write(%__MODULE__{ram_enabled: enabled} = cartridge, address, value)
      when address in 0x0000..0x1FFF do
    next = (value &&& 0x0F) == 0x0A
    if enabled == next, do: cartridge, else: %{cartridge | ram_enabled: next}
  end

  def write(%__MODULE__{rom_bank: current} = cartridge, address, value)
      when address in 0x2000..0x3FFF do
    bank = value &&& 0x7F
    bank = if bank == 0, do: 1, else: bank

    if bank == current do
      cartridge
    else
      %{cartridge | rom_bank: bank, romx_offset: rem(bank, cartridge.rom_banks) * 0x4000}
    end
  end

  def write(%__MODULE__{} = cartridge, address, value) when address in 0x4000..0x5FFF,
    do: select(cartridge, value)

  def write(%__MODULE__{rtc: nil} = cartridge, address, _value)
      when address in 0x6000..0x7FFF,
      do: cartridge

  def write(%__MODULE__{latch_value: 0} = cartridge, address, 1)
      when address in 0x6000..0x7FFF and not is_nil(cartridge.rtc),
      do: %{cartridge | latched_rtc: cartridge.rtc, latch_value: 1}

  def write(%__MODULE__{latch_value: current} = cartridge, address, value)
      when address in 0x6000..0x7FFF do
    if current == value, do: cartridge, else: %{cartridge | latch_value: value}
  end

  def write(%__MODULE__{ram_enabled: false} = cartridge, address, _value)
      when address in 0xA000..0xBFFF,
      do: cartridge

  def write(%__MODULE__{selection: :ram, ram: %RAM{size: 0}} = cartridge, address, _value)
      when address in 0xA000..0xBFFF,
      do: cartridge

  def write(
        %__MODULE__{selection: :ram, ram: ram, ram_page_offset: page_offset} = cartridge,
        address,
        value
      )
      when address in 0xA000..0xBFFF and value in 0x00..0xFF,
      do: put_ram(cartridge, ram, page_offset, address - 0xA000, value)

  def write(%__MODULE__{selection: :rtc, rtc: %RTC{} = rtc} = cartridge, address, value)
      when address in 0xA000..0xBFFF and value in 0x00..0xFF do
    next = RTC.write(rtc, cartridge.rtc_register, value)
    if next == rtc, do: cartridge, else: %{cartridge | rtc: next}
  end

  def write(%__MODULE__{} = cartridge, address, value)
      when address in 0x0000..0xFFFF and value in 0x00..0xFF,
      do: cartridge

  @spec advance_rtc(t(), non_neg_integer()) :: t()
  def advance_rtc(%__MODULE__{rtc: nil} = cartridge, seconds) when seconds >= 0, do: cartridge

  def advance_rtc(%__MODULE__{rtc: rtc} = cartridge, seconds) when seconds >= 0 do
    next = RTC.advance(rtc, seconds)
    if next == rtc, do: cartridge, else: %{cartridge | rtc: next}
  end

  @spec restore_persistent_data(t(), map()) :: {:ok, t()} | {:error, term()}
  def restore_persistent_data(%__MODULE__{} = cartridge, %{ram: ram} = data)
      when is_binary(ram) do
    with :ok <- validate_ram_size(cartridge.ram, ram),
         {:ok, rtc} <- restore_rtc(cartridge.rtc, data) do
      {:ok, %{cartridge | ram: RAM.new(ram), rtc: rtc, latched_rtc: nil}}
    end
  end

  def restore_persistent_data(%__MODULE__{}, _data), do: {:error, :invalid_persistence_data}

  defp select(%__MODULE__{ram: %RAM{size: size}} = cartridge, value)
       when value in 0x00..0x07 and size != 0 do
    page_offset = rem(value, cartridge.ram_banks) * 32

    if cartridge.selection == :ram and page_offset == cartridge.ram_page_offset do
      cartridge
    else
      %{cartridge | selection: :ram, ram_page_offset: page_offset}
    end
  end

  defp select(%__MODULE__{rtc: %RTC{}} = cartridge, value) when value in 0x08..0x0C do
    if cartridge.selection == :rtc and cartridge.rtc_register == value,
      do: cartridge,
      else: %{cartridge | selection: :rtc, rtc_register: value}
  end

  defp select(%__MODULE__{selection: :none} = cartridge, _value), do: cartridge
  defp select(%__MODULE__{} = cartridge, _value), do: %{cartridge | selection: :none}

  defp initial_rtc(timer?, opts) do
    persistence = Keyword.get(opts, :persistence, %{})
    supplied = Keyword.get(opts, :rtc, Map.get(persistence, :rtc, :default))

    case {timer?, supplied} do
      {false, :default} -> {:ok, nil}
      {false, nil} -> {:ok, nil}
      {false, _rtc} -> {:error, :unexpected_rtc_data}
      {true, :default} -> RTC.new(%{})
      {true, rtc} -> RTC.new(rtc)
    end
  end

  defp validate_ram_size(expected, actual) when expected.size == byte_size(actual), do: :ok

  defp validate_ram_size(expected, actual),
    do: {:error, {:ram_size_mismatch, RAM.size(expected), byte_size(actual)}}

  defp restore_rtc(nil, data) do
    if Map.has_key?(data, :rtc), do: {:error, :unexpected_rtc_data}, else: {:ok, nil}
  end

  defp restore_rtc(%RTC{}, %{rtc: rtc}), do: RTC.new(rtc)
  defp restore_rtc(%RTC{}, _data), do: {:error, :missing_rtc_data}

  defp put_ram(cartridge, ram, page_offset, window_offset, value) do
    case RAM.put_window(ram, page_offset, window_offset, value) do
      :unchanged -> cartridge
      {:changed, ram} -> %{cartridge | ram: ram}
    end
  end
end
