defmodule NxNes.Machine.PPU do
  @moduledoc "Resident PPU registers and event timing, using the existing Nx scanline renderer."
  import Nx.Defn

  defn next_stop(p) do
    stop =
      Nx.select(
        p.dot < 1,
        1,
        Nx.select(p.dot < 257, 257, Nx.select(p.dot < 260, 260, Nx.select(p.dot < 280, 280, 341)))
      )

    length =
      Nx.select(p.scanline == 261 and band(p.frame, 1) == 1 and band(p.mask, 24) != 0, 340, 341)

    Nx.min(stop, length)
  end

  defn run(p, chr, dots) do
    if p.dot + dots < next_stop(p), do: %{p | dot: p.dot + dots}, else: run_events(p, chr, dots)
  end

  defnp run_events(p, chr, dots) do
    {p, _, _} =
      while {p, dots, chr}, dots > 0 do
        stop =
          Nx.select(
            p.dot < 1,
            1,
            Nx.select(
              p.dot < 257,
              257,
              Nx.select(p.dot < 260, 260, Nx.select(p.dot < 280, 280, 341))
            )
          )

        length =
          Nx.select(
            p.scanline == 261 and band(p.frame, 1) == 1 and band(p.mask, 24) != 0,
            340,
            341
          )

        stop = Nx.min(stop, length)
        advance = Nx.min(dots, stop - p.dot)
        p = %{p | dot: p.dot + advance}

        p =
          if p.dot == stop do
            p =
              if stop == length do
                %{
                  p
                  | dot: Nx.tensor(0, type: :s32),
                    scanline: Nx.select(p.scanline == 261, 0, p.scanline + 1),
                    frame: p.frame + Nx.as_type(p.scanline == 261, :s32)
                }
              else
                p
              end

            fire(p, chr)
          else
            p
          end

        {p, dots - advance, chr}
      end

    p
  end

  defnp fire(p, chr) do
    rendering = band(p.mask, 24) != 0

    cond do
      p.dot == 257 and p.scanline < 240 ->
        {line, status, v} = NxNes.PPU.render(p, chr)
        store_line(%{p | status: status, v: v}, line)

      p.dot == 257 and p.scanline == 261 and rendering ->
        %{p | v: bor(band(p.v, 31712), band(p.t, 1055))}

      p.dot == 280 and p.scanline == 261 and rendering ->
        %{p | v: bor(band(p.v, 1055), band(p.t, 31712))}

      p.dot == 260 and rendering and (p.scanline < 240 or p.scanline == 261) ->
        %{
          p
          | irq_ticks: p.irq_ticks + 1,
            irq_scanline: Nx.select(p.scanline == 261, 0, p.scanline + 1)
        }

      p.dot == 0 and p.scanline == 240 ->
        %{p | ready: p.frame, output_palette: p.palette, output_mask: p.mask}

      p.dot == 1 and p.scanline == 241 ->
        %{p | status: bor(p.status, 128)}

      p.dot == 1 and p.scanline == 261 ->
        %{p | status: band(p.status, 31)}

      true ->
        p
    end
  end

  deftransformp store_line(p, line) do
    if Map.has_key?(p, :render_rows) do
      queue_line(p, line)
    else
      %{p | framebuffer: Nx.put_slice(p.framebuffer, [p.scanline, 0], Nx.reshape(line, {1, 256}))}
    end
  end

  defnp queue_line(p, line) do
    %{
      p
      | render_rows: Nx.put_slice(p.render_rows, [p.render_count, 0], Nx.reshape(line, {1, 256})),
        render_indices:
          Nx.put_slice(p.render_indices, [p.render_count], Nx.reshape(p.scanline, {1})),
        render_count: p.render_count + 1
    }
  end

  defn commit_lines(p, framebuffer) do
    slots = Nx.iota({8}, type: :s32)
    valid = slots < p.render_count
    # Rendered rows are consecutive and there are at most six per CPU step.
    # Offset unused slots by eight so every scatter index remains distinct.
    untouched_indices = Nx.remainder(p.render_indices[0] + 8 + slots, 240)
    indices = Nx.select(valid, p.render_indices, untouched_indices)
    untouched_rows = Nx.take(framebuffer, untouched_indices)
    rows = Nx.select(Nx.broadcast(valid, {8, 256}, axes: [0]), p.render_rows, untouched_rows)
    framebuffer = Nx.indexed_put(framebuffer, Nx.new_axis(indices, -1), rows)

    {%{p | render_count: Nx.tensor(0, type: :s32)}, framebuffer}
  end

  defn read_register(p, chr, addr) do
    reg = band(addr, 7)
    at_set = p.scanline == 241 and p.dot == 1
    near = p.scanline == 241 and p.dot >= 1 and p.dot <= 3

    status_value =
      bor(
        Nx.select(at_set, 0, band(p.status, 128)),
        bor(band(p.status, 96), band(p.buffer, 31))
      )

    oam = Nx.as_type(Nx.take(Nx.reshape(p.oam, {256}), p.oam_addr), :s32)
    oam_value = Nx.select(band(p.oam_addr, 3) == 2, band(oam, 227), oam)
    a = band(p.v, 16383)
    data_value = Nx.select(a >= 0x3F00, read(p, chr, a), p.buffer)
    data_buffer = read(p, chr, Nx.select(a >= 0x3F00, a - 0x1000, a))

    value =
      Nx.select(
        reg == 2,
        status_value,
        Nx.select(reg == 4, oam_value, Nx.select(reg == 7, data_value, p.buffer))
      )

    {value,
     %{
       p
       | status: Nx.select(reg == 2, band(p.status, 127), p.status),
         w: Nx.select(reg == 2, 0, p.w),
         nmi_suppress: Nx.select(reg == 2, Nx.as_type(near, :s32), p.nmi_suppress),
         buffer: Nx.select(reg == 7, data_buffer, p.buffer),
         v:
           Nx.select(
             reg == 7,
             band(p.v + Nx.select(band(p.ctrl, 4) != 0, 32, 1), 32767),
             p.v
           )
     }}
  end

  defn write_register(p, addr, value) do
    reg = band(addr, 7)
    v = band(value, 255)
    t0 = bor(band(p.t, 0x73FF), band(v, 3) * 1024)

    t5 =
      Nx.select(
        p.w == 0,
        bor(band(p.t, 0x7FE0), shr(v, 3)),
        bor(band(p.t, 0x0C1F), bor(band(v, 7) * 4096, band(v, 248) * 4))
      )

    t6 = Nx.select(p.w == 0, bor(band(p.t, 255), band(v, 63) * 256), bor(band(p.t, 0x7F00), v))
    flat_oam = put(Nx.reshape(p.oam, {256}), p.oam_addr, v)
    memory = write(p, band(p.v, 16383), v)
    latch_write = reg == 5 or reg == 6

    %{
      p
      | ctrl: Nx.select(reg == 0, v, p.ctrl),
        mask: Nx.select(reg == 1, v, p.mask),
        oam_addr:
          Nx.select(reg == 3, v, Nx.select(reg == 4, band(p.oam_addr + 1, 255), p.oam_addr)),
        oam: Nx.select(reg == 4, Nx.reshape(flat_oam, {64, 4}), p.oam),
        t: Nx.select(reg == 0, t0, Nx.select(reg == 5, t5, Nx.select(reg == 6, t6, p.t))),
        x: Nx.select(reg == 5 and p.w == 0, band(v, 7), p.x),
        w: Nx.select(latch_write, 1 - p.w, p.w),
        v:
          Nx.select(
            reg == 6 and p.w == 1,
            t6,
            Nx.select(
              reg == 7,
              band(p.v + Nx.select(band(p.ctrl, 4) != 0, 32, 1), 32767),
              p.v
            )
          ),
        palette: Nx.select(reg == 7, memory.palette, p.palette),
        exram: Nx.select(reg == 7, memory.exram, p.exram),
        vram: Nx.select(reg == 7, memory.vram, p.vram)
    }
  end

  defn read(p, chr, a) do
    off = band(a, 1023)
    source = p.nt_source[band(shr(a, 10), 3)]

    nt =
      Nx.select(
        source == 2,
        p.exram[off],
        Nx.select(
          source == 3,
          Nx.select(off < 960, p.fill_tile, p.fill_attr * 85),
          Nx.as_type(p.vram[off + Nx.select(source == 1, 1024, 0)], :s32)
        )
      )

    flat = p.chr_banks[band(shr(a, 10), 7)] + off

    Nx.select(
      a < 0x2000,
      Nx.as_type(chr[Nx.remainder(flat, Nx.axis_size(chr, 0))], :s32),
      Nx.select(a < 0x3F00, nt, Nx.as_type(p.palette[palette_addr(a)], :s32))
    )
  end

  defnp write(p, a, v) do
    off = band(a, 1023)
    source = p.nt_source[band(shr(a, 10), 3)]
    palette = put(p.palette, palette_addr(a), v)
    exram = put(p.exram, off, v)
    vram = put(p.vram, Nx.clip(off + source * 1024, 0, 2047), v)
    palette_write = a >= 0x3F00
    nametable_write = a >= 0x2000 and a < 0x3F00

    %{
      p
      | palette: Nx.select(palette_write, palette, p.palette),
        exram: Nx.select(nametable_write and source == 2, exram, p.exram),
        vram: Nx.select(nametable_write and source < 2, vram, p.vram)
    }
  end

  defnp palette_addr(addr) do
    a = band(addr, 31)
    Nx.select(band(a, 19) == 16, a - 16, a)
  end

  defn(put(t, i, v), do: Nx.put_slice(t, [i], Nx.reshape(Nx.as_type(v, Nx.type(t)), {1})))
  defnp(band(a, b), do: Nx.bitwise_and(a, b))
  defnp(bor(a, b), do: Nx.bitwise_or(a, b))
  defnp(shr(a, b), do: Nx.right_shift(a, b))
end
