if Code.ensure_loaded?(Nx.Defn) do
  # SPDX-License-Identifier: LGPL-2.1-or-later

  defmodule Beamicom.SNES.Nx.BlarggNTSC do
    @moduledoc """
    Nx port of Shay Green's `snes_ntsc` 0.2.2 presentation filter.

    Native 256-pixel RGB24 rows are quantized exactly as the reference RGB15
    input path and expanded by the original 3-to-7-pixel blitter. The result is
    a 602-pixel RGB24 row for each source scanline.
    """

    @behaviour Beamicom.SNES.VideoFilter

    import Nx.Defn
    import Bitwise, only: [<<<: 2, |||: 2]

    alias Beamicom.SNES.Nx.BlarggNTSC.Table

    @width 256
    @groups 86
    @output_width 602
    @burst_size 42
    @table_stride 128
    @table_size 0x2000 * @table_stride
    @rgb_builder 1 <<< 21 ||| 1 <<< 11 ||| 1 <<< 1
    @clamp_mask div(@rgb_builder * 3, 2)
    @clamp_add @rgb_builder * 0x101
    @kernel_format :flat_compact_v1
    @compiled_key {__MODULE__, :compiled, @kernel_format}

    @type state :: %{preset: atom(), merge_fields: boolean(), table: Nx.Tensor.t()}

    @impl true
    def output_width, do: @output_width

    @impl true
    def pixel_scale, do: {1, 2}

    @doc "Prepare a backend-resident lookup table for a standard snes_ntsc preset."
    @impl true
    def prepare(options \\ []) do
      preset = Keyword.get(options, :preset, :composite)
      overrides = options |> Keyword.delete(:preset) |> Map.new()
      setup = Map.merge(Table.preset(preset), overrides)
      merge_fields = setup.merge_fields or (setup.artifacts <= -1.0 and setup.fringing <= -1.0)
      key = {__MODULE__, :table, @kernel_format, Beamicom.SNES.Nx.backend(), setup}

      table =
        case :persistent_term.get(key, nil) do
          nil ->
            table =
              setup
              |> Table.generate()
              |> compact_table()
              |> Nx.reshape({@table_size})
              |> Nx.backend_copy(Beamicom.SNES.Nx.backend())

            :persistent_term.put(key, table)
            table

          table ->
            table
        end

      %{preset: preset, merge_fields: merge_fields, table: table}
    end

    @doc "Filter one 256-pixel-wide RGB24 frame into packed 602-pixel-wide RGB24."
    @impl true
    def filter(rgb, frame_number, state) when rem(byte_size(rgb), @width * 3) == 0 do
      height = div(byte_size(rgb), @width * 3)

      rgb
      |> Nx.from_binary(:u8)
      |> Nx.reshape({height, @width, 3})
      |> filter_tensor(frame_number, state)
      |> Nx.to_binary()
    end

    @doc false
    def filter_tensor(%Nx.Tensor{} = rgb, frame_number, state) do
      args = [
        rgb,
        Nx.tensor(frame_number, type: :s32),
        state.table,
        Nx.tensor(if(state.merge_fields, do: 1, else: 0), type: :u8)
      ]

      {@compiled_key, Nx.shape(rgb), Nx.type(state.table)}
      |> compiled(args)
      |> apply(args)
    end

    @doc false
    defn render(rgb, frame_number, table, merge_fields) do
      height = elem(Nx.shape(rgb), 0)
      red = Nx.as_type(rgb[[.., .., 0]], :s32)
      green = Nx.as_type(rgb[[.., .., 1]], :s32)
      blue = Nx.as_type(rgb[[.., .., 2]], :s32)

      colors =
        Nx.left_shift(Nx.right_shift(red, 4), 9) +
          Nx.left_shift(Nx.right_shift(green, 3), 4) + Nx.right_shift(blue, 4)

      black = Nx.broadcast(0, {height, 1})
      current0 = Nx.concatenate([colors[[.., 1..253//3]], black], axis: 1)
      current1 = Nx.concatenate([colors[[.., 2..254//3]], black], axis: 1)
      current2 = Nx.concatenate([colors[[.., 3..255//3]], black], axis: 1)
      previous0 = Nx.concatenate([black, current0[[.., 0..84]]], axis: 1)
      previous1 = Nx.concatenate([black, current1[[.., 0..84]]], axis: 1)
      previous2 = Nx.concatenate([colors[[.., 0..0]], current2[[.., 0..84]]], axis: 1)
      lagged1 = Nx.concatenate([black, previous1[[.., 0..84]]], axis: 1)
      lagged2 = Nx.concatenate([black, previous2[[.., 0..84]]], axis: 1)

      row = Nx.iota({height, 1}, axis: 0, type: :s32)
      field_phase = Nx.select(merge_fields != 0, 0, Nx.remainder(frame_number, 2))
      phase = Nx.remainder(row + field_phase, 3)
      sample = Nx.iota({1, 1, 7}, axis: 2, type: :s32)

      raw =
        lookup(table, current0, phase, sample, height) +
          staged_lookup(table, previous1, current1, phase, sample, 2, 14, 12, height) +
          staged_lookup(table, previous2, current2, phase, sample, 4, 28, 10, height) +
          lookup(table, previous0, phase, Nx.remainder(sample + 7, 14), height) +
          staged_lookup(table, lagged1, previous1, phase, sample, 2, 21, 5, height) +
          staged_lookup(table, lagged2, previous2, phase, sample, 4, 35, 3, height)

      sub = Nx.bitwise_and(Nx.right_shift(raw, 8), @clamp_mask)
      clamp = @clamp_add - sub
      raw = Nx.bitwise_or(raw, clamp)
      clamp = clamp - sub
      raw = Nx.bitwise_and(raw, clamp)

      red = Nx.bitwise_and(Nx.right_shift(raw, 20), 0xFF)
      green = Nx.bitwise_and(Nx.right_shift(raw, 10), 0xFF)
      blue = Nx.bitwise_and(raw, 0xFF)

      Nx.stack([red, green, blue], axis: 3)
      |> Nx.reshape({height, @output_width, 3})
      |> Nx.as_type(:u8)
    end

    defnp lookup(table, colors, phase, offsets, height) do
      colors =
        colors
        |> Nx.new_axis(2)
        |> Nx.broadcast({height, @groups, 7})
        |> Nx.as_type(:s32)

      lookup_colors(table, colors, phase, offsets, height)
    end

    defnp staged_lookup(
            table,
            previous,
            current,
            phase,
            sample,
            split,
            base,
            rotation,
            height
          ) do
      previous = previous |> Nx.new_axis(2) |> Nx.broadcast({height, @groups, 7})
      current = current |> Nx.new_axis(2) |> Nx.broadcast({height, @groups, 7})
      staged = Nx.broadcast(sample < split, {height, @groups, 7})
      colors = Nx.select(staged, previous, current) |> Nx.as_type(:s32)
      offsets = Nx.remainder(sample + rotation, 7) + base
      lookup_colors(table, colors, phase, offsets, height)
    end

    defnp lookup_colors(table, colors, phase, offsets, height) do
      table_index =
        (Nx.new_axis(phase, 2) * @burst_size + offsets)
        |> Nx.broadcast({height, @groups, 7})
        |> Nx.as_type(:s32)

      Nx.take(table, colors * @table_stride + table_index)
    end

    defp compiled(key, args) do
      key = {key, Beamicom.SNES.Nx.compiler_options()}

      case :persistent_term.get(key, nil) do
        nil ->
          fun = Beamicom.SNES.Nx.compile(&render/4, args)
          :persistent_term.put(key, fun)
          fun

        fun ->
          fun
      end
    end

    defp compact_table(table) do
      minima = table |> Nx.reduce_min(axes: [0]) |> Nx.to_flat_list()
      maxima = table |> Nx.reduce_max(axes: [0]) |> Nx.to_flat_list()

      if sums_fit_s32?(minima, maxima), do: Nx.as_type(table, :s32), else: table
    end

    defp sums_fit_s32?(minima, maxima) do
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

          minimum = Enum.sum(Enum.map(offsets, &Enum.at(minima, phase * @burst_size + &1)))
          maximum = Enum.sum(Enum.map(offsets, &Enum.at(maxima, phase * @burst_size + &1)))
          minimum >= -2_147_483_648 and maximum <= 2_147_483_647
        end)
      end)
    end
  end
end
