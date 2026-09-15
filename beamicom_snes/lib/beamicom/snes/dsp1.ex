defmodule Beamicom.SNES.DSP1 do
  @moduledoc """
  Host-side command processor for the NEC uPD77C25 DSP-1 family.

  The S-CPU sees one byte-wide command/data port mirrored through a
  mapper-dependent window. Commands and 16-bit parameters are transferred
  least-significant byte first. The native high-level implementation retains
  projection and attitude state across commands and supports streamed Raster
  results. The geometry path follows the firmware's signed fixed-point
  normalization and truncation rules; command-cycle busy timing remains future
  accuracy work.
  """

  import Bitwise
  alias Beamicom.SNES.Cartridge

  # The firmware interpolates two 256-entry sine tables. Generate the same
  # integer samples at compile time so command execution has no floating-point
  # work or trigonometric calls in its hot path.
  @sin_table (for index <- 0..255 do
                value = trunc(:math.sin(index * 2 * :math.pi() / 256) * 32_768)

                case index do
                  64 -> 32_767
                  192 -> -32_767
                  _ -> value
                end
              end)
             |> List.to_tuple()

  @mul_table (for index <- 0..255 do
                value = trunc(:math.sin(index * 2 * :math.pi() / 65_536) * 32_768)
                if index in [113, 198, 205, 212, 219, 226], do: value + 1, else: value
              end)
             |> List.to_tuple()

  @inverse_table (for index <- 0..127 do
                    min(32_767, round((1 <<< 29) / (0x4000 + index * 0x80)))
                  end)
                 |> List.to_tuple()

  @max_azs {0x38B4, 0x38B7, 0x38BA, 0x38BE, 0x38C0, 0x38C4, 0x38C7, 0x38CA, 0x38CE, 0x38D0,
            0x38D4, 0x38D7, 0x38DA, 0x38DD, 0x38E0, 0x38E4}

  @parameter_words %{
    0x00 => 2,
    0x20 => 2,
    0x10 => 2,
    0x30 => 2,
    0x04 => 2,
    0x24 => 2,
    0x08 => 3,
    0x18 => 4,
    0x28 => 3,
    0x38 => 4,
    0x0C => 3,
    0x2C => 3,
    0x1C => 6,
    0x3C => 6,
    0x02 => 7,
    0x12 => 7,
    0x22 => 7,
    0x32 => 7,
    0x0A => 1,
    0x1A => 1,
    0x2A => 1,
    0x3A => 1,
    0x06 => 3,
    0x16 => 3,
    0x26 => 3,
    0x36 => 3,
    0x0E => 2,
    0x1E => 2,
    0x2E => 2,
    0x3E => 2,
    0x01 => 4,
    0x05 => 4,
    0x31 => 4,
    0x35 => 4,
    0x11 => 4,
    0x15 => 4,
    0x21 => 4,
    0x25 => 4,
    0x0D => 3,
    0x09 => 3,
    0x39 => 3,
    0x3D => 3,
    0x1D => 3,
    0x19 => 3,
    0x2D => 3,
    0x29 => 3,
    0x03 => 3,
    0x33 => 3,
    0x13 => 3,
    0x23 => 3,
    0x0B => 3,
    0x3B => 3,
    0x1B => 3,
    0x2B => 3,
    0x14 => 6,
    0x34 => 6,
    0x0F => 1,
    0x07 => 1,
    0x2F => 1,
    0x27 => 1,
    0x1F => 1,
    0x17 => 1,
    0x37 => 1,
    0x3F => 1
  }

  @enforce_keys [:mapping, :boundary]
  defstruct mapping: nil,
            boundary: nil,
            command: nil,
            remaining: 0,
            parameters: <<>>,
            output: <<>>,
            output_index: 0,
            command_counts: %{},
            unsupported_commands: MapSet.new(),
            matrices: %{
              a: {{0, 0, 0}, {0, 0, 0}, {0, 0, 0}},
              b: {{0, 0, 0}, {0, 0, 0}, {0, 0, 0}},
              c: {{0, 0, 0}, {0, 0, 0}, {0, 0, 0}}
            },
            projection: nil,
            stream: nil

  @type t :: %__MODULE__{}

  @spec cartridge?(Cartridge.t()) :: boolean()
  def cartridge?(%Cartridge{header: %{cartridge_type: 0x03, map_mode: map_mode}}),
    do: (map_mode &&& 0x3F) != 0x30

  def cartridge?(%Cartridge{
        header: %{cartridge_type: 0x05, map_mode: map_mode, developer_id: developer_id}
      }) do
    speed = map_mode &&& 0x3F
    speed != 0x20 and not (speed == 0x30 and developer_id == 0xB2)
  end

  def cartridge?(%Cartridge{}), do: false

  @spec new(Cartridge.t()) :: t()
  def new(%Cartridge{layout: :hirom}), do: %__MODULE__{mapping: :hirom, boundary: 0x7000}

  def new(%Cartridge{size: size}) when size > 0x10_0000,
    do: %__MODULE__{mapping: :lorom_large, boundary: 0x4000}

  def new(%Cartridge{}), do: %__MODULE__{mapping: :lorom_small, boundary: 0xC000}

  @spec mapped?(t(), non_neg_integer()) :: boolean()
  def mapped?(%__MODULE__{mapping: mapping}, address) do
    bank = address >>> 16
    offset = address &&& 0xFFFF

    case mapping do
      :lorom_small -> (bank in 0x20..0x3F or bank in 0xA0..0xBF) and offset >= 0x8000
      :lorom_large -> (bank in 0x60..0x6F or bank in 0xE0..0xEF) and offset < 0x8000
      :hirom -> (bank in 0x00..0x1F or bank in 0x80..0x9F) and offset in 0x6000..0x7FFF
    end
  end

  @spec peek(t(), non_neg_integer()) :: byte()
  def peek(%__MODULE__{} = dsp1, address) do
    if data_port?(dsp1, address) and dsp1.output_index < byte_size(dsp1.output),
      do: :binary.at(dsp1.output, dsp1.output_index),
      else: 0x80
  end

  @spec read(t(), non_neg_integer()) :: {byte(), t()}
  def read(%__MODULE__{} = dsp1, address) do
    value = peek(dsp1, address)

    if data_port?(dsp1, address) and dsp1.output_index < byte_size(dsp1.output) do
      next = dsp1.output_index + 1

      if next == byte_size(dsp1.output),
        do: {value, refill_or_clear_output(dsp1)},
        else: {value, %{dsp1 | output_index: next}}
    else
      {value, dsp1}
    end
  end

  @spec write(t(), non_neg_integer(), byte()) :: t()
  def write(%__MODULE__{} = dsp1, address, value) do
    value = value &&& 0xFF

    cond do
      not data_port?(dsp1, address) ->
        dsp1

      not is_nil(dsp1.stream) and dsp1.output_index < byte_size(dsp1.output) ->
        discard_stream_byte(dsp1)

      is_nil(dsp1.command) ->
        start_command(dsp1, value)

      true ->
        parameters = <<dsp1.parameters::binary, value>>
        remaining = dsp1.remaining - 1
        dsp1 = %{dsp1 | parameters: parameters, remaining: remaining}
        if remaining == 0, do: finish_command(dsp1), else: dsp1
    end
  end

  defp start_command(dsp1, 0x80), do: dsp1

  defp start_command(dsp1, command) do
    case Map.fetch(@parameter_words, command) do
      {:ok, words} ->
        %{
          dsp1
          | command: command,
            remaining: words * 2,
            parameters: <<>>,
            output: <<>>,
            output_index: 0,
            stream: nil
        }

      :error ->
        %{dsp1 | unsupported_commands: MapSet.put(dsp1.unsupported_commands, command)}
    end
  end

  defp finish_command(dsp1) do
    command = dsp1.command
    count = Map.get(dsp1.command_counts, command, 0) + 1
    words = decode_words(dsp1.parameters)
    {output, supported?, dsp1} = execute(command, words, dsp1)

    %{
      dsp1
      | command: nil,
        remaining: 0,
        parameters: <<>>,
        output: output,
        output_index: 0,
        command_counts: Map.put(dsp1.command_counts, command, count),
        unsupported_commands:
          if(supported?,
            do: dsp1.unsupported_commands,
            else: MapSet.put(dsp1.unsupported_commands, command)
          )
    }
  end

  defp execute(command, [a, b], dsp1) when command in [0x00, 0x20] do
    result = ((s16(a) * s16(b)) >>> 15) + if(command == 0x20, do: 1, else: 0)
    {word(result), true, dsp1}
  end

  defp execute(command, [coefficient, exponent], dsp1) when command in [0x10, 0x30] do
    {inverse_coefficient, inverse_exponent} = inverse(s16(coefficient), s16(exponent))
    {words([inverse_coefficient, inverse_exponent]), true, dsp1}
  end

  defp execute(command, [angle, radius], dsp1) when command in [0x04, 0x24] do
    sine = q15_mul(sin_q15(angle), s16(radius))
    cosine = q15_mul(cos_q15(angle), s16(radius))
    {words([sine, cosine]), true, dsp1}
  end

  defp execute(0x08, [x, y, z], dsp1) do
    size = (s16(x) * s16(x) + s16(y) * s16(y) + s16(z) * s16(z)) <<< 1
    {words([size, size >>> 16]), true, dsp1}
  end

  defp execute(command, [x, y, z, radius], dsp1) when command in [0x18, 0x38] do
    distance =
      (s16(x) * s16(x) + s16(y) * s16(y) + s16(z) * s16(z) -
         s16(radius) * s16(radius)) >>> 15

    distance = distance + if(command == 0x38, do: 1, else: 0)
    {word(distance), true, dsp1}
  end

  defp execute(0x28, [x, y, z], dsp1) do
    squared = s16(x) * s16(x) + s16(y) * s16(y) + s16(z) * s16(z)
    {word(trunc(:math.sqrt(squared))), true, dsp1}
  end

  defp execute(command, [angle, x, y], dsp1) when command in [0x0C, 0x2C] do
    sine = sin_q15(angle)
    cosine = cos_q15(angle)
    x = s16(x)
    y = s16(y)

    {words([q15_mul(y, sine) + q15_mul(x, cosine), q15_mul(y, cosine) - q15_mul(x, sine)]), true,
     dsp1}
  end

  defp execute(command, [z_angle, y_angle, x_angle, x, y, z], dsp1)
       when command in [0x1C, 0x3C] do
    {x, y, z} = rotate_3d(z_angle, y_angle, x_angle, x, y, z)
    {words([x, y, z]), true, dsp1}
  end

  defp execute(command, parameters, dsp1) when command in [0x02, 0x12, 0x22, 0x32] do
    {output, projection} = set_projection(parameters)
    {output, true, %{dsp1 | projection: projection}}
  end

  defp execute(command, [vertical_scanline], dsp1) when command in [0x0A, 0x1A, 0x2A, 0x3A] do
    vertical_scanline = s16(vertical_scanline)
    output = raster_output(dsp1.projection, vertical_scanline)
    {output, true, %{dsp1 | stream: {:raster, wrap_s16(vertical_scanline + 1)}}}
  end

  defp execute(command, [x, y, z], dsp1) when command in [0x06, 0x16, 0x26, 0x36] do
    {horizontal, vertical, scale} = project(dsp1.projection, s16(x), s16(y), s16(z))
    {words([horizontal, vertical, scale]), true, dsp1}
  end

  defp execute(command, [horizontal, vertical], dsp1)
       when command in [0x0E, 0x1E, 0x2E, 0x3E] do
    {x, y} = target(dsp1.projection, s16(horizontal), s16(vertical))
    {words([x, y]), true, dsp1}
  end

  defp execute(command, parameters, dsp1)
       when command in [0x01, 0x05, 0x31, 0x35, 0x11, 0x15, 0x21, 0x25] do
    slot = matrix_slot(command)
    matrix = attitude_matrix(parameters)
    {<<>>, true, put_in(dsp1.matrices[slot], matrix)}
  end

  defp execute(command, [x, y, z], dsp1)
       when command in [0x0D, 0x09, 0x39, 0x3D, 0x1D, 0x19, 0x2D, 0x29] do
    matrix = Map.fetch!(dsp1.matrices, matrix_slot(command))
    {forward, left, up} = objective(matrix, {s16(x), s16(y), s16(z)})
    {words([forward, left, up]), true, dsp1}
  end

  defp execute(command, [forward, left, up], dsp1) when command in [0x03, 0x33, 0x13, 0x23] do
    matrix = Map.fetch!(dsp1.matrices, matrix_slot(command))
    {x, y, z} = subjective(matrix, {s16(forward), s16(left), s16(up)})
    {words([x, y, z]), true, dsp1}
  end

  defp execute(command, [x, y, z], dsp1) when command in [0x0B, 0x3B, 0x1B, 0x2B] do
    matrix = Map.fetch!(dsp1.matrices, matrix_slot(command))
    {word(scalar(matrix, {s16(x), s16(y), s16(z)})), true, dsp1}
  end

  defp execute(command, [zr, xr, yr, up, forward, left], dsp1) when command in [0x14, 0x34] do
    {zr, xr, yr} = gyrate(zr, xr, yr, up, forward, left)
    {words([zr, xr, yr]), true, dsp1}
  end

  defp execute(command, [_ram_size], dsp1) when command in [0x07, 0x0F],
    do: {word(0), true, dsp1}

  defp execute(command, [_unknown], dsp1) when command in [0x27, 0x2F],
    do: {word(0x0100), true, dsp1}

  defp execute(_command, _words, dsp1), do: {<<>>, false, dsp1}

  defp refill_or_clear_output(%{stream: {:raster, vertical_scanline}} = dsp1) do
    %{
      dsp1
      | output: raster_output(dsp1.projection, vertical_scanline),
        output_index: 0,
        stream: {:raster, wrap_s16(vertical_scanline + 1)}
    }
  end

  defp refill_or_clear_output(dsp1), do: %{dsp1 | output: <<>>, output_index: 0}

  defp discard_stream_byte(dsp1) do
    next = dsp1.output_index + 1

    if next == byte_size(dsp1.output),
      do: %{dsp1 | output: <<>>, output_index: 0, stream: nil},
      else: %{dsp1 | output_index: next}
  end

  defp set_projection([fx, fy, fz, lfe, les, azimuth, zenith]) do
    fx = s16(fx)
    fy = s16(fy)
    fz = s16(fz)
    lfe = s16(lfe)
    les = s16(les)
    azimuth = s16(azimuth)
    zenith = s16(zenith)
    sin_azimuth = sin_q15(azimuth)
    cos_azimuth = cos_q15(azimuth)
    sin_zenith = sin_q15(zenith)
    cos_zenith = cos_q15(zenith)
    nx = i16((sin_zenith * -sin_azimuth) >>> 15)
    ny = i16((sin_zenith * cos_azimuth) >>> 15)
    nz = i16((cos_zenith * 0x7FFF) >>> 15)
    centre_x = i16(fx + ((lfe * nx) >>> 15))
    centre_y = i16(fy + ((lfe * ny) >>> 15))
    centre_z = i16(fz + ((lfe * nz) >>> 15))
    gx = i16(centre_x - ((les * nx) >>> 15))
    gy = i16(centre_y - ((les * ny) >>> 15))
    gz = i16(centre_z - ((les * nz) >>> 15))
    {c_les, e_les} = normalize(les, 0)
    {vplane_c, vplane_e} = normalize(centre_z, 0)
    max_azs = elem(@max_azs, -vplane_e)

    {clipped_zenith, max_azs} =
      if zenith < 0 do
        max_azs = -max_azs
        {if(zenith < max_azs + 1, do: max_azs + 1, else: zenith), max_azs}
      else
        {if(zenith > max_azs, do: max_azs, else: zenith), max_azs}
      end

    sin_zenith_clipped = sin_q15(clipped_zenith)
    cos_zenith_clipped = cos_q15(clipped_zenith)
    {sec_azs_c1, sec_azs_e1} = inverse(cos_zenith_clipped, 0)
    {c, e} = normalize(i16((vplane_c * sec_azs_c1) >>> 15), vplane_e)
    e = i16(e + sec_azs_e1)
    c = i16((truncate(c, e) * sin_zenith_clipped) >>> 15)
    centre_x = i16(centre_x + ((c * sin_azimuth) >>> 15))
    centre_y = i16(centre_y - ((c * cos_azimuth) >>> 15))

    {vertical_offset_result, cos_zenith_clipped} =
      projection_clip_correction(zenith, clipped_zenith, max_azs, les, cos_zenith_clipped)

    vertical_offset = i16((les * cos_zenith_clipped) >>> 15)
    {c_sec, e} = inverse(sin_zenith_clipped, 0)
    {c, e} = normalize(vertical_offset, e)
    {c, e} = normalize(i16((c * c_sec) >>> 15), e)

    {c, e} =
      if c == -32_768,
        do: {c >>> 1, i16(e + 1)},
        else: {c, e}

    vertical_vanish = truncate(i16(-c), e)
    {sec_azs_c2, sec_azs_e2} = inverse(cos_zenith_clipped, 0)

    projection = %{
      sin_aas: sin_azimuth,
      cos_aas: cos_azimuth,
      sin_azs: sin_zenith,
      cos_azs: cos_zenith,
      sin_azs_clipped: sin_zenith_clipped,
      cos_azs_clipped: cos_zenith_clipped,
      nx: nx,
      ny: ny,
      nz: nz,
      gx: gx,
      gy: gy,
      gz: gz,
      c_les: c_les,
      e_les: e_les,
      g_les: les,
      centre_x: centre_x,
      centre_y: centre_y,
      v_offset: vertical_offset,
      vplane_c: vplane_c,
      vplane_e: vplane_e,
      sec_azs_c1: sec_azs_c1,
      sec_azs_e1: sec_azs_e1,
      sec_azs_c2: sec_azs_c2,
      sec_azs_e2: sec_azs_e2
    }

    {words([vertical_offset_result, vertical_vanish, centre_x, centre_y]), projection}
  end

  defp projection_clip_correction(zenith, clipped, max_azs, les, cos_zenith)
       when zenith != clipped or zenith == max_azs do
    zenith = if zenith == -32_768, do: -32_767, else: zenith
    c = i16(zenith - max_azs)
    c = if c >= 0, do: i16(c - 1), else: c
    aux = i16(bnot(c <<< 2))
    c = i16((aux * 0x14AC) >>> 15)
    c = i16(((c * aux) >>> 15) + 0x6488)
    vertical_offset = i16(-((((c * aux) >>> 15) * les) >>> 15))
    c = i16((aux * aux) >>> 15)
    aux = i16(((c * 0x0A26) >>> 15) + 0x277A)
    correction = (((c * aux) >>> 15) * cos_zenith) >>> 15
    {vertical_offset, i16(cos_zenith + correction)}
  end

  defp projection_clip_correction(_zenith, _clipped, _max_azs, _les, cos_zenith),
    do: {0, cos_zenith}

  defp raster_output(nil, _vertical_scanline), do: words([0, 0, 0, 0])

  defp raster_output(projection, vertical_scanline) do
    denominator =
      i16(((vertical_scanline * projection.sin_azs) >>> 15) + projection.v_offset)

    {c, e} = inverse(denominator, 7)
    e = i16(e + projection.vplane_e)
    c1 = i16((c * projection.vplane_c) >>> 15)
    e1 = i16(e + projection.sec_azs_e2)
    {c, e} = normalize(c1, e)
    c = truncate(c, e)
    an = i16((c * projection.cos_aas) >>> 15)
    cn = i16((c * projection.sin_aas) >>> 15)
    {c, e1} = normalize(i16((c1 * projection.sec_azs_c2) >>> 15), e1)
    c = truncate(c, e1)
    bn = i16((c * -projection.sin_aas) >>> 15)
    dn = i16((c * projection.cos_aas) >>> 15)
    words([an, bn, cn, dn])
  end

  defp project(nil, _x, _y, _z), do: {0, 0, 0}

  defp project(projection, x, y, z) do
    {px, e4} = normalize_double(x - projection.gx)
    {py, e} = normalize_double(y - projection.gy)
    {pz, e3} = normalize_double(z - projection.gz)
    px = i16(px >>> 1)
    py = i16(py >>> 1)
    pz = i16(pz >>> 1)
    e4 = i16(e4 - 1)
    e = i16(e - 1)
    e3 = i16(e3 - 1)
    ref_e = min(e, min(e3, e4))
    px = shift_r(px, e4 - ref_e)
    py = shift_r(py, e - ref_e)
    pz = shift_r(pz, e3 - ref_e)
    c11 = i16(-((px * projection.nx) >>> 15))
    c8 = i16(-((py * projection.ny) >>> 15))
    c9 = i16(-((pz * projection.nz) >>> 15))
    c12 = i16(c11 + c8 + c9)
    aux4 = c12
    ref_e = 16 - ref_e
    aux4 = if ref_e >= 0, do: aux4 <<< ref_e, else: aux4 >>> -ref_e
    aux4 = if aux4 == -1, do: 0, else: aux4
    aux4 = aux4 >>> 1
    aux = (projection.g_les &&& 0xFFFF) + aux4
    {c10, e2} = normalize_double(aux)
    e2 = i16(15 - e2)
    {c4, e4} = inverse(c10, 0)
    c2 = i16((c4 * projection.c_les) >>> 15)

    c16 = i16((px * ((projection.cos_aas * 0x7FFF) >>> 15)) >>> 15)
    c20 = i16((py * ((projection.sin_aas * 0x7FFF) >>> 15)) >>> 15)
    c17 = i16(c16 + c20)
    c18 = i16((c17 * c2) >>> 15)
    {c19, e7} = normalize(c18, 0)
    horizontal = truncate(c19, projection.e_les - e2 + ref_e + e7)

    c21 = i16((px * ((projection.cos_azs * -projection.sin_aas) >>> 15)) >>> 15)
    c22 = i16((py * ((projection.cos_azs * projection.cos_aas) >>> 15)) >>> 15)
    c23 = i16((pz * ((-projection.sin_azs * 0x7FFF) >>> 15)) >>> 15)
    c24 = i16(c21 + c22 + c23)
    c26 = i16((c24 * c2) >>> 15)
    {c25, e6} = normalize(c26, 0)
    vertical = truncate(c25, projection.e_les - e2 + ref_e + e6)
    {c6, e4} = normalize(c2, e4)
    scale = truncate(c6, e4 + projection.e_les - e2 - 7)
    {horizontal, vertical, scale}
  end

  defp target(nil, _horizontal, _vertical), do: {0, 0}

  defp target(projection, horizontal, vertical) do
    denominator = i16(((vertical * projection.sin_azs) >>> 15) + projection.v_offset)
    {c, e} = inverse(denominator, 8)
    e = i16(e + projection.vplane_e)
    c1 = i16((c * projection.vplane_c) >>> 15)
    e1 = i16(e + projection.sec_azs_e1)
    horizontal = i16(horizontal <<< 8)
    {c, e} = normalize(c1, e)
    c = i16((truncate(c, e) * horizontal) >>> 15)
    x = i16(projection.centre_x + ((c * projection.cos_aas) >>> 15))
    y = i16(projection.centre_y - ((c * projection.sin_aas) >>> 15))
    vertical = i16(vertical <<< 8)
    {c, e1} = normalize(i16((c1 * projection.sec_azs_c1) >>> 15), e1)
    c = i16((truncate(c, e1) * vertical) >>> 15)
    x = i16(x + ((c * -projection.sin_aas) >>> 15))
    y = i16(y + ((c * projection.cos_aas) >>> 15))
    {x, y}
  end

  defp inverse(0, _exponent), do: {0x7FFF, 0x002F}

  defp inverse(coefficient, exponent) do
    {coefficient, sign} =
      if coefficient < 0 do
        coefficient = if coefficient < -32_767, do: -32_767, else: coefficient
        {-coefficient, -1}
      else
        {coefficient, 1}
      end

    {coefficient, exponent} = inverse_normalize(coefficient, exponent)

    if coefficient == 0x4000 do
      if sign == 1,
        do: {0x7FFF, i16(1 - exponent)},
        else: {-0x4000, i16(-exponent)}
    else
      index = (coefficient - 0x4000) >>> 7
      guess = elem(@inverse_table, index)
      guess = inverse_iteration(guess, coefficient)
      guess = inverse_iteration(guess, coefficient)
      {i16(guess * sign), i16(1 - exponent)}
    end
  end

  defp inverse_normalize(coefficient, exponent) when coefficient < 0x4000,
    do: inverse_normalize(coefficient <<< 1, i16(exponent - 1))

  defp inverse_normalize(coefficient, exponent), do: {coefficient, exponent}

  defp inverse_iteration(guess, coefficient) do
    correction = (-guess * ((coefficient * guess) >>> 15)) >>> 15
    i16((guess + correction) <<< 1)
  end

  defp attitude_matrix([m, z_angle, y_angle, x_angle]) do
    m = s16(m) >>> 1
    sin_z = sin_q15(z_angle)
    cos_z = cos_q15(z_angle)
    sin_y = sin_q15(y_angle)
    cos_y = cos_q15(y_angle)
    sin_x = sin_q15(x_angle)
    cos_x = cos_q15(x_angle)

    m_cos_z = q15_mul(m, cos_z)
    m_sin_z = q15_mul(m, sin_z)

    {
      {q15_mul(m_cos_z, cos_y), -q15_mul(m_sin_z, cos_y), q15_mul(m, sin_y)},
      {q15_mul(m_sin_z, cos_x) + q15_mul(q15_mul(m_cos_z, sin_x), sin_y),
       q15_mul(m_cos_z, cos_x) - q15_mul(q15_mul(m_sin_z, sin_x), sin_y),
       -q15_mul(q15_mul(m, sin_x), cos_y)},
      {q15_mul(m_sin_z, sin_x) - q15_mul(q15_mul(m_cos_z, cos_x), sin_y),
       q15_mul(m_cos_z, sin_x) + q15_mul(q15_mul(m_sin_z, cos_x), sin_y),
       q15_mul(q15_mul(m, cos_x), cos_y)}
    }
  end

  defp objective(matrix, {x, y, z}) do
    {row0, row1, row2} = matrix
    {row_product(row0, x, y, z), row_product(row1, x, y, z), row_product(row2, x, y, z)}
  end

  defp subjective({row0, row1, row2}, {forward, left, up}) do
    {
      q15_mul(forward, elem(row0, 0)) + q15_mul(left, elem(row1, 0)) +
        q15_mul(up, elem(row2, 0)),
      q15_mul(forward, elem(row0, 1)) + q15_mul(left, elem(row1, 1)) +
        q15_mul(up, elem(row2, 1)),
      q15_mul(forward, elem(row0, 2)) + q15_mul(left, elem(row1, 2)) +
        q15_mul(up, elem(row2, 2))
    }
  end

  defp scalar({row0, _row1, _row2}, {x, y, z}) do
    (x * elem(row0, 0) + y * elem(row0, 1) + z * elem(row0, 2)) >>> 15
  end

  defp row_product(row, x, y, z) do
    q15_mul(x, elem(row, 0)) + q15_mul(y, elem(row, 1)) + q15_mul(z, elem(row, 2))
  end

  defp rotate_3d(z_angle, y_angle, x_angle, x, y, z) do
    sin_z = sin_q15(z_angle)
    cos_z = cos_q15(z_angle)
    x1 = q15_mul(s16(y), sin_z) + q15_mul(s16(x), cos_z)
    y1 = q15_mul(s16(y), cos_z) - q15_mul(s16(x), sin_z)

    sin_y = sin_q15(y_angle)
    cos_y = cos_q15(y_angle)
    z1 = q15_mul(x1, sin_y) + q15_mul(s16(z), cos_y)
    x2 = q15_mul(x1, cos_y) - q15_mul(s16(z), sin_y)

    sin_x = sin_q15(x_angle)
    cos_x = cos_q15(x_angle)
    y2 = q15_mul(z1, sin_x) + q15_mul(y1, cos_x)
    z2 = q15_mul(z1, cos_x) - q15_mul(y1, sin_x)
    {x2, y2, z2}
  end

  defp gyrate(zr, xr, yr, up, forward, left) do
    zr = s16(zr)
    xr = s16(xr)
    yr = s16(yr)
    up = s16(up)
    forward = s16(forward)
    left = s16(left)
    sin_y = sin_q15(yr)
    cos_y = cos_q15(yr)
    sin_x = sin_q15(xr)
    cos_x = cos_q15(xr)
    numerator_z = q15_mul(up, cos_y) - q15_mul(forward, sin_y)
    numerator_y = q15_mul(up, cos_y) + q15_mul(forward, sin_y)

    z_delta = if cos_x == 0, do: signed_limit(numerator_z), else: div(numerator_z * 32_768, cos_x)

    y_delta =
      if cos_x == 0, do: signed_limit(-numerator_y), else: -div(numerator_y * sin_x, cos_x)

    x_delta = q15_mul(up, sin_y) + q15_mul(forward, cos_y)

    {wrap_s16(zr + z_delta), wrap_s16(xr + x_delta), wrap_s16(yr + y_delta + left)}
  end

  defp matrix_slot(command)
       when command in [0x01, 0x05, 0x31, 0x35, 0x0D, 0x09, 0x39, 0x3D, 0x03, 0x33, 0x0B, 0x3B],
       do: :a

  defp matrix_slot(command) when command in [0x11, 0x15, 0x1D, 0x19, 0x13, 0x1B], do: :b
  defp matrix_slot(command) when command in [0x21, 0x25, 0x2D, 0x29, 0x23, 0x2B], do: :c

  defp sin_q15(angle) do
    angle = s16(angle)

    cond do
      angle == -32_768 ->
        0

      angle < 0 ->
        -sin_q15(-angle)

      true ->
        coarse = elem(@sin_table, angle >>> 8)
        slope = elem(@sin_table, 0x40 + (angle >>> 8))
        fine = elem(@mul_table, angle &&& 0xFF)
        min(32_767, coarse + ((fine * slope) >>> 15))
    end
  end

  defp cos_q15(angle) do
    angle = s16(angle)

    angle =
      cond do
        angle == -32_768 -> :minimum
        angle < 0 -> -angle
        true -> angle
      end

    if angle == :minimum do
      -32_768
    else
      coarse = elem(@sin_table, 0x40 + (angle >>> 8))
      slope = elem(@sin_table, angle >>> 8)
      fine = elem(@mul_table, angle &&& 0xFF)
      max(-32_767, coarse - ((fine * slope) >>> 15))
    end
  end

  defp normalize(value, exponent) do
    value = i16(value)
    shift = normalization_shift(value, 15)
    {i16(value <<< shift), i16(exponent - shift)}
  end

  defp normalize_double(value) do
    shift = normalization_shift_double(value, 0)
    {i16((value <<< shift) >>> 15), shift}
  end

  defp normalization_shift(0, limit), do: limit

  defp normalization_shift(value, limit) do
    Enum.reduce_while(0..limit, value, fn shift, current ->
      if current >= 0x4000 or current < -0x4000,
        do: {:halt, shift},
        else: {:cont, i16(current <<< 1)}
    end)
  end

  defp normalization_shift_double(_value, shift) when shift >= 30, do: shift

  defp normalization_shift_double(value, shift) do
    coefficient = (value <<< shift) >>> 15

    if coefficient >= 0x4000 or coefficient < -0x4000,
      do: shift,
      else: normalization_shift_double(value, shift + 1)
  end

  defp truncate(coefficient, exponent) when exponent > 0 do
    cond do
      coefficient > 0 -> 32_767
      coefficient < 0 -> -32_767
      true -> coefficient
    end
  end

  defp truncate(coefficient, exponent) when exponent < 0,
    do: i16(coefficient >>> -exponent)

  defp truncate(coefficient, _exponent), do: i16(coefficient)

  defp shift_r(coefficient, exponent) when exponent == 0,
    do: i16((coefficient * 0x7FFF) >>> 15)

  defp shift_r(coefficient, exponent), do: i16(coefficient >>> exponent)

  defp q15_mul(left, right), do: (left * right) >>> 15
  defp signed_limit(value) when value < 0, do: -32_767
  defp signed_limit(_value), do: 32_767
  defp wrap_s16(value), do: s16(value &&& 0xFFFF)
  defp i16(value), do: s16(value &&& 0xFFFF)

  defp data_port?(dsp1, address), do: (address &&& 0xFFFF) < dsp1.boundary

  defp decode_words(binary) do
    for <<low, high <- binary>>, do: low ||| high <<< 8
  end

  defp word(value), do: <<value &&& 0xFF, value >>> 8 &&& 0xFF>>
  defp words(values), do: values |> Enum.map(&word/1) |> IO.iodata_to_binary()
  defp s16(value) when (value &&& 0x8000) != 0, do: (value &&& 0xFFFF) - 0x10000
  defp s16(value), do: value &&& 0xFFFF
end
