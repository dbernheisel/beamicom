if Code.ensure_loaded?(Nx.Defn) and Code.ensure_loaded?(EXLA) do
  defmodule Beamicom.GB.Nx.PixelTransparency do
    @moduledoc """
    Nx port of Matt Akins' [Pixel Transparency][pixel-transparency] shader.

    [pixel-transparency]: https://github.com/mattakins/Pixel_Transparency

    The first stage modulates the image with RGB subpixel and scanline factors.
    The second treats bright LCD pixels as partially transparent, revealing a
    textured reflective backing and shadows cast by darker pixels. Sensor-driven
    motion and optional shimmer extensions are omitted because Scenic does not
    provide their uniforms; the original static-shadow fallback is used.
    """

    import Nx.Defn

    @defaults [
      brighten_scanlines: 16.0,
      brighten_lcd: 4.0,
      hide_content: 0.0,
      palette: 3.0,
      palette_intensity: 1.0,
      backing_brightness: 0.48,
      polarizer: 1.0,
      polarizer_tint: 1.0,
      saturation: 1.0,
      highlights: 0.05,
      pixel_mode: 1.0,
      base_alpha: 0.20,
      threshold: 0.90,
      white_boost: 0.0,
      white_transparency: 0.50,
      brightness_mode: 1.0,
      brightness_grid: 0.0,
      shadow_enable: 1.0,
      shadow_offset_x: 3.0,
      shadow_offset_y: 3.0,
      shadow_opacity: 0.50,
      shadow_blur: 1.0,
      shadow_fast_blur: 1.0
    ]

    @parameter_names Keyword.keys(@defaults)
    @compiled_version :pixel_transparency_v1
    @tau 6.283185308

    defmacrop parameter(parameters, name) do
      index = Enum.find_index(@parameter_names, &(&1 == name))

      quote do
        unquote(parameters)[unquote(index)]
      end
    end

    @doc "Default shader parameters as a keyword list."
    def defaults, do: @defaults

    @doc "Apply Pixel Transparency to a packed RGB24 frame."
    @spec filter(
            binary(),
            {pos_integer(), pos_integer()},
            {pos_integer(), pos_integer()},
            keyword()
          ) ::
            binary()
    def filter(rgb, {width, height}, output_size, options \\ [])
        when is_binary(rgb) and byte_size(rgb) == width * height * 3 do
      rgb
      |> Nx.from_binary(:u8)
      |> Nx.reshape({height, width, 3})
      |> filter_tensor(output_size, options)
      |> Nx.to_binary()
    end

    @doc "Apply Pixel Transparency to an RGB tensor shaped `{height, width, 3}`."
    @spec filter_tensor(Nx.Tensor.t(), {pos_integer(), pos_integer()}, keyword()) :: Nx.Tensor.t()
    def filter_tensor(
          %Nx.Tensor{shape: {source_height, source_width, 3}} = source,
          {output_width, output_height},
          options \\ []
        )
        when source_width > 0 and source_height > 0 and is_integer(output_width) and
               output_width > 0 and is_integer(output_height) and output_height > 0 and
               is_list(options) do
      parameters = parameters(options)

      args = [
        source,
        Nx.add(Nx.iota({1, output_width}, type: :f32), 0.5),
        Nx.add(Nx.iota({output_height, 1}, type: :f32), 0.5),
        parameters
      ]

      key =
        {__MODULE__, @compiled_version, Nx.type(source), source_width, source_height,
         output_width, output_height}

      compiled(key, args) |> apply(args)
    end

    @doc false
    defn render(source, output_x, output_y, parameters) do
      source_height = Nx.axis_size(source, 0)
      source_width = Nx.axis_size(source, 1)
      output_height = Nx.axis_size(output_y, 0)
      output_width = Nx.axis_size(output_x, 1)
      tau = @tau

      u = output_x / output_width
      v = output_y / output_height
      original = sample_nearest(source, u, v) |> Nx.as_type(:f32) |> Nx.divide(255.0)

      angle_x = u * tau * source_width
      angle_y = v * tau * source_height

      yfactor =
        (parameter(parameters, :brighten_scanlines) + Nx.sin(angle_y)) /
          (parameter(parameters, :brighten_scanlines) + 1.0)

      offsets =
        Nx.tensor(
          [1.570796327, -0.523598776, -2.617993878],
          type: :f32
        )
        |> Nx.reshape({1, 1, 3})

      xfactors =
        (parameter(parameters, :brighten_lcd) + Nx.sin(Nx.new_axis(angle_x, 2) + offsets)) /
          (parameter(parameters, :brighten_lcd) + 1.0)

      lcd = original * Nx.new_axis(yfactor, 2) * xfactors
      hide_content = parameter(parameters, :hide_content)
      hidden = hide_content > 0.5
      lcd = Nx.select(hidden, 1.0, lcd)
      original = Nx.select(hidden, 1.0, original)

      highlights = parameter(parameters, :highlights)
      lcd_luma = perceptual_brightness(lcd)
      dimmed = lcd * Nx.new_axis(Nx.max(1.0 + highlights * lcd_luma, 0.0), 2)
      lcd = Nx.select(highlights < -0.001, dimmed, lcd)
      current_is_white = white_pixel?(original, parameter(parameters, :threshold))

      background = procedural_background(u, v, parameter(parameters, :backing_brightness))
      background = apply_shadow(background, source, u, v, parameters, output_width, output_height)
      background = tint_background(background, parameters)

      grid = parameter(parameters, :brightness_grid)
      white_blend = smoothstep(0.05, 1.0, grid)
      white_grid_source = mix(original, lcd, white_blend)

      white_mask =
        current_is_white
        |> Nx.new_axis(2)
        |> Nx.broadcast({output_height, output_width, 3})

      grid_source = Nx.select(white_mask, white_grid_source, lcd)
      brightness_source = Nx.select(grid > 0.001, grid_source, original)
      pixel_intensity = brightness(brightness_source, parameter(parameters, :brightness_mode))

      base_alpha = parameter(parameters, :base_alpha)
      white_alpha = parameter(parameters, :white_transparency)
      boosted = current_is_white and parameter(parameters, :white_boost) > 0.5
      bright_alpha = Nx.clip(base_alpha * pixel_intensity * 2.665, 0.0, 1.0)
      bright_alpha = Nx.select(boosted, Nx.max(bright_alpha, white_alpha), bright_alpha)
      bright_output = mix(lcd, background, Nx.new_axis(bright_alpha, 2))

      pixel_alpha = Nx.clip(pixel_intensity / 3.0 + base_alpha, 0.0, 1.0)
      pixel_alpha = Nx.select(boosted, Nx.max(pixel_alpha, white_alpha), pixel_alpha)
      applied = mix(lcd, background, Nx.new_axis(pixel_alpha, 2))
      pixel_mode = parameter(parameters, :pixel_mode)
      should_apply = current_is_white or pixel_mode >= 0.5

      apply_mask =
        should_apply
        |> Nx.new_axis(2)
        |> Nx.broadcast({output_height, output_width, 3})

      other_output = Nx.select(apply_mask, applied, lcd)
      output = Nx.select(pixel_mode > 0.5 and pixel_mode < 1.5, bright_output, other_output)

      polarizer = Nx.tensor([0.94, 1.0, 0.865], type: :f32) |> Nx.reshape({1, 1, 3})

      polarizer =
        mix(Nx.broadcast(1.0, {1, 1, 3}), polarizer, parameter(parameters, :polarizer_tint))

      polarizer_enabled = parameter(parameters, :polarizer) > 0.5
      output = Nx.select(polarizer_enabled, output * polarizer, output)

      output_luma = perceptual_brightness(output)
      lifted = Nx.clip(output * Nx.new_axis(1.0 + highlights * output_luma, 2), 0.0, 1.0)
      output = Nx.select(highlights > 0.001, lifted, output)

      saturation = parameter(parameters, :saturation)
      gray = Nx.new_axis(perceptual_brightness(output), 2)
      output = Nx.clip(mix(gray, output, saturation), 0.0, 1.0)
      dither = (hash2(output_x, output_y) - 0.5) / 255.0

      (output + Nx.new_axis(dither, 2))
      |> Nx.clip(0.0, 1.0)
      |> Nx.multiply(255.0)
      |> Nx.round()
      |> Nx.as_type(:u8)
    end

    defnp apply_shadow(background, source, u, v, parameters, output_width, output_height) do
      scale = Nx.sqrt(output_width / 640.0 * (output_height / 480.0))
      offset_x = -parameter(parameters, :shadow_offset_x) * scale / output_width
      offset_y = -parameter(parameters, :shadow_offset_y) * scale / output_height
      blur_x = parameter(parameters, :shadow_blur) * scale / output_width
      blur_y = parameter(parameters, :shadow_blur) * scale / output_height
      center_u = u + offset_x
      center_v = v + offset_y

      center = shadow_sample(source, center_u, center_v, parameters)
      left = shadow_sample(source, center_u - blur_x, center_v, parameters)
      right = shadow_sample(source, center_u + blur_x, center_v, parameters)
      up = shadow_sample(source, center_u, center_v - blur_y, parameters)
      down = shadow_sample(source, center_u, center_v + blur_y, parameters)
      upper_left = shadow_sample(source, center_u - blur_x, center_v - blur_y, parameters)
      upper_right = shadow_sample(source, center_u + blur_x, center_v - blur_y, parameters)
      lower_left = shadow_sample(source, center_u - blur_x, center_v + blur_y, parameters)
      lower_right = shadow_sample(source, center_u + blur_x, center_v + blur_y, parameters)

      cross = (center * 4.0 + (left + right + up + down) * 2.0) / 12.0

      grid =
        (center * 4.0 + (left + right + up + down) * 2.0 + upper_left + upper_right +
           lower_left + lower_right) / 16.0

      blurred = Nx.select(parameter(parameters, :shadow_fast_blur) < 0.5, cross, grid)
      shadow = Nx.select(parameter(parameters, :shadow_blur) > 0.1, blurred, center)
      shadow = shadow * parameter(parameters, :shadow_opacity)

      deadzone =
        (1.0 - parameter(parameters, :threshold)) * parameter(parameters, :shadow_opacity)

      shadow = Nx.select(deadzone > 0.001, smoothstep(0.0, deadzone, shadow) * shadow, shadow)
      shadow = Nx.clip(shadow, 0.0, 1.0)
      shadowed = background * Nx.new_axis(1.0 - shadow * 0.8, 2)

      enabled =
        parameter(parameters, :shadow_enable) > 0.5 and
          parameter(parameters, :hide_content) < 1.5

      Nx.select(enabled, shadowed, background)
    end

    defnp shadow_sample(source, u, v, parameters) do
      sample = source |> sample_linear(u, v) |> Nx.as_type(:f32) |> Nx.divide(255.0)
      1.0 - brightness(sample, parameter(parameters, :brightness_mode))
    end

    defnp procedural_background(u, v, backing_brightness) do
      p_x = u * 128.0
      p_y = v * 128.0

      grain =
        hash2(p_x, p_y) * 0.5 + hash2(p_x * 2.0, p_y * 2.0) * 0.25 +
          hash2(p_x * 4.0, p_y * 4.0) * 0.125

      value = backing_brightness + (grain - 0.4375) * 0.065
      Nx.new_axis(value, 2) |> Nx.broadcast({Nx.axis_size(v, 0), Nx.axis_size(u, 1), 3})
    end

    defnp tint_background(background, parameters) do
      palette = parameter(parameters, :palette)
      warm1 = Nx.tensor([0.651, 0.675, 0.518], type: :f32)
      warm2 = Nx.tensor([0.72, 0.73, 0.66], type: :f32)
      neutral = Nx.tensor([0.766, 0.73, 0.763], type: :f32)
      aluminum = Nx.tensor([0.76, 0.76, 0.76], type: :f32)

      color =
        Nx.select(
          palette < 1.5,
          warm1,
          Nx.select(palette < 2.5, warm2, Nx.select(palette < 3.5, neutral, aluminum))
        )

      color = color * (0.675 / Nx.reduce_max(color))
      color = Nx.reshape(color, {1, 1, 3})
      tinted = Nx.clip(color + (background * 2.0 - 1.0), 0.0, 1.0)
      tinted = mix(background, tinted, parameter(parameters, :palette_intensity))
      Nx.select(palette > 0.5, tinted, background)
    end

    defnp white_pixel?(color, threshold) do
      perceptual_brightness(color) > threshold and
        Nx.reduce_min(color, axes: [2]) > threshold * 0.9
    end

    defnp brightness(color, mode) do
      average = Nx.mean(color, axes: [2])
      Nx.select(mode < 0.5, average, perceptual_brightness(color))
    end

    defnp perceptual_brightness(color) do
      color[[.., .., 0]] * 0.2126 + color[[.., .., 1]] * 0.7152 + color[[.., .., 2]] * 0.0722
    end

    defnp sample_nearest(source, u, v) do
      height = Nx.axis_size(source, 0)
      width = Nx.axis_size(source, 1)
      x = Nx.floor(u * width) |> Nx.clip(0, width - 1) |> Nx.as_type(:s32)
      y = Nx.floor(v * height) |> Nx.clip(0, height - 1) |> Nx.as_type(:s32)
      source = Nx.reshape(source, {height * width, 3})
      Nx.take(source, y * width + x)
    end

    defnp sample_linear(source, u, v) do
      height = Nx.axis_size(source, 0)
      width = Nx.axis_size(source, 1)
      sample_x = u * width - 0.5
      sample_y = v * height - 0.5
      x0 = Nx.floor(sample_x) |> Nx.clip(0, width - 1) |> Nx.as_type(:s32)
      y0 = Nx.floor(sample_y) |> Nx.clip(0, height - 1) |> Nx.as_type(:s32)
      x1 = Nx.min(x0 + 1, width - 1)
      y1 = Nx.min(y0 + 1, height - 1)
      x_weight = Nx.clip(sample_x - Nx.as_type(x0, :f32), 0.0, 1.0) |> Nx.new_axis(2)
      y_weight = Nx.clip(sample_y - Nx.as_type(y0, :f32), 0.0, 1.0) |> Nx.new_axis(2)
      source = Nx.reshape(source, {height * width, 3}) |> Nx.as_type(:f32)
      top_left = Nx.take(source, y0 * width + x0)
      top_right = Nx.take(source, y0 * width + x1)
      bottom_left = Nx.take(source, y1 * width + x0)
      bottom_right = Nx.take(source, y1 * width + x1)
      top = mix(top_left, top_right, x_weight)
      bottom = mix(bottom_left, bottom_right, x_weight)
      mix(top, bottom, y_weight)
    end

    defnp hash2(x, y) do
      p3x = fract(x * 0.1031)
      p3y = fract(y * 0.1031)
      p3z = fract(x * 0.1031)
      dot = p3x * (p3y + 33.33) + p3y * (p3z + 33.33) + p3z * (p3x + 33.33)
      p3x = p3x + dot
      p3y = p3y + dot
      p3z = p3z + dot
      fract((p3x + p3y) * p3z)
    end

    defnp(fract(value), do: value - Nx.floor(value))
    defnp(mix(a, b, amount), do: a + (b - a) * amount)

    defnp smoothstep(edge0, edge1, value) do
      t = Nx.clip((value - edge0) / (edge1 - edge0), 0.0, 1.0)
      t * t * (3.0 - 2.0 * t)
    end

    defp parameters(options) do
      options
      |> Keyword.validate!(@defaults)
      |> then(fn values -> Enum.map(@parameter_names, &Keyword.fetch!(values, &1)) end)
      |> Nx.tensor(type: :f32)
    end

    defp compiled(key, args) do
      case :persistent_term.get(key, nil) do
        nil ->
          compiled = EXLA.compile(&render/4, Enum.map(args, &Nx.to_template/1), client: :host)
          :persistent_term.put(key, compiled)
          compiled

        compiled ->
          compiled
      end
    end
  end
end
