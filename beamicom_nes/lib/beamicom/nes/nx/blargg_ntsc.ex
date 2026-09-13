if Code.ensure_loaded?(Nx.Defn) and Code.ensure_loaded?(EXLA) do
  # SPDX-License-Identifier: LGPL-2.1-or-later

  defmodule Beamicom.NES.Nx.BlarggNTSC do
    @moduledoc """
    Nx implementation of Shay Green's `nes_ntsc` 3-to-7-pixel runtime blitter.

    The setup code builds the original phase/alignment lookup table once. Frames
    remain native NES palette indices until this module applies the selected table
    in one fixed-shape EXLA call, producing 602x240 RGB24 output.

    The port is derived from nes_ntsc 0.2.2 and is LGPL-2.1-or-later.
    """

    import Nx.Defn
    import Bitwise, only: [<<<: 2, |||: 2]

    alias Beamicom.NES.Nx.BlarggNTSC.Table

    @height 240
    @width 256
    @groups 86
    @output_width 602
    @burst_size 42
    @table_stride 128
    @table_size 64 * @table_stride
    @black 0x0F
    @rgb_builder 1 <<< 21 ||| 1 <<< 11 ||| 1 <<< 1
    @clamp_mask div(@rgb_builder * 3, 2)
    @clamp_add @rgb_builder * 0x101
    @kernel_format :flat_compact_v1
    @compiled_key {__MODULE__, :compiled, @kernel_format}

    @type state :: %{preset: atom(), merge_fields: boolean(), table: Nx.Tensor.t()}

    @doc "Prepare an EXLA-resident lookup table for a standard nes_ntsc preset."
    @spec prepare(keyword()) :: state()
    def prepare(options \\ []) do
      preset = Keyword.get(options, :preset, :composite)
      overrides = options |> Keyword.delete(:preset) |> Map.new()
      setup = Map.merge(Table.preset(preset), overrides)
      merge_fields = setup.merge_fields
      key = {__MODULE__, :table, @kernel_format, setup}

      table =
        case :persistent_term.get(key, nil) do
          nil ->
            table =
              setup
              |> Table.generate()
              |> compact_table()
              |> Nx.reshape({@table_size})
              |> Nx.backend_copy({EXLA.Backend, client: :host})

            :persistent_term.put(key, table)
            table

          table ->
            table
        end

      %{preset: preset, merge_fields: merge_fields, table: table}
    end

    @doc "Filter one 256x240 palette-address plane into packed 602x240 RGB24."
    @spec filter(binary(), binary(), binary(), non_neg_integer(), non_neg_integer(), state()) ::
            binary()
    def filter(pixels, palette, masks, frame_number, edge_mask, state)
        when byte_size(pixels) == @width * @height and byte_size(palette) == 32 and
               byte_size(masks) == @height do
      pixels
      |> tensor({@height, @width})
      |> filter_tensor(palette, masks, frame_number, edge_mask, state)
      |> Nx.to_binary()
    end

    @doc false
    def filter_tensor(%Nx.Tensor{} = pixels, palette, masks, frame_number, edge_mask, state)
        when byte_size(palette) == 32 and byte_size(masks) == @height do
      filter_tensor(
        pixels,
        palette,
        tensor(masks, {@height, 1}),
        frame_number,
        edge_mask,
        state
      )
    end

    @doc false
    def filter_tensor(
          %Nx.Tensor{} = pixels,
          palette,
          %Nx.Tensor{} = masks,
          frame_number,
          edge_mask,
          state
        )
        when byte_size(palette) == 32 do
      args = [
        pixels,
        tensor(palette, {32}),
        masks,
        Nx.tensor(frame_number, type: :s32),
        Nx.tensor(edge_mask, type: :s32),
        state.table,
        Nx.tensor(if(state.merge_fields, do: 1, else: 0), type: :u8)
      ]

      {@compiled_key, Nx.type(state.table)}
      |> compiled(args)
      |> apply(args)
    end

    @doc false
    defn render(pixels, palette, masks, frame_number, edge_mask, table, merge_fields) do
      x = Nx.iota({@height, @width}, axis: 1, type: :s32)
      gray_mask = Nx.select(band(masks, 1) != 0, 0x30, 0x3F)
      colors = Nx.take(palette, Nx.as_type(pixels, :s32)) |> band(gray_mask)
      in_picture = x >= edge_mask and x < @width - edge_mask
      colors = Nx.select(in_picture, colors, @black)

      black = Nx.broadcast(@black, {@height, 1})
      current0 = Nx.concatenate([colors[[.., 1..253//3]], black], axis: 1)
      current1 = Nx.concatenate([colors[[.., 2..254//3]], black], axis: 1)
      current2 = Nx.concatenate([colors[[.., 3..255//3]], black], axis: 1)
      previous0 = Nx.concatenate([black, current0[[.., 0..84]]], axis: 1)
      previous1 = Nx.concatenate([black, current1[[.., 0..84]]], axis: 1)
      previous2 = Nx.concatenate([colors[[.., 0..0]], current2[[.., 0..84]]], axis: 1)
      lagged1 = Nx.concatenate([black, previous1[[.., 0..84]]], axis: 1)
      lagged2 = Nx.concatenate([black, previous2[[.., 0..84]]], axis: 1)

      row = Nx.iota({@height, 1}, axis: 0, type: :s32)
      field_phase = Nx.select(merge_fields != 0, 0, remainder(frame_number, 2))
      phase = remainder(row + field_phase, 3)
      sample = Nx.iota({1, 1, 7}, axis: 2, type: :s32)

      raw =
        lookup(table, current0, phase, sample) +
          staged_lookup(table, previous1, current1, phase, sample, 2, 14, 12) +
          staged_lookup(table, previous2, current2, phase, sample, 4, 28, 10) +
          lookup(table, previous0, phase, remainder(sample + 7, 14)) +
          staged_lookup(table, lagged1, previous1, phase, sample, 2, 21, 5) +
          staged_lookup(table, lagged2, previous2, phase, sample, 4, 35, 3)

      sub = band(Nx.right_shift(raw, 9), @clamp_mask)
      clamp = @clamp_add - sub
      raw = bor(raw, clamp)
      clamp = clamp - sub
      raw = band(raw, clamp)

      red = band(Nx.right_shift(raw, 21), 0xFF)
      green = band(Nx.right_shift(raw, 11), 0xFF)
      blue = band(Nx.right_shift(raw, 1), 0xFF)

      Nx.stack([red, green, blue], axis: 3)
      |> Nx.reshape({@height, @output_width, 3})
      |> Nx.as_type(:u8)
    end

    defnp lookup(table, colors, phase, offsets) do
      colors =
        colors
        |> Nx.new_axis(2)
        |> Nx.broadcast({@height, @groups, 7})
        |> Nx.as_type(:s32)

      lookup_colors(table, colors, phase, offsets)
    end

    defnp staged_lookup(table, previous, current, phase, sample, split, base, rotation) do
      previous = previous |> Nx.new_axis(2) |> Nx.broadcast({@height, @groups, 7})
      current = current |> Nx.new_axis(2) |> Nx.broadcast({@height, @groups, 7})
      staged = Nx.broadcast(sample < split, {@height, @groups, 7})
      colors = Nx.select(staged, previous, current) |> Nx.as_type(:s32)
      offsets = remainder(sample + rotation, 7) + base
      lookup_colors(table, colors, phase, offsets)
    end

    defnp lookup_colors(table, colors, phase, offsets) do
      table_index =
        (Nx.new_axis(phase, 2) * @burst_size + offsets)
        |> Nx.broadcast({@height, @groups, 7})
        |> Nx.as_type(:s32)

      # The table is logically {color, phase/alignment}, but a flat take avoids
      # materializing a second coordinate plane and stacking both coordinates for
      # every one of the six taps. Signed 32-bit indices and compact standard
      # tables are sufficient for nes_ntsc's packed lanes and halve bandwidth.
      Nx.take(table, colors * @table_stride + table_index)
    end

    defp compiled(key, args) do
      case :persistent_term.get(key, nil) do
        nil ->
          fun = EXLA.compile(&render/7, Enum.map(args, &Nx.to_template/1), client: :host)
          :persistent_term.put(key, fun)
          fun

        fun ->
          fun
      end
    end

    # Standard presets have exhaustive six-tap bounds of 0.84B..1.81B. Check
    # custom setup overrides too, retaining s64 if their table or any possible
    # aligned sum exceeds the exact signed-32-bit range.
    defp compact_table(table) do
      values = Nx.to_flat_list(table)

      if Enum.min(values) >= -2_147_483_648 and Enum.max(values) <= 2_147_483_647 and
           sums_fit_s32?(values),
         do: Nx.as_type(table, :s32),
         else: table
    end

    defp sums_fit_s32?(values) do
      rows = Enum.chunk_every(values, @table_stride)

      Enum.all?(0..2, fn phase ->
        Enum.all?(0..6, fn sample ->
          offsets = [
            sample,
            rem(sample + 12, 7) + 14,
            rem(sample + 10, 7) + 28,
            sample + 7,
            rem(sample + 5, 7) + 21,
            rem(sample + 3, 7) + 35
          ]

          {minimum, maximum} =
            Enum.reduce(offsets, {0, 0}, fn offset, {minimum, maximum} ->
              candidates = Enum.map(rows, &Enum.at(&1, phase * @burst_size + offset))
              {minimum + Enum.min(candidates), maximum + Enum.max(candidates)}
            end)

          minimum >= -2_147_483_648 and maximum <= 2_147_483_647
        end)
      end)
    end

    defp tensor(binary, shape), do: binary |> Nx.from_binary(:u8) |> Nx.reshape(shape)
    defnp(band(a, b), do: Nx.bitwise_and(a, b))
    defnp(bor(a, b), do: Nx.bitwise_or(a, b))
    defnp(remainder(a, b), do: Nx.remainder(a, b))
  end
end
