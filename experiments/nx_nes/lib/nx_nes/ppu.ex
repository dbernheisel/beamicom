defmodule NxNes.PPU do
  @moduledoc "MMC5 CHR-ROM scanline renderer: fetch, sprite evaluation, composition and scroll/status results."
  import Nx.Defn

  @scalars ~w(v t x ctrl mask status scanline exram_mode fill_tile fill_attr ext_chr_hi split_en split_side split_tile split_scroll split_chr)a
  def pack(s) do
    if s.chr_latch != nil or s.unlimited_sprites or map_size(s.chr_ram) != 0,
      do: raise(ArgumentError, "probe supports MMC5 CHR-ROM with hardware sprite limit")

    scalars =
      Map.new(@scalars, fn k ->
        v = Map.fetch!(s, k)
        {k, Nx.tensor(if(is_boolean(v), do: if(v, do: 1, else: 0), else: v), type: :s32)}
      end)

    nt =
      s.nt_source ||
        case s.mirroring do
          :horizontal -> {0, 0, 1, 1}
          :vertical -> {0, 1, 0, 1}
          :single -> {0, 0, 0, 0}
          :single1 -> {1, 1, 1, 1}
        end

    Map.merge(scalars, %{
      vram: Nx.from_binary(s.vram, :u8),
      oam: Nx.from_binary(s.oam, :u8) |> Nx.reshape({64, 4}),
      exram: Nx.tensor(for(i <- 0..1023, do: Map.get(s.exram, i, 0)), type: :s32),
      nt_source: Nx.tensor(Tuple.to_list(nt), type: :s32),
      chr_banks: Nx.tensor(Tuple.to_list(s.chr_banks), type: :s32),
      bg_chr_banks: Nx.tensor(Tuple.to_list(s.bg_chr_banks), type: :s32)
    })
  end

  defn render(s, chr) do
    # Tile coordinates, including coarse-X wrap and horizontal nametable toggle.
    i = Nx.iota({33}, type: :s32)
    cx = band(s.v, 31) + i
    v = Nx.bitwise_xor(band(s.v, 32736), Nx.select(cx >= 32, 1024, 0)) + band(cx, 31)

    split =
      s.split_en != 0 and
        Nx.select(s.split_side == 0, band(v, 31) < s.split_tile, band(v, 31) >= s.split_tile)

    sy = Nx.remainder(s.scanline + s.split_scroll, 240)
    scy = Nx.quotient(sy, 8)
    split_nt = s.exram[scy * 32 + band(v, 31)]
    nt = Nx.select(split, split_nt, nt_read(s, band(v, 4095)))
    ext = s.exram[band(v, 1023)]
    at_addr = bor(960, bor(band(v, 3072), bor(band(shr(v, 4), 56), band(shr(v, 2), 7))))
    at = band(shr(nt_read(s, at_addr), bor(band(shr(v, 4), 4), band(v, 2))), 3)
    split_at = s.exram[960 + shr(scy, 2) * 8 + shr(band(v, 31), 2)]
    split_at = band(shr(split_at, bor(band(scy, 2) * 2, band(v, 2))), 3)
    at = Nx.select(split, split_at, Nx.select(s.exram_mode == 1, shr(ext, 6), at))
    fy = band(shr(v, 12), 7)
    banks = Nx.select(band(s.ctrl, 32) != 0, s.bg_chr_banks, s.chr_banks)
    addr = bor(band(s.ctrl, 16) * 256, nt * 16 + fy)
    flat = banks[shr(addr, 10)] + band(addr, 1023)
    extended = bor(band(ext, 63), s.ext_chr_hi * 64) * 4096 + nt * 16 + fy
    split_flat = s.split_chr * 4096 + nt * 16 + Nx.remainder(sy, 8)
    flat = Nx.select(split, split_flat, Nx.select(s.exram_mode == 1, extended, flat))
    flat = Nx.remainder(flat, Nx.axis_size(chr, 0))
    lo = Nx.as_type(chr[flat], :s32)
    hi = Nx.as_type(chr[Nx.remainder(flat + 8, Nx.axis_size(chr, 0))], :s32)
    x = Nx.iota({256}, type: :s32)
    tx = Nx.quotient(x + s.x, 8)
    bit = 7 - band(x + s.x, 7)
    pat = bor(band(shr(lo[tx], bit), 1), band(shr(hi[tx], bit), 1) * 2)

    bg =
      Nx.select(
        pat == 0 or band(s.mask, 8) == 0 or (x < 8 and band(s.mask, 2) == 0),
        0,
        at[tx] * 4 + pat
      )

    # First eight in-range sprites in OAM order; overflow counts all 64.
    oam = Nx.as_type(s.oam, :s32)
    height = Nx.select(band(s.ctrl, 32) != 0, 16, 8)
    row = s.scanline - oam[[.., 0]] - 1
    active = row >= 0 and row < height
    ids = Nx.iota({64}, type: :s32)
    selected = Nx.argsort(Nx.select(active, ids, ids + 64)) |> Nx.slice([0], [8])
    valid = active[selected]
    spr = oam[selected]
    attr = spr[[.., 2]]
    row = row[selected]
    row = Nx.select(band(attr, 128) != 0, height - 1 - row, row)
    row = Nx.clip(row, 0, 15)
    tile = spr[[.., 1]]
    addr8 = band(s.ctrl, 8) * 512 + tile * 16 + row
    addr16 = band(tile, 1) * 4096 + (band(tile, 254) + Nx.quotient(row, 8)) * 16 + band(row, 7)
    sa = Nx.select(height == 16, addr16, addr8)
    off = s.chr_banks[shr(sa, 10)] + band(sa, 1023)
    slo = Nx.as_type(chr[Nx.remainder(off, Nx.axis_size(chr, 0))], :s32) |> Nx.new_axis(1)
    shi = Nx.as_type(chr[Nx.remainder(off + 8, Nx.axis_size(chr, 0))], :s32) |> Nx.new_axis(1)
    col = Nx.new_axis(x, 0) - Nx.new_axis(spr[[.., 3]], 1)

    sb =
      Nx.select(Nx.broadcast(Nx.new_axis(band(attr, 64) != 0, 1), {8, 256}), col, 7 - col)
      |> Nx.clip(0, 7)

    sp = bor(band(shr(slo, sb), 1), band(shr(shi, sb), 1) * 2)
    opaque = Nx.new_axis(valid, 1) and col >= 0 and col < 8 and sp != 0
    rank = Nx.iota({8, 1}, type: :s32) |> Nx.broadcast({8, 256})
    winner = Nx.reduce_min(Nx.select(opaque, rank, 8), axes: [0])
    win = Nx.clip(winner, 0, 7)
    coords = Nx.stack([win, x], axis: 1)
    pixel = Nx.gather(sp, coords)
    wa = attr[win]
    visible = winner < 8 and band(s.mask, 16) != 0 and (x >= 8 or band(s.mask, 4) != 0)
    out = Nx.select(visible and (bg == 0 or band(wa, 32) == 0), 16 + band(wa, 3) * 4 + pixel, bg)
    hit = Nx.any(visible and selected[win] == 0 and bg != 0 and x != 255)
    rendering = band(s.mask, 24) != 0
    status = bor(s.status, Nx.select(rendering and Nx.sum(Nx.as_type(active, :s32)) > 8, 32, 0))
    status = bor(status, Nx.select(rendering and hit, 64, 0))
    y = band(shr(s.v, 5), 31)
    vert = band(s.v, 4095)
    vert = Nx.select(y == 29, Nx.bitwise_xor(vert, 2048), vert)
    vert = band(vert, 31775) + Nx.select(y == 29 or y == 31, 0, y + 1) * 32
    vert = Nx.select(band(s.v, 28672) != 28672, s.v + 4096, vert)
    vnext = bor(band(vert, 31712), band(s.t, 1055))
    {Nx.as_type(Nx.select(rendering, out, 0), :u8), status, Nx.select(rendering, vnext, s.v)}
  end

  defnp nt_read(s, address) do
    off = band(address, 1023)
    source = s.nt_source[band(shr(address, 10), 3)]
    ciram = Nx.as_type(s.vram[off + Nx.select(source == 1, 1024, 0)], :s32)

    Nx.select(
      source == 2,
      s.exram[off],
      Nx.select(source == 3, Nx.select(off < 960, s.fill_tile, s.fill_attr * 85), ciram)
    )
  end

  defnp(band(a, b), do: Nx.bitwise_and(a, b))
  defnp(bor(a, b), do: Nx.bitwise_or(a, b))
  defnp(shr(a, b), do: Nx.right_shift(a, b))
end
