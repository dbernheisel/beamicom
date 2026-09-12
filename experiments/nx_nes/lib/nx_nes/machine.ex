defmodule NxNes.Machine do
  @moduledoc """
  Optional resident MMC5 NES frame runner. ROM/RAM/devices remain in Nx state;
  run_frame accepts controller masks and emits a framebuffer and PCM in state.
  The native Elixir production core remains independent. DMC is unsupported.
  """
  import Nx.Defn
  alias NxNes.Core.{CPU, Decode}
  alias NxNes.Machine.{PPU, Audio, Bus}

  def load(media, opts \\ []) do
    with {:ok, cart} <- Beamicom.NES.Cart.parse(media) do
      if cart.mapper != 5 or byte_size(cart.chr_rom) == 0 do
        {:error, :requires_mmc5_chr_rom}
      else
        native = Beamicom.NES.Console.load_binary(media)
        # Reuse the CPU container layout; the full cartridge replaces the NROM seed.
        seed = <<"NES", 26, 1, 1, 0::80>> <> :binary.copy(<<0>>, 24576)
        {:ok, cpu} = NxNes.Core.load(seed, pc: native.cpu.pc, backend: Nx.BinaryBackend)

        scalar = fn v ->
          Nx.tensor(if(is_boolean(v), do: if(v, do: 1, else: 0), else: v), type: :s32)
        end

        p = NxNes.PPU.pack(native.bus.ppu)

        p =
          Map.merge(
            p,
            Map.new(
              [:oam_addr, :w, :buffer, :dot, :frame, :nmi_suppress, :irq_ticks, :irq_scanline],
              fn k -> {k, scalar.(Map.fetch!(native.bus.ppu, k))} end
            )
          )

        p =
          Map.merge(p, %{
            palette: Nx.broadcast(Nx.tensor(0, type: :u8), {32}),
            framebuffer: Nx.broadcast(Nx.tensor(0, type: :u8), {240, 256}),
            output_palette: Nx.broadcast(Nx.tensor(0, type: :u8), {32}),
            output_mask: scalar.(0),
            ready: scalar.(-1)
          })

        m =
          Map.take(native.bus.mapper_state, [
            :prg_mode,
            :chr_mode,
            :m5_protect1,
            :m5_protect2,
            :mul_a,
            :mul_b,
            :chr_hi,
            :wram_bank,
            :prg_ram_windows,
            :irq_latch,
            :irq_counter
          ])

        m = Map.new(m, fn {k, v} -> {k, scalar.(v)} end)

        m =
          Map.merge(
            m,
            Map.new([:m5_prg_regs, :chr_regs], fn k ->
              {k, Nx.tensor(Tuple.to_list(Map.fetch!(native.bus.mapper_state, k)), type: :s32)}
            end)
          )

        s =
          Map.merge(cpu, %{
            prg: Nx.from_binary(cart.prg_rom, :u8),
            chr: Nx.from_binary(cart.chr_rom, :u8),
            wram:
              Nx.broadcast(
                Nx.tensor(0, type: :u8),
                {max(native.bus.mapper_state.prg_ram_size, 8192)}
              ),
            prg_banks: Nx.tensor(Tuple.to_list(native.bus.prg_banks), type: :s32),
            mapper: m,
            ppu: p,
            apu: NxNes.APU.pack(native.bus.apu),
            apu_pending: scalar.(0),
            audio: Nx.broadcast(Nx.tensor(0, type: :s16), {2048}),
            audio_count: scalar.(0),
            dma: scalar.(0),
            nmi_prev: scalar.(0),
            nmi_edge: scalar.(0),
            nmi_pending: scalar.(0),
            irq_enabled: scalar.(0),
            irq_pending: scalar.(0),
            fast_instructions: scalar.(0),
            batched_instructions: scalar.(0),
            journal_count: scalar.(0),
            journal_keys: Nx.broadcast(Nx.tensor(0, type: :s32), {8}),
            journal_values: Nx.broadcast(Nx.tensor(0, type: :u8), {8})
          })

        {:ok, Nx.backend_copy(s, Keyword.get(opts, :backend, {EXLA.Backend, client: :host}))}
      end
    end
  end

  @doc "Export only the completed framebuffer and audio; emulation state stays resident."
  def status(s) do
    Map.fetch!(
      %{
        0 => :running,
        4 => :unsupported_opcode,
        7 => :unsupported_dmc,
        8 => :audio_overflow,
        9 => :instruction_limit,
        10 => :render_overflow
      },
      Nx.to_number(s.reason)
    )
  end

  def output(s) do
    if status(s) != :running, do: raise(ArgumentError, "machine stopped: #{status(s)}")
    mask = Nx.to_number(s.ppu.output_mask)
    count = Nx.to_number(s.audio_count)

    framebuffer = %Beamicom.NES.Framebuffer{
      number: Nx.to_number(s.ppu.ready),
      pixels: Nx.to_binary(s.ppu.framebuffer),
      palette: Nx.to_binary(s.ppu.output_palette),
      grayscale: Bitwise.band(mask, 1) != 0,
      emphasis:
        {Bitwise.band(mask, 32) != 0, Bitwise.band(mask, 64) != 0, Bitwise.band(mask, 128) != 0}
    }

    %{
      framebuffer: framebuffer,
      audio_samples: count,
      pcm: binary_part(Nx.to_binary(s.audio), 0, count * 2)
    }
  end

  @doc "Compile a frame runner, optionally specializing a guarded ROM block at :entry."
  def compile(initial, media, opts \\ []) do
    initial = normalize_tensor_metadata(initial)

    block =
      if entry = Keyword.get(opts, :entry) do
        native = Beamicom.NES.Console.load_binary(media)

        mapped =
          for addr <- 0x8000..0xFFFF, into: <<>>, do: <<Beamicom.NES.Bus.peek(native.bus, addr)>>

        nrom = <<"NES", 26, 2, 0, 0::80>> <> mapped

        case NxNes.Core.Blocks.analyze(nrom, entry) do
          {:ok, block} -> block
          {:error, reason} -> raise ArgumentError, "cannot specialize entry: #{reason}"
        end
      end

    compiled =
      EXLA.compile(
        fn s, p1, p2 ->
          {next, n} = run_frame(s, p1, p2, block: block)
          # Immutable cartridge tensors already have resident buffers. Returning
          # them through XLA would allocate/copy them merely to satisfy output ownership.
          rest = Map.drop(next, [:prg, :chr, :ram, :wram])
          rest = %{rest | ppu: Map.delete(rest.ppu, :framebuffer)}
          result = {next.ppu.framebuffer, next.ram, next.wram, rest, n}

          if Keyword.get(opts, :prune_state, true),
            do: NxNes.StateGraph.prune(result),
            else: result
        end,
        [
          initial |> donate_memory() |> Nx.to_template(),
          Nx.template({}, :s32),
          Nx.template({}, :s32)
        ],
        client: :host
      )

    fn s, p1, p2 ->
      s = normalize_tensor_metadata(s)
      {framebuffer, ram, wram, next, n} = compiled.(donate_memory(s), p1, p2)
      next = Map.merge(next, %{ram: ram, wram: wram})
      next = %{next | ppu: Map.put(next.ppu, :framebuffer, framebuffer)}
      # Reuse handles only: no tensor values cross to Elixir and no ROM bytes change.
      {Map.merge(next, Map.take(s, [:prg, :chr])), n}
    end
  end

  defp donate_memory(s) do
    %{
      s
      | ram: Nx.donatable(s.ram),
        wram: Nx.donatable(s.wram),
        ppu: %{s.ppu | framebuffer: Nx.donatable(s.ppu.framebuffer)}
    }
  end

  defp normalize_tensor_metadata(%Nx.Tensor{} = tensor),
    do: Map.put_new(tensor, :donatable?, false)

  defp normalize_tensor_metadata(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, normalize_tensor_metadata(value)} end)

  defp normalize_tensor_metadata(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&normalize_tensor_metadata/1) |> List.to_tuple()

  defp normalize_tensor_metadata(value), do: value

  defn run_frame(s, pad1, pad2, opts \\ []) do
    target = s.ppu.ready + 1

    s = %{
      s
      | pad1: pad1,
        pad2: pad2,
        batched_instructions: Nx.tensor(0, type: :s32),
        fast_instructions: Nx.tensor(0, type: :s32),
        audio_count: Nx.tensor(0, type: :s32)
    }

    {s, framebuffer} = separate_framebuffer(s)

    {s, framebuffer, count, _} =
      while {s, framebuffer, count = Nx.tensor(0, type: :s32), target},
            s.ppu.ready < target and s.reason == 0 and count < 100_000 do
        s =
          if NxNes.Machine.Memory.journal_room(s),
            do: s,
            else: NxNes.Machine.Memory.flush_journal(s)

        {s, n} = scheduled_step(s, opts[:block])
        s = %{s | reason: Nx.select(s.ppu.render_count > 8, 10, s.reason)}
        {p, framebuffer} = PPU.commit_lines(s.ppu, framebuffer)
        {%{s | ppu: p}, framebuffer, count + n, target}
      end

    s = NxNes.Machine.Memory.flush_journal(s)
    s = restore_framebuffer(s, framebuffer)
    s = Audio.sync(s)
    s = %{s | reason: Nx.select(count >= 100_000, 9, s.reason)}
    {s, count}
  end

  # A CPU step can render at most six scanlines, including DMA and interrupt entry.
  # Keep the full framebuffer out of every nested device/CPU conditional.
  deftransformp separate_framebuffer(s) do
    {framebuffer, p} = Map.pop!(s.ppu, :framebuffer)

    p =
      Map.merge(p, %{
        render_rows: Nx.broadcast(Nx.tensor(0, type: :u8), {8, 256}),
        render_indices: Nx.broadcast(Nx.tensor(0, type: :s32), {8}),
        render_count: Nx.tensor(0, type: :s32)
      })

    {%{s | ppu: p}, framebuffer}
  end

  deftransformp restore_framebuffer(s, framebuffer) do
    p =
      s.ppu
      |> Map.drop([:render_rows, :render_indices, :render_count])
      |> Map.put(:framebuffer, framebuffer)

    %{s | ppu: p}
  end

  deftransformp scheduled_step(s, block) do
    if block, do: block_or_step(s, block: block), else: batch_or_step(s)
  end

  defn block_or_step(s, opts) do
    block = opts[:block]
    cycles = block_cycles(block)
    # No PPU event or observable IRQ/NMI may fall inside the fused region.
    if s.pc == block_entry(block) and s.ppu.dot + cycles * 3 < PPU.next_stop(s.ppu) and
         s.nmi_pending == 0 and s.nmi_edge == 0 and s.nmi_prev == line(s.ppu) and
         not (s.irq_pending != 0 and s.irq_enabled != 0) and s.apu.frame_irq == 0 and
         s.apu.irq_inhibit != 0 and
         NxNes.Machine.Memory.journal_room_for(s, block_count(block) * 3) and
         block_valid(s, block) do
      iterations =
        Nx.select(
          block_loops(block),
          Nx.quotient(PPU.next_stop(s.ppu) - 1 - s.ppu.dot, cycles * 3),
          1
        )

      iterations =
        Nx.min(
          iterations,
          NxNes.Machine.Memory.journal_iterations(s, block_count(block) * 3)
        )

      c = cpu_state(s)

      {c, _, _} =
        while {c, i = Nx.tensor(0, type: :s32), iterations}, i < iterations do
          {NxNes.Core.Blocks.emit(c, block), i + 1, iterations}
        end

      s = merge_cpu_fields(s, c)
      elapsed = iterations * cycles
      n = iterations * block_count(block)

      s = %{
        s
        | ppu: %{s.ppu | dot: s.ppu.dot + elapsed * 3},
          fast_instructions: s.fast_instructions + n
      }

      {flush(s, elapsed), n}
    else
      batch_or_step(s)
    end
  end

  defn batch_or_step(s) do
    available = Nx.quotient(PPU.next_stop(s.ppu) - 1 - s.ppu.dot, 3)

    if available >= 2 and s.nmi_pending == 0 and s.nmi_edge == 0 and s.nmi_prev == line(s.ppu) and
         not (s.irq_pending != 0 and s.irq_enabled != 0) and s.apu.frame_irq == 0 and
         s.apu.irq_inhibit != 0 do
      {c, n} =
        CPU.run(
          cpu_state(s),
          s.cycles + Nx.as_type(available, :s64),
          Nx.tensor(100_000, type: :s32)
        )

      if n > 0 do
        elapsed = Nx.as_type(c.cycles - s.cycles, :s32)
        s = merge_cpu_fields(s, c)

        s = %{
          s
          | ppu: %{s.ppu | dot: s.ppu.dot + elapsed * 3},
            batched_instructions: s.batched_instructions + n
        }

        {flush(s, elapsed), n}
      else
        {step(s), Nx.tensor(1, type: :s32)}
      end
    else
      {step(s), Nx.tensor(1, type: :s32)}
    end
  end

  deftransformp(block_loops(b),
    do:
      if(List.last(b.instructions).op == "JMP" and List.last(b.instructions).operand == b.entry,
        do: 1,
        else: 0
      )
  )

  deftransformp(block_entry(b), do: b.entry)
  deftransformp(block_count(b), do: b.count)
  deftransformp(block_cycles(b), do: b.cycles)

  deftransformp block_valid(s, b) do
    addresses = Nx.tensor(Enum.to_list(b.entry..(b.entry + length(b.bytes) - 1)), type: :s32)
    windows = Nx.right_shift(Nx.subtract(addresses, 32768), 13)
    rom = Nx.all(Nx.equal(Nx.bitwise_and(s.mapper.prg_ram_windows, Nx.left_shift(1, windows)), 0))

    Nx.logical_and(
      rom,
      Nx.all(Nx.equal(Bus.peek_base(s, addresses), Nx.tensor(b.bytes, type: :s32)))
    )
  end

  defn run_steps(s, limit) do
    {s, _, _} =
      while {s, count = Nx.tensor(0, type: :s32), limit}, count < limit and s.reason == 0 do
        {step(s), count + 1, limit}
      end

    s
  end

  defn step(s) do
    byte = Bus.peek(s, s.pc)
    d = Decode.fetch(byte)
    {addr, crossed, c} = CPU.resolve(cpu_state(s), d[1])
    s = merge_cpu_fields(s, c)
    cost = d[2] + crossed * d[3]
    s = %{s | opcode: byte, event_cycle: s.cycles + Nx.as_type(cost - 1, :s64)}
    s = tick_ppu(s, Nx.max(cost - 1, 0))
    poll = s.nmi_pending
    {value, s} = if CPU.reads_operand(d[0], d[1]), do: Bus.read(s, addr), else: {s.a, s}
    c = cpu_state(s)
    c = %{c | io_read_ready: Nx.tensor(1, type: :s32), io_read_addr: addr, io_read_value: value}
    {c, extra} = CPU.execute(c, d[0], d[1], addr)
    c = NxNes.Machine.Memory.commit(c)
    s = merge_cpu_fields(s, c)
    s = if c.reason == 3, do: Bus.write(s, c.event_addr, c.event_value), else: s

    s =
      if addr >= 0x2000 and addr <= 0x3FFF and (band(addr, 7) == 0 or band(addr, 7) == 2) do
        s = poll_nmi(s, line(s.ppu))

        %{
          s
          | nmi_pending: Nx.select(s.ppu.nmi_suppress != 0, 0, s.nmi_pending),
            ppu: %{s.ppu | nmi_suppress: Nx.tensor(0, type: :s32)}
        }
      else
        s
      end

    s = tick_ppu(s, 1 + extra)
    s = flush(s, cost + extra)

    s = %{
      s
      | cycles: s.cycles + Nx.as_type(cost + extra, :s64),
        reason: Nx.select(d[2] == 0, 4, s.reason)
    }

    s =
      if s.dma != 0 do
        stall = Nx.as_type(513 + Nx.remainder(s.cycles, 2), :s32)
        s = tick_ppu(s, stall) |> flush(stall)
        %{s | dma: Nx.tensor(0, type: :s32), cycles: s.cycles + Nx.as_type(stall, :s64)}
      else
        s
      end

    cond do
      poll != 0 and s.nmi_pending != 0 ->
        interrupt(%{s | nmi_pending: Nx.tensor(0, type: :s32)}, 1)

      ((s.irq_pending != 0 and s.irq_enabled != 0) or s.apu.frame_irq != 0) and band(s.p, 4) == 0 ->
        interrupt(s, 2)

      true ->
        s
    end
  end

  defnp interrupt(s, kind) do
    c = CPU.interrupt(cpu_state(s), kind, Nx.tensor(0x1000000000000000, type: :s64))
    c = NxNes.Machine.Memory.commit(c)
    s = merge_cpu_fields(s, c)
    s = tick_ppu(s, 7)
    flush(s, 7)
  end

  defn flush(s, cycles) do
    p = s.ppu

    s =
      if p.irq_ticks != 0 do
        %{
          s
          | mapper: %{s.mapper | irq_counter: p.irq_scanline},
            irq_pending:
              Nx.as_type(
                s.irq_pending != 0 or
                  (p.irq_scanline == s.mapper.irq_latch and s.mapper.irq_latch != 0),
                :s32
              ),
            ppu: %{p | irq_ticks: Nx.tensor(0, type: :s32)}
        }
      else
        s
      end

    Audio.tick(s, cycles)
  end

  defn tick_ppu(s, n) do
    if s.ppu.dot + n * 3 < PPU.next_stop(s.ppu) and s.nmi_edge == 0 and s.nmi_prev == line(s.ppu) do
      %{s | ppu: %{s.ppu | dot: s.ppu.dot + n * 3}}
    else
      tick_ppu_events(s, n)
    end
  end

  defnp tick_ppu_events(s, n) do
    if n > 0 do
      before = line(s.ppu)
      p = PPU.run(s.ppu, s.chr, n * 3)

      if before == line(p) do
        s = %{s | ppu: p}

        if n == 1 do
          poll_nmi(s, before)
        else
          %{
            s
            | nmi_pending:
                Nx.as_type(
                  s.nmi_pending != 0 or s.nmi_edge != 0 or (before != 0 and s.nmi_prev == 0),
                  :s32
                ),
              nmi_edge: Nx.tensor(0, type: :s32),
              nmi_prev: before
          }
        end
      else
        {s, _, _} =
          while {s, i = Nx.tensor(0, type: :s32), n}, i < n do
            p = PPU.run(s.ppu, s.chr, 3)
            {poll_nmi(%{s | ppu: p}, line(p)), i + 1, n}
          end

        s
      end
    else
      s
    end
  end

  # Isolate arithmetic/CPU memory from device graphs so each device access is
  # compiled once, outside the opcode dispatch tree.
  @cpu_fields [
    :a,
    :x,
    :y,
    :sp,
    :p,
    :pc,
    :cycles,
    :ram,
    :wram,
    :journal_count,
    :journal_keys,
    :journal_values
  ]
  deftransformp cpu_state(s) do
    Map.merge(Map.take(s, @cpu_fields ++ [:prg, :prg_banks, :event_cycle, :opcode]), %{
      write_count: Nx.tensor(0, type: :s32),
      write_addr0: Nx.tensor(0, type: :s32),
      write_addr1: Nx.tensor(0, type: :s32),
      write_addr2: Nx.tensor(0, type: :s32),
      write_value0: Nx.tensor(0, type: :s32),
      write_value1: Nx.tensor(0, type: :s32),
      write_value2: Nx.tensor(0, type: :s32),
      reason: Nx.tensor(0, type: :s32),
      event_addr: Nx.tensor(0, type: :s32),
      event_value: Nx.tensor(0, type: :s32),
      io_read_ready: Nx.tensor(0, type: :s32),
      io_read_addr: Nx.tensor(0, type: :s32),
      io_read_value: Nx.tensor(0, type: :s32),
      io_write_ready: Nx.tensor(0, type: :s32),
      io_write_addr: Nx.tensor(0, type: :s32),
      wram_bank: s.mapper.wram_bank,
      prg_ram_windows: s.mapper.prg_ram_windows,
      wram_writable:
        Nx.as_type(
          Nx.logical_and(Nx.equal(s.mapper.m5_protect1, 2), Nx.equal(s.mapper.m5_protect2, 1)),
          :s32
        ),
      exram: s.ppu.exram,
      exram_mode: s.ppu.exram_mode
    })
  end

  deftransformp(merge_cpu_fields(s, c), do: Map.merge(s, Map.take(c, @cpu_fields)))

  defnp poll_nmi(s, line) do
    %{
      s
      | nmi_pending: Nx.as_type(s.nmi_pending != 0 or s.nmi_edge != 0, :s32),
        nmi_edge: Nx.as_type(line != 0 and s.nmi_prev == 0, :s32),
        nmi_prev: line
    }
  end

  defnp(line(p), do: Nx.as_type(band(band(p.status, p.ctrl), 128) != 0, :s32))
  defnp(band(a, b), do: Nx.bitwise_and(a, b))
end
