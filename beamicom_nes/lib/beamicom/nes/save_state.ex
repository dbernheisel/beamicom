defmodule Beamicom.NES.SaveState do
  @moduledoc "Serialize/deserialize NES console state, ROM-stripped."

  alias Beamicom.NES.{Bus, Cart, Console, PPU}

  @doc "Split a console into {state_bin, rom_blob}. Both are zlib-compressed term binaries."
  def split(%Console{} = console) do
    prg = console.bus.prg
    chr = console.bus.ppu.chr
    rom_crc = :erlang.crc32(prg <> chr)

    console = snapshot_audio_renderer(console)

    stripped =
      console
      |> put_in([Access.key!(:bus), Access.key!(:prg)], <<>>)
      |> put_in([Access.key!(:bus), Access.key!(:ppu), Access.key!(:chr)], <<>>)
      # Drop the last rendered frame: it's transient output, re-rendered on resume,
      # and the biggest chunk of the payload.
      |> put_in([Access.key!(:bus), Access.key!(:ppu), Access.key!(:frame_ready)], nil)
      # Renderer state is a derived cache. Nx/EXLA states can contain process-local
      # device-buffer references, so serializing them makes a save larger without
      # making those references reusable in the loading VM. `restore_renderers/1`
      # rebuilds the cache from renderer_options after the state is decoded.
      |> put_in([Access.key!(:bus), Access.key!(:ppu), Access.key!(:renderer_state)], nil)
      # Drop the buffered audio samples for the same reason (the audio analog of
      # frame_ready): a drained, regenerated output buffer, ~1KB compressed.
      |> put_in([Access.key!(:bus), Access.key!(:apu), Access.key!(:samples)], [])

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
        |> ensure_current_bus_fields()
        |> put_in([Access.key!(:bus), Access.key!(:prg)], prg)
        |> put_in([Access.key!(:bus), Access.key!(:ppu), Access.key!(:chr)], chr)
        |> restore_renderers()

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
    # A save can contain renderer option atoms and legacy derived renderer state.
    # Load optional renderer applications before binary_to_term(..., [:safe]) so
    # saves made with Nx/EXLA remain readable in a fresh VM. Missing optional apps
    # simply expose no module list and are handled by restore_renderers/1 later.
    for app <- [:beamicom_nes, :nx, :exla] do
      Application.load(app)
      for mod <- Application.spec(app, :modules) || [], do: Code.ensure_loaded(mod)
    end

    :ok
  end

  # Keep the save format version stable while Bus fields with safe defaults are
  # introduced; old struct maps retain their __struct__ tag but do not acquire
  # fields added by a later module version.
  defp ensure_current_bus_fields(%Console{bus: bus} = console) do
    defaults = Bus.default_mapper_state()

    mapper_state =
      Enum.reduce(
        Map.keys(defaults),
        Map.merge(defaults, Map.get(bus, :mapper_state, %{})),
        fn key, state ->
          if Map.has_key?(bus, key), do: Map.put(state, key, Map.fetch!(bus, key)), else: state
        end
      )

    bus = bus |> Map.drop(Map.keys(defaults)) |> then(&Map.merge(%Bus{}, &1))
    bus = %{bus | ppu: Map.merge(%PPU{}, bus.ppu)}
    %{console | bus: %{bus | mapper_state: mapper_state}}
  end

  defp snapshot_audio_renderer(%Console{bus: %{apu_renderer: :native}} = console), do: console

  defp snapshot_audio_renderer(%Console{bus: bus} = console) do
    state =
      if function_exported?(bus.apu_renderer, :snapshot, 1),
        do: apply(bus.apu_renderer, :snapshot, [bus.apu_renderer_state]),
        else: bus.apu_renderer_state

    %{console | bus: %{bus | apu_renderer_state: state}}
  end

  defp restore_renderers(%Console{bus: bus} = console) do
    ppu =
      if bus.ppu.renderer == :native,
        do: bus.ppu,
        else:
          Beamicom.NES.PPU.set_renderer(
            bus.ppu,
            {bus.ppu.renderer, Map.get(bus.ppu, :renderer_options, [])}
          )

    audio_state =
      if bus.apu_renderer != :native and function_exported?(bus.apu_renderer, :restore, 1),
        do: apply(bus.apu_renderer, :restore, [bus.apu_renderer_state]),
        else: bus.apu_renderer_state

    %{console | bus: %{bus | ppu: ppu, apu_renderer_state: audio_state}}
  end
end
