defmodule Beamicom.GB.SaveState do
  @moduledoc """
  Versioned, ROM-stripped serialization for Game Boy machines.

  The state payload contains every execution-relevant CPU, mapper, timer, PPU,
  and APU field. The immutable cartridge ROM is kept separately and identified
  by its byte length and SHA-256 digest. Completed video and drained PCM are
  transient host output, so they are cleared before serialization.
  """

  alias Beamicom.GB.{BoundedZlib, Machine, PPU}

  @magic "BEAMICOM_GB_STATE"
  @version 1
  @max_state_bytes 4 * 1024 * 1024
  @max_rom_bytes 8 * 1024 * 1024
  @max_compressed_rom_bytes @max_rom_bytes + 1024 * 1024

  @type identity :: %{size: non_neg_integer(), sha256: binary()}

  @doc "Splits a machine into compressed state and immutable-ROM blobs."
  @spec split(Machine.t()) :: {binary(), binary()}
  def split(%Machine{bus: %{cartridge: %{rom: rom}}} = machine) when is_binary(rom) do
    identity = rom_identity(rom)

    stripped =
      machine
      |> put_in(
        [Access.key!(:bus), Access.key!(:cartridge)],
        Map.put(machine.bus.cartridge, :rom, <<>>)
      )
      |> put_in(
        [Access.key!(:bus), Access.key!(:ppu), Access.key!(:frame)],
        blank_frame(machine.model)
      )
      |> put_in([Access.key!(:bus), Access.key!(:apu), Access.key!(:samples)], [])
      |> put_in([Access.key!(:bus), Access.key!(:apu), Access.key!(:sample_count)], 0)
      |> put_in([Access.key!(:bus), Access.key!(:serial_output)], [])

    payload = %{magic: @magic, version: @version, rom: identity, machine: stripped}
    {:zlib.compress(:erlang.term_to_binary(payload)), :zlib.compress(rom)}
  end

  @doc "Restores a machine and rejects corrupt, unsupported, or mismatched ROM data."
  @spec merge(binary(), binary()) :: {:ok, Machine.t()} | {:error, term()}
  def merge(state_blob, rom_blob) when is_binary(state_blob) and is_binary(rom_blob) do
    ensure_atoms_loaded()

    with {:ok, payload} <- decode_state(state_blob),
         :ok <- validate_envelope(payload),
         {:ok, rom} <- decode_rom(rom_blob),
         :ok <- validate_rom(rom, payload.rom),
         {:ok, machine} <- restore_machine(payload.machine, rom) do
      {:ok, machine}
    end
  end

  @doc "Reads the validated state envelope without requiring the cartridge ROM."
  @spec metadata(binary()) :: {:ok, %{version: pos_integer(), rom: identity()}} | {:error, term()}
  def metadata(state_blob) when is_binary(state_blob) do
    ensure_atoms_loaded()

    with {:ok, payload} <- decode_state(state_blob),
         :ok <- validate_envelope(payload) do
      {:ok, %{version: payload.version, rom: payload.rom}}
    end
  end

  @doc "Returns the stable ROM identity used by save states."
  @spec rom_identity(binary()) :: identity()
  def rom_identity(rom) when is_binary(rom),
    do: %{size: byte_size(rom), sha256: :crypto.hash(:sha256, rom)}

  defp decode_state(blob) when byte_size(blob) <= @max_state_bytes do
    with {:ok, inflated} <- BoundedZlib.inflate(blob, @max_state_bytes) do
      try do
        {:ok, :erlang.binary_to_term(inflated, [:safe])}
      rescue
        _error -> {:error, :corrupt}
      end
    else
      {:error, :too_large} -> {:error, :state_too_large}
      {:error, :invalid} -> {:error, :corrupt}
    end
  end

  defp decode_state(_blob), do: {:error, :state_too_large}

  defp validate_envelope(%{magic: @magic, version: @version, rom: identity, machine: %Machine{}}) do
    case identity do
      %{size: size, sha256: digest}
      when is_integer(size) and size >= 0 and size <= @max_rom_bytes and byte_size(digest) == 32 ->
        :ok

      _other ->
        {:error, :corrupt}
    end
  end

  defp validate_envelope(%{magic: @magic, version: version}) when is_integer(version),
    do: {:error, {:unsupported_version, version}}

  defp validate_envelope(_payload), do: {:error, :corrupt}

  defp decode_rom(blob) when byte_size(blob) <= @max_compressed_rom_bytes do
    case BoundedZlib.inflate(blob, @max_rom_bytes) do
      {:ok, rom} -> {:ok, rom}
      {:error, :too_large} -> {:error, :rom_too_large}
      {:error, :invalid} -> {:error, :corrupt_rom}
    end
  end

  defp decode_rom(_blob), do: {:error, :rom_too_large}

  defp validate_rom(rom, expected) do
    if rom_identity(rom) == expected, do: :ok, else: {:error, :rom_mismatch}
  end

  defp restore_machine(
         %Machine{model: model, bus: %{cartridge: cartridge, ppu: %PPU{model: model}}} = machine,
         rom
       )
       when model in [:dmg, :cgb] and is_struct(cartridge) do
    {:ok, put_in(machine.bus.cartridge, Map.put(cartridge, :rom, rom))}
  end

  defp restore_machine(_machine, _rom), do: {:error, :corrupt}

  defp blank_frame(:dmg), do: :binary.copy(<<0>>, 160 * 144)
  defp blank_frame(:cgb), do: :binary.copy(<<255>>, 160 * 144 * 3)

  defp ensure_atoms_loaded do
    Application.load(:beamicom_gbc)
    for module <- Application.spec(:beamicom_gbc, :modules) || [], do: Code.ensure_loaded(module)
    :ok
  end
end
