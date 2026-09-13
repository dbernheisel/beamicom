# SPDX-License-Identifier: LGPL-2.1-or-later

defmodule Beamicom.NES.Nx.BlarggNTSC.Table do
  @moduledoc false

  # This is an Elixir port of the kernel setup in Shay Green's nes_ntsc 0.2.2.
  # The runtime blitter is implemented with Nx in `Beamicom.NES.Nx.BlarggNTSC`.
  # nes_ntsc is licensed under LGPL-2.1-or-later; see LICENSES in this package.

  import Bitwise

  @pi 3.14159265358979323846
  @rgb_unit 256
  @rgb_offset 512.5
  @rgb_builder 1 <<< 21 ||| 1 <<< 11 ||| 1 <<< 1
  @rgb_bias @rgb_unit * 2 * @rgb_builder
  @kernel_half 16
  @kernel_size 33
  @burst_size 42
  @rgb_kernel_size 14

  @levels {
    {-0.12, 0.40},
    {0.00, 0.68},
    {0.31, 1.00},
    {0.72, 1.00}
  }

  @phases {
    -1.0,
    -0.866025,
    -0.5,
    0.0,
    0.5,
    0.866025,
    1.0,
    0.866025,
    0.5,
    0.0,
    -0.5,
    -0.866025,
    -1.0,
    -0.866025,
    -0.5,
    0.0,
    0.5,
    0.866025,
    1.0
  }

  @decoder {0.956, 0.621, -0.272, -0.647, -1.105, 1.702}
  @pixel_info [
    {353, 1.0, {1.0, 1.0, 0.6667, 0.0}},
    {22, -1.0, {0.3333, 1.0, 1.0, 0.3333}},
    {154, 1.0, {0.0, 0.6667, 1.0, 1.0}}
  ]

  @type setup :: %{
          hue: float(),
          saturation: float(),
          contrast: float(),
          brightness: float(),
          sharpness: float(),
          gamma: float(),
          resolution: float(),
          artifacts: float(),
          fringing: float(),
          bleed: float(),
          merge_fields: boolean()
        }

  @doc false
  def preset(:composite),
    do: setup(artifacts: 0.0, fringing: 0.0, bleed: 0.0, sharpness: 0.0, resolution: 0.0)

  def preset(:svideo),
    do: setup(artifacts: -1.0, fringing: -1.0, bleed: 0.0, sharpness: 0.2, resolution: 0.2)

  def preset(:rgb),
    do: setup(artifacts: -1.0, fringing: -1.0, bleed: -1.0, sharpness: 0.2, resolution: 0.7)

  def preset(:monochrome),
    do:
      setup(
        saturation: -1.0,
        sharpness: 0.2,
        resolution: 0.2,
        artifacts: -0.2,
        fringing: -0.2,
        bleed: -1.0
      )

  @doc false
  def generate(preset) when is_atom(preset), do: preset |> preset() |> generate()

  def generate(%{} = setup) do
    impl = init(setup)

    0..63
    |> Enum.flat_map(&entry(&1, setup, impl))
    |> Nx.tensor(type: :s64)
    |> Nx.reshape({64, 128})
  end

  defp setup(overrides) do
    Map.merge(
      %{
        hue: 0.0,
        saturation: 0.0,
        contrast: 0.0,
        brightness: 0.0,
        sharpness: 0.0,
        gamma: 0.0,
        resolution: 0.0,
        artifacts: 0.0,
        fringing: 0.0,
        bleed: 0.0,
        merge_fields: true
      },
      Map.new(overrides)
    )
  end

  defp init(setup) do
    artifacts = scale_artifacts(setup.artifacts, 1.5)
    fringing = scale_artifacts(setup.fringing, 2.0)
    kernel = init_filters(setup)

    hue = f32(setup.hue * @pi - @pi / 12)
    saturation = f32(setup.saturation + 1.0)
    sin_hue = f32(:math.sin(hue) * saturation)
    cos_hue = f32(:math.cos(hue) * saturation)

    {to_rgb, _sin_hue, _cos_hue} =
      Enum.reduce(0..2, {[], sin_hue, cos_hue}, fn _burst, {all, sin_phase, cos_phase} ->
        matrix =
          @decoder
          |> Tuple.to_list()
          |> Enum.chunk_every(2)
          |> Enum.flat_map(fn [i, q] ->
            [f32(i * cos_phase - q * sin_phase), f32(i * sin_phase + q * cos_phase)]
          end)

        rotated_sin = f32(sin_phase * -0.5 - cos_phase * 0.866025)
        rotated_cos = f32(sin_phase * 0.866025 + cos_phase * -0.5)
        {all ++ matrix, rotated_sin, rotated_cos}
      end)

    %{
      artifacts: artifacts,
      fringing: fringing,
      kernel: List.to_tuple(kernel),
      to_rgb: to_rgb |> Enum.chunk_every(6) |> Enum.map(&List.to_tuple/1)
    }
  end

  defp scale_artifacts(value, maximum) do
    value = if value > 0, do: value * (maximum - 1.0), else: value
    value + 1.0
  end

  defp init_filters(setup) do
    chroma = chroma_kernel(setup.bleed)
    luma = luma_kernel(setup.sharpness, setup.resolution)

    Enum.reduce(1..7, {[], 1.0}, fn _phase, {out, weight} ->
      weight = f32(weight - 1.0 / 8.0)

      {phase, _remain} =
        Enum.map_reduce(chroma ++ luma, 0.0, fn current, remain ->
          mixed = f32(current * weight)
          {f32(mixed + remain), f32(current - mixed)}
        end)

      {out ++ phase, weight}
    end)
    |> elem(0)
  end

  defp luma_kernel(sharpness, resolution) do
    rolloff = f32(1.0 + sharpness * 0.032)
    max_harmonic = 32.0
    pow_a_n = f32(:math.pow(rolloff, max_harmonic))
    angle_scale = f32(resolution + 1.0)
    angle_scale = f32(@pi / max_harmonic * 0.20 * (angle_scale * angle_scale + 1.0))

    values =
      for offset <- -@kernel_half..@kernel_half do
        value =
          if offset == 0 and pow_a_n <= 1.056 and pow_a_n >= 0.981 do
            max_harmonic
          else
            angle = f32(offset * angle_scale)
            rolloff_cos = f32(rolloff * :math.cos(angle))

            numerator =
              1.0 - rolloff_cos - pow_a_n * :math.cos(max_harmonic * angle) +
                pow_a_n * rolloff * :math.cos((max_harmonic - 1.0) * angle)

            denominator = 1.0 - 2.0 * rolloff_cos + rolloff * rolloff
            f32(numerator / denominator - 0.5)
          end

        index = offset + @kernel_half
        angle = @pi * 2.0 / (@kernel_half * 2) * index
        blackman = 0.42 - 0.5 * :math.cos(angle) + 0.08 * :math.cos(angle * 2.0)
        f32(value * blackman)
      end

    total = Enum.sum(values)
    Enum.map(values, &f32(&1 / total))
  end

  defp chroma_kernel(bleed) do
    cutoff =
      if bleed < 0 do
        powered = bleed |> square() |> square() |> square()
        powered * (-30.0 / 0.65)
      else
        bleed
      end

    cutoff = -0.03125 - 0.65 * -0.03125 * cutoff

    values =
      for offset <- -@kernel_half..@kernel_half,
          do: f32(:math.exp(offset * offset * cutoff))

    for {value, index} <- Enum.with_index(values) do
      parity_sum =
        values
        |> Enum.with_index()
        |> Enum.reduce(0.0, fn {candidate, candidate_index}, sum ->
          if rem(candidate_index, 2) == rem(index, 2), do: sum + candidate, else: sum
        end)

      f32(value / parity_sum)
    end
  end

  defp square(value), do: value * value

  defp entry(index, setup, impl) do
    level = index >>> 4 &&& 0x03
    {lo, hi} = elem(@levels, level)
    color = index &&& 0x0F

    {lo, hi} =
      cond do
        color == 0 -> {hi, hi}
        color == 0x0D -> {lo, lo}
        color > 0x0D -> {0.0, 0.0}
        true -> {lo, hi}
      end

    saturation = f32((hi - lo) * 0.5)
    i = f32(elem(@phases, color) * saturation)
    q = f32(elem(@phases, color + 3) * saturation)
    y = f32((hi + lo) * 0.5)
    y = f32(y * f32(setup.contrast * 0.5 + 1.0))
    y = f32(y + f32(setup.brightness * 0.5) - f32(0.5 / 256.0))

    gamma = f32(setup.gamma * -0.5 + 0.1333)

    gamma_factor =
      f32(:math.pow(abs(gamma), 0.73) * if(gamma < 0, do: -1.0, else: 1.0))

    {r, g, b} = yiq_to_rgb(y, i, q, @decoder)
    r = f32(f32(f32(r * gamma_factor) - gamma_factor) * r + r)
    g = f32(f32(f32(g * gamma_factor) - gamma_factor) * g + g)
    b = f32(f32(f32(b * gamma_factor) - gamma_factor) * b + b)
    {y, i, q} = rgb_to_yiq(r, g, b)

    y = f32(f32(y * @rgb_unit) + @rgb_offset)
    i = f32(i * @rgb_unit)
    q = f32(q * @rgb_unit)
    {r, g, b} = yiq_to_rgb(y, i, q, hd(impl.to_rgb))
    color_value = pack_rgb(trunc(r), trunc(g), min(trunc(b), 0x3E0))

    kernel = generate_kernel(y, i, q, impl)
    kernel = if setup.merge_fields, do: merge_fields(kernel), else: kernel
    correct_errors(color_value, kernel) ++ [0, 0]
  end

  defp generate_kernel(y, initial_i, initial_q, impl) do
    {_i, _q, entries} =
      Enum.reduce(0..2, {initial_i, initial_q, []}, fn burst, {i, q, all} ->
        matrix = Enum.at(impl.to_rgb, burst)

        burst_entries =
          Enum.flat_map(@pixel_info, fn {offset, negate, weights} ->
            {c0, c1, c2, c3} = weights
            base_y = f32(y - @rgb_offset)
            yy = f32(f32(base_y * impl.fringing) * negate)
            ic0 = f32(f32(i + yy) * c0)
            qc1 = f32(f32(q + yy) * c1)
            ic2 = f32(f32(i - yy) * c2)
            qc3 = f32(f32(q - yy) * c3)
            factor = f32(impl.artifacts * negate)
            ii = f32(i * factor)
            qq = f32(q * factor)
            yc0 = f32(f32(base_y + ii) * c0)
            yc2 = f32(f32(base_y - ii) * c2)
            yc1 = f32(f32(base_y + qq) * c1)
            yc3 = f32(f32(base_y - qq) * c3)

            {values, _offset} =
              Enum.map_reduce(1..@rgb_kernel_size, offset, fn _sample, kernel_offset ->
                chroma_i =
                  f32(
                    f32(at(impl.kernel, kernel_offset) * ic0) +
                      f32(at(impl.kernel, kernel_offset + 2) * ic2)
                  )

                chroma_q =
                  f32(
                    f32(at(impl.kernel, kernel_offset + 1) * qc1) +
                      f32(at(impl.kernel, kernel_offset + 3) * qc3)
                  )

                luma =
                  f32(
                    f32(at(impl.kernel, kernel_offset + @kernel_size) * yc0) +
                      f32(at(impl.kernel, kernel_offset + @kernel_size + 1) * yc1) +
                      f32(at(impl.kernel, kernel_offset + @kernel_size + 2) * yc2) +
                      f32(at(impl.kernel, kernel_offset + @kernel_size + 3) * yc3) +
                      @rgb_offset
                  )

                {red, green, blue} = yiq_to_rgb(luma, chroma_i, chroma_q, matrix)
                packed = pack_rgb(trunc(red), trunc(green), trunc(blue)) - @rgb_bias

                next_offset =
                  if kernel_offset < @kernel_size * 2 * 6,
                    do: kernel_offset + @kernel_size * 2 - 1,
                    else: kernel_offset - (@kernel_size * 2 * 6 + 2)

                {packed, next_offset}
              end)

            values
          end)

        rotated_i = f32(i * -0.5 - q * -0.866025)
        rotated_q = f32(i * -0.866025 + q * -0.5)
        {rotated_i, rotated_q, all ++ burst_entries}
      end)

    entries
  end

  defp correct_errors(color, kernel) do
    Enum.reduce(0..2, kernel, fn burst, corrected ->
      base = burst * @burst_size

      Enum.reduce(0..6, corrected, fn index, values ->
        error =
          color - at(values, base + index) - at(values, base + rem(index + 12, 14) + 14) -
            at(values, base + rem(index + 10, 14) + 28) - at(values, base + index + 7) -
            at(values, base + index + 5 + 14) - at(values, base + index + 3 + 28)

        fourth =
          ((error + 2 * @rgb_builder) >>> 2)
          |> band((@rgb_bias >>> 1) - @rgb_builder)
          |> Kernel.-(@rgb_bias >>> 2)

        values
        |> add_at(base + index + 3 + 28, fourth)
        |> add_at(base + index + 5 + 14, fourth)
        |> add_at(base + index + 7, fourth)
        |> add_at(base + index, error - fourth * 3)
      end)
    end)
  end

  defp merge_fields(kernel) do
    Enum.reduce(0..(@burst_size - 1), kernel, fn index, values ->
      p0 = at(values, index) + @rgb_bias
      p1 = at(values, @burst_size + index) + @rgb_bias
      p2 = at(values, @burst_size * 2 + index) + @rgb_bias

      values
      |> List.replace_at(index, div(p0 + p1 - band(bxor(p0, p1), @rgb_builder), 2) - @rgb_bias)
      |> List.replace_at(
        @burst_size + index,
        div(p1 + p2 - band(bxor(p1, p2), @rgb_builder), 2) - @rgb_bias
      )
      |> List.replace_at(
        @burst_size * 2 + index,
        div(p2 + p0 - band(bxor(p2, p0), @rgb_builder), 2) - @rgb_bias
      )
    end)
  end

  defp rgb_to_yiq(r, g, b) do
    {f32(r * 0.299 + g * 0.587 + b * 0.114), f32(r * 0.596 - g * 0.275 - b * 0.321),
     f32(r * 0.212 - g * 0.523 + b * 0.311)}
  end

  defp yiq_to_rgb(y, i, q, matrix) do
    {f32(y + elem(matrix, 0) * i + elem(matrix, 1) * q),
     f32(y + elem(matrix, 2) * i + elem(matrix, 3) * q),
     f32(y + elem(matrix, 4) * i + elem(matrix, 5) * q)}
  end

  defp pack_rgb(r, g, b), do: r <<< 21 ||| g <<< 11 ||| b <<< 1
  defp at(tuple, index) when is_tuple(tuple), do: elem(tuple, index)
  defp at(list, index), do: Enum.at(list, index)
  defp add_at(list, index, amount), do: List.update_at(list, index, &(&1 + amount))

  defp f32(value) do
    <<rounded::native-float-32>> = <<value::native-float-32>>
    rounded
  end
end
