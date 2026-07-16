defmodule Beamicom.NES.SaveState do
  @moduledoc "Serialize/deserialize NES console state, ROM-stripped."

  alias Beamicom.NES.{Console, Cart}

  @doc "Split a console into {state_bin, rom_blob}. Both are zlib-compressed term binaries."
  def split(%Console{} = console) do
    prg = console.bus.prg
    chr = console.bus.ppu.chr
    rom_crc = :erlang.crc32(prg <> chr)

    stripped =
      console
      |> put_in([Access.key!(:bus), Access.key!(:prg)], <<>>)
      |> put_in([Access.key!(:bus), Access.key!(:ppu), Access.key!(:chr)], <<>>)
      # Drop the last rendered frame: it's transient output, re-rendered on resume,
      # and the biggest chunk of the payload.
      |> put_in([Access.key!(:bus), Access.key!(:ppu), Access.key!(:frame_ready)], nil)

    state_bin =
      :zlib.compress(:erlang.term_to_binary(%{v: 1, rom_crc: rom_crc, console: stripped}))

    rom_blob = :zlib.compress(:erlang.term_to_binary({prg, chr}))
    {state_bin, rom_blob}
  end

  @doc "Reconstruct a %Console{} from state_bin + rom_blob, verifying CRC."
  def merge(state_bin, rom_blob) do
    # The saved console holds atoms (module/field names, :ntsc, ...). `binary_to_term`
    # with [:safe] refuses atoms not already in the table, so a fresh process (e.g.
    # `mix nes.load`) that never ran the emulator would reject them. Load the app's
    # modules first to register their atoms while keeping [:safe]'s DoS guard.
    ensure_atoms_loaded()

    try do
      %{v: 1, rom_crc: saved_crc, console: console} =
        :erlang.binary_to_term(:zlib.uncompress(state_bin), [:safe])

      {prg, chr} = :erlang.binary_to_term(:zlib.uncompress(rom_blob), [:safe])

      unless :erlang.crc32(prg <> chr) == saved_crc, do: throw({:error, :crc_mismatch})

      console =
        console
        |> put_in([Access.key!(:bus), Access.key!(:prg)], prg)
        |> put_in([Access.key!(:bus), Access.key!(:ppu), Access.key!(:chr)], chr)

      {:ok, console}
    rescue
      _ -> {:error, :corrupt}
    catch
      :throw, err -> err
    end
  end

  @doc "Compute the ROM CRC from a .nes file path (for trailer-stripped fallback matching)."
  def rom_crc(nes_path) do
    {:ok, cart} = Cart.parse(File.read!(nes_path))
    :erlang.crc32(cart.prg_rom <> cart.chr_rom)
  end

  defp ensure_atoms_loaded do
    Application.load(:beamicom)
    for mod <- Application.spec(:beamicom, :modules) || [], do: Code.ensure_loaded(mod)
    :ok
  end
end
