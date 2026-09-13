defmodule Beamicom.GB.Nx.PPURenderer do
  @moduledoc """
  Frame-wide DMG/CGB sprite-priority and palette compositor.

  The live PPU captures mapper- and register-resolved background colors and
  sprite rows at HBlank. This renderer composes all 23,040 pixels in one EXLA
  program at VBlank.
  """

  import Nx.Defn
  @behaviour Beamicom.GB.PPURenderer

  @height 144
  @width 160

  @impl true
  def prepare(model) when model in [:dmg, :cgb], do: nil

  @impl true
  def render(:dmg, lines, state) when length(lines) == @height do
    args = [tensor(IO.iodata_to_binary(lines), {@height, @width * 2 + 3})]

    frame = compiled(:dmg, args) |> apply(args)
    {Nx.to_binary(frame), state}
  end

  def render(:cgb, lines, state) when length(lines) == @height do
    args = [tensor(IO.iodata_to_binary(lines), {@height, @width * 2 + 1 + 64 * 3})]

    frame = compiled(:cgb, args) |> apply(args)
    {Nx.to_binary(frame), state}
  end

  defn compose_dmg(rows) do
    background = rows[[.., 0..(@width - 1)]]
    objects = rows[[.., @width..(@width * 2 - 1)]]
    palettes = rows[[.., (@width * 2)..(@width * 2 + 2)]]
    bgp = palettes[[.., 0]] |> Nx.reshape({@height, 1})
    obp0 = palettes[[.., 1]] |> Nx.reshape({@height, 1})
    obp1 = palettes[[.., 2]] |> Nx.reshape({@height, 1})
    bg = band(shr(bgp, background * 2), 3)
    object_color = band(objects, 3)
    object_palette = Nx.select(band(objects, 0x20) != 0, obp1, obp0)
    object = band(shr(object_palette, object_color * 2), 3)
    occupied = band(objects, 0x80) != 0
    behind_background = band(objects, 0x40) != 0 and background != 0
    Nx.select(occupied and not behind_background, object, bg)
  end

  defn compose_cgb(rows) do
    background = rows[[.., 0..(@width - 1)]]
    objects = rows[[.., @width..(@width * 2 - 1)]]
    control = rows[[.., (@width * 2)..(@width * 2)]]

    palettes =
      rows[[.., (@width * 2 + 1)..(@width * 2 + 64 * 3)]]
      |> Nx.reshape({@height, 64, 3})

    bg_index = band(shr(background, 2), 7) * 4 + band(background, 3)
    object_index = 32 + band(shr(objects, 2), 7) * 4 + band(objects, 3)
    bg = palette_gather(palettes, bg_index)
    object = palette_gather(palettes, object_index)
    occupied = band(objects, 0x40) != 0

    priority =
      band(control, 1) != 0 and band(background, 3) != 0 and
        (band(background, 0x20) != 0 or band(objects, 0x20) != 0)

    visible = occupied and not priority
    visible = visible |> Nx.new_axis(2) |> Nx.broadcast({@height, @width, 3})
    Nx.select(visible, object, bg)
  end

  defnp palette_gather(palettes, indexes) do
    indexes = indexes |> Nx.new_axis(2) |> Nx.broadcast({@height, @width, 3})
    Nx.take_along_axis(palettes, indexes, axis: 1)
  end

  defp tensor(binary, shape), do: binary |> Nx.from_binary(:u8) |> Nx.reshape(shape)

  defp compiled(kind, args) do
    key = {__MODULE__, kind, :compiled}

    case :persistent_term.get(key, nil) do
      nil ->
        function = if kind == :dmg, do: &compose_dmg/1, else: &compose_cgb/1
        compiled = EXLA.compile(function, Enum.map(args, &Nx.to_template/1), client: :host)
        :persistent_term.put(key, compiled)
        compiled

      compiled ->
        compiled
    end
  end

  defnp(band(a, b), do: Nx.bitwise_and(a, b))
  defnp(shr(a, b), do: Nx.right_shift(a, b))
end
