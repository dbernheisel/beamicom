defmodule Beamicom.NES.Runtime do
  @moduledoc """
  The emulation loop process (spec §4, §5.5): loads a ROM, produces exactly one
  `%Beamicom.NES.Framebuffer{}` per PPU frame, and publishes it to `Beamicom.NES.Output`. Pacing
  is decoupled from every sink — the loop never waits on a consumer.

  Video-only pacing (milestone one): the next frame's deadline is computed from a
  fixed epoch rather than by adding a period each tick, so timing error doesn't
  accumulate (spec §5.5). A long scheduler or renderer stall rebases that epoch
  so audio produced before the stall is not emitted in a burst afterward. Pass
  `pace: false` to run flat-out (tests, batch).

  ## Sources
    * spec §5.5 — monotonic-clock pacing from a fixed epoch; fire-and-forget publish.
  """
  use GenServer

  alias Beamicom.NES.{Bus, CPU, Console, Output, PPU}

  # NTSC ~60.0988 fps.
  @period_ns round(1_000_000_000 / 60.0988)
  @cpu_cycles_per_frame round(1_789_773 / 60.0988)
  # Short overruns still catch up against the fixed epoch. Longer discontinuities
  # (notably first-use Nx/EXLA compilation) must not become queued stale audio.
  @max_catchup_ns 50_000_000
  @enhancements [:hide_horizontal_overscan, :unlimited_sprites]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc "Set controller `port` (1 or 2) to the pressed buttons."
  def set_buttons(server \\ __MODULE__, port, buttons) do
    GenServer.cast(server, {:set_buttons, port, buttons})
  end

  @doc "Enable or disable a supported enhancement while the emulator is running."
  def set_enhancement(server \\ __MODULE__, enhancement, enabled)

  def set_enhancement(server, enhancement, enabled)
      when enhancement in @enhancements and is_boolean(enabled),
      do: GenServer.call(server, {:set_enhancement, enhancement, enabled})

  def set_enhancement(_server, _enhancement, _enabled),
    do: {:error, :invalid_enhancement}

  @impl true
  def init(opts) do
    # The emulation loop is soft-real-time: it must finish each frame within the
    # ~16.7ms budget or the audio sink starves. Run it above the video sink and
    # Scenic driver so CPU contention can't push a frame past its deadline. Safe
    # because paced play sleeps between frames (it never busy-holds the CPU).
    Process.flag(:priority, :high)

    console =
      case Keyword.fetch(opts, :console) do
        {:ok, console} -> console
        :error -> Console.load(Keyword.fetch!(opts, :rom))
      end

    console =
      Enum.reduce(Keyword.get(opts, :enhancements, []), console, fn {enhancement, enabled}, acc ->
        Console.set_enhancement(acc, enhancement, enabled)
      end)

    pace = Keyword.get(opts, :pace, true)
    # Playback speed multiplier (1.0 = real-time NTSC). Below 1.0 paces frames
    # further apart for glitch-free slow-motion on machines that can't sustain
    # real-time; the audio sink must run at the matching rate to stay in sync.
    speed = Keyword.get(opts, :speed, 1.0)

    # Audio is drained/published once per "slice"; with `audio_slices` > 1 that
    # happens sub-frame, keeping the player's input queue (and A/V lag) down to
    # ~1 slice. 1 = the safe default: one whole frame per slice, as before. Higher
    # tightens sync but costs per-tick overhead — raise it only while the machine
    # has slack (watch the AudioSink "audio ahead" meter; back off if it trends
    # negative, meaning the player is starving).
    slices = max(1, Keyword.get(opts, :audio_slices, 1))

    state = %{
      console: console,
      frame: -1,
      published: 0,
      slice: 0,
      audio_slices: slices,
      slice_ns: round(@period_ns / slices),
      cycles_per_slice: round(@cpu_cycles_per_frame / slices),
      epoch: now(),
      pace: pace,
      speed: speed,
      paused: false,
      pending_enhancements: []
    }

    {:ok, schedule(state)}
  end

  @doc "Pause / resume the loop, or advance a single frame while paused (debugger)."
  def pause(server \\ __MODULE__), do: GenServer.cast(server, :pause)
  def resume(server \\ __MODULE__), do: GenServer.cast(server, :resume)
  def step(server \\ __MODULE__), do: GenServer.cast(server, :step)

  @doc "Return the live `{console, framebuffer}` for a mid-play save."
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, {state.console, state.console.bus.ppu.frame_ready}, state}
  end

  def handle_call({:set_enhancement, enhancement, enabled}, _from, state) do
    pending_enhancements = Keyword.put(state.pending_enhancements, enhancement, enabled)
    {:reply, :ok, %{state | pending_enhancements: pending_enhancements}}
  end

  @impl true
  def handle_cast({:set_buttons, port, buttons}, state) do
    {:noreply, %{state | console: Console.set_buttons(state.console, port, buttons)}}
  end

  def handle_cast(:pause, state), do: {:noreply, %{state | paused: true}}

  def handle_cast(:resume, state) do
    {:noreply, schedule(%{state | paused: false, epoch: now(), published: 0, slice: 0})}
  end

  def handle_cast(:step, state), do: {:noreply, run_frame(state)}

  @impl true
  def handle_info(:tick, %{paused: true} = state), do: {:noreply, state}

  def handle_info(:tick, %{audio_slices: 1} = state),
    do: {:noreply, schedule(%{run_frame(state) | slice: state.slice + 1})}

  def handle_info(:tick, state),
    do: {:noreply, schedule(%{run_slice(state) | slice: state.slice + 1})}

  defp run_frame(state) do
    {console, frame} = next_frame(state.console, state.frame)
    {frame, sample_count, pcm, bus} = render_outputs(frame, console.bus)
    bus = put_in(bus.ppu.frame_ready, frame)
    console = %{console | bus: bus}
    Output.publish(frame)
    Output.publish_audio(sample_count, pcm, Bus.audio_sample_rate(bus))

    state
    |> Map.merge(%{console: console, frame: frame.number, published: state.published + 1})
    |> apply_pending_enhancements()
  end

  # A sub-frame slice: run a fraction of a frame's cycles, publish a video frame
  # if one became ready, then drain and publish just this slice's audio.
  defp run_slice(state) do
    previous_published = state.published
    target = state.console.cpu.cycles + state.cycles_per_slice
    console = run_cycles(state.console, target)
    fb = console.bus.ppu.frame_ready

    {console, frame, published, sample_count, pcm} =
      if fb && fb.number > state.frame do
        {fb, sample_count, pcm, bus} = render_outputs(fb, console.bus)
        bus = put_in(bus.ppu.frame_ready, fb)
        console = %{console | bus: bus}
        Output.publish(fb)
        {console, fb.number, state.published + 1, sample_count, pcm}
      else
        {sample_count, pcm, bus} = Bus.take_audio_pcm(console.bus)
        {%{console | bus: bus}, state.frame, state.published, sample_count, pcm}
      end

    Output.publish_audio(sample_count, pcm, Bus.audio_sample_rate(console.bus))

    state
    |> Map.merge(%{console: console, frame: frame, published: published})
    |> then(fn state ->
      if published > previous_published, do: apply_pending_enhancements(state), else: state
    end)
  end

  defp apply_pending_enhancements(%{pending_enhancements: []} = state), do: state

  defp apply_pending_enhancements(state) do
    console =
      Enum.reduce(state.pending_enhancements, state.console, fn {enhancement, enabled}, console ->
        Console.set_enhancement(console, enhancement, enabled)
      end)

    %{state | console: console, pending_enhancements: []}
  end

  # Deferred Nx video and block audio are independent computations over the same
  # immutable bus snapshot. Render them concurrently so the real-time runtime has
  # the same critical path as System.run_slice/2 and does not add their latencies.
  defp render_outputs(%{render: nil} = frame, bus) do
    {sample_count, pcm, bus} = Bus.take_audio_pcm(bus)
    {frame, sample_count, pcm, bus}
  end

  defp render_outputs(frame, bus) do
    audio = Task.async(fn -> Bus.take_audio_pcm(bus) end)
    frame = PPU.resolve_frame(frame)
    {sample_count, pcm, bus} = Task.await(audio, :infinity)
    {frame, sample_count, pcm, bus}
  end

  defp run_cycles(%Console{} = console, target) do
    {cpu, bus} = run_cycles(console.cpu, console.bus, target, 2_000_000)
    %{console | cpu: cpu, bus: bus}
  end

  defp run_cycles(cpu, bus, _target, 0), do: {cpu, bus}

  defp run_cycles(cpu, bus, target, remaining) do
    if cpu.cycles >= target do
      {cpu, bus}
    else
      {cpu, bus} = CPU.step(cpu, bus)
      run_cycles(cpu, bus, target, remaining - 1)
    end
  end

  # Step the console until a new fully-rendered frame is ready.
  defp next_frame(%Console{} = console, after_number) do
    case next_frame(console.cpu, console.bus, after_number, 1_000_000) do
      {cpu, bus, frame} -> {%{console | cpu: cpu, bus: bus}, frame}
      {cpu, bus} -> %{console | cpu: cpu, bus: bus}
    end
  end

  defp next_frame(cpu, bus, _after_number, 0), do: {cpu, bus}

  defp next_frame(cpu, bus, after_number, remaining) do
    {cpu, bus} = CPU.step(cpu, bus)
    frame = bus.ppu.frame_ready

    if frame && frame.number > after_number,
      do: {cpu, bus, frame},
      else: next_frame(cpu, bus, after_number, remaining - 1)
  end

  defp schedule(%{pace: false} = state) do
    send(self(), :tick)
    state
  end

  defp schedule(state) do
    current = now()
    period = round(state.slice_ns / state.speed)
    deadline = state.epoch + state.slice * period

    if current - deadline > @max_catchup_ns do
      # The emulator clock was stopped for long enough that catching wall time
      # would only flood the audio player with historical PCM. Continue one
      # period from now; video and audio remain on the same emulated timeline.
      Process.send_after(self(), :tick, max(0, div(period, 1_000_000)))
      %{state | epoch: current, slice: 1}
    else
      Process.send_after(self(), :tick, max(0, div(deadline - current, 1_000_000)))
      state
    end
  end

  defp now, do: System.monotonic_time(:nanosecond)
end
