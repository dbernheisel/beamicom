if Code.ensure_loaded?(Nx.Defn) and Code.ensure_loaded?(EXLA) do
  defmodule Beamicom.NES.Nx.BlarggNTSC.Renderer do
    @moduledoc """
    Runtime-selectable NES PPU renderer with Blargg NTSC presentation.

    This composes the native palette-address plane with the resident CHR atlas and
    then applies `Beamicom.NES.Nx.BlarggNTSC`. Optional identity-derived sprite
    lighting is composited after filtering. The logical NES plane remains
    256x240 while the shared RGB presentation is 602x240.
    """

    import Nx.Defn

    alias Beamicom.NES.Nx.{BlarggNTSC, PPURenderer}

    @width 602
    @height 240
    @native_width 256
    @compiled_key {__MODULE__, :compiled}

    def output_dimensions, do: {@width, @height}
    def output_dimensions(_options_or_state), do: output_dimensions()

    # The filter emits one 602-sample row for each of the NES's 240 scanlines.
    # Doubling rows gives those samples the intended square-pixel presentation.
    def pixel_scale, do: {1, 2}
    def pixel_scale(_options_or_state), do: pixel_scale()

    def prepare_chr(chr, options) do
      ppu = PPURenderer.prepare_chr(chr, options)

      %{
        atlas: PPURenderer.atlas_state(ppu),
        ppu: ppu,
        ntsc: options |> Keyword.delete(:lighting) |> BlarggNTSC.prepare()
      }
    end

    def atlas_state(state), do: state.atlas

    @doc false
    def sprite_lighting?(state), do: PPURenderer.sprite_lighting?(state.ppu)

    def render(lines, palette, grayscale, edge_mask, state),
      do: render(lines, palette, grayscale, edge_mask, state, 0)

    def render(lines, palette, grayscale, edge_mask, state, frame_number) do
      if sprite_lighting?(state) do
        render_lit(lines, palette, grayscale, edge_mask, state, frame_number)
      else
        {pixels, masks} = PPURenderer.render_pixels_and_masks_tensor(lines, state.atlas)

        rgb =
          BlarggNTSC.filter_tensor(pixels, palette, masks, frame_number, edge_mask, state.ntsc)

        {Nx.to_binary(pixels), Nx.to_binary(rgb)}
      end
    end

    @doc false
    def render_composed(pixels, palette, masks, edge_mask, state, frame_number) do
      rgb = BlarggNTSC.filter(pixels, palette, masks, frame_number, edge_mask, state.ntsc)
      {pixels, rgb}
    end

    @doc false
    def render_composed_lit(
          pixels,
          palette,
          masks,
          provenance,
          edge_mask,
          state,
          frame_number
        ) do
      grayscale = Enum.any?(:binary.bin_to_list(masks), &(Bitwise.band(&1, 0x01) != 0))

      emission =
        PPURenderer.composed_emission_tensor(pixels, palette, grayscale, provenance, state.ppu)

      filtered =
        BlarggNTSC.filter_tensor(
          pixels |> Nx.from_binary(:u8) |> Nx.reshape({@height, @native_width}),
          palette,
          masks,
          frame_number,
          edge_mask,
          state.ntsc
        )

      rgb =
        apply_filtered_lighting(
          pixels,
          palette,
          grayscale,
          emission,
          filtered,
          edge_mask,
          state,
          frame_number
        )

      {pixels, Nx.to_binary(rgb)}
    end

    defp render_lit(lines, palette, grayscale, edge_mask, state, frame_number) do
      {pixels, native_rgb, emission} =
        PPURenderer.render_lighting_tensors(
          lines,
          palette,
          grayscale,
          edge_mask,
          state.ppu
        )

      {_pixels, masks} = PPURenderer.render_pixels_and_masks_tensor(lines, state.atlas)

      filtered =
        BlarggNTSC.filter_tensor(pixels, palette, masks, frame_number, edge_mask, state.ntsc)

      rgb =
        apply_filtered_lighting(
          native_rgb,
          emission,
          filtered,
          edge_mask,
          state,
          frame_number
        )

      {Nx.to_binary(pixels), Nx.to_binary(rgb)}
    end

    defp apply_filtered_lighting(
           pixels,
           palette,
           grayscale,
           emission,
           filtered,
           edge_mask,
           state,
           frame_number
         ) do
      frame = %Beamicom.NES.Framebuffer{
        number: frame_number,
        pixels: pixels,
        palette: palette,
        edge_mask: edge_mask,
        grayscale: grayscale
      }

      native_rgb =
        frame
        |> Beamicom.NES.Palette.to_rgb()
        |> Nx.from_binary(:u8)
        |> Nx.reshape({@height, @native_width, 3})

      apply_filtered_lighting(
        native_rgb,
        emission,
        filtered,
        edge_mask,
        state,
        frame_number
      )
    end

    defp apply_filtered_lighting(
           native_rgb,
           emission,
           filtered,
           edge_mask,
           state,
           frame_number
         ) do
      if Nx.to_binary(emission) == :binary.copy(<<0>>, @height * @native_width * 3) do
        filtered
      else
        lit_native =
          PPURenderer.apply_lighting_tensor(
            emission,
            edge_mask,
            PPURenderer.lighting_state(state.ppu),
            frame_number,
            native_rgb
          )

        args = [filtered, native_rgb, lit_native]
        compiled(args) |> apply(args)
      end
    end

    defn add_native_glow(filtered, native_rgb, lit_native) do
      source_x =
        Nx.iota({@width}, type: :s32)
        |> Nx.multiply(@native_width)
        |> Nx.quotient(@width)

      glow =
        Nx.as_type(lit_native, :s16)
        |> Nx.subtract(Nx.as_type(native_rgb, :s16))
        |> Nx.take(source_x, axis: 1)

      filtered
      |> Nx.as_type(:s16)
      |> Nx.add(glow)
      |> Nx.clip(0, 255)
      |> Nx.as_type(:u8)
    end

    defp compiled(args) do
      key = {@compiled_key, Enum.map(args, &Nx.shape/1)}

      case :persistent_term.get(key, nil) do
        nil ->
          fun = EXLA.compile(&add_native_glow/3, Enum.map(args, &Nx.to_template/1), client: :host)
          :persistent_term.put(key, fun)
          fun

        fun ->
          fun
      end
    end
  end
end
