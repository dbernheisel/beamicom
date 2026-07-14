defmodule Beamicom.NES.Runtime do
  @moduledoc """
  The emulation loop process (spec §4, §5.5): loads a ROM, produces exactly one
  `%Beamicom.NES.Framebuffer{}` per PPU frame, and publishes it to `Beamicom.NES.Output`. Pacing
  is decoupled from every sink — the loop never waits on a consumer.

  Video-only pacing (milestone one): the next frame's deadline is computed from a
  fixed epoch rather than by adding a period each tick, so timing error doesn't
  accumulate (spec §5.5). Pass `pace: false` to run flat-out (tests, batch).

  ## Sources
    * spec §5.5 — monotonic-clock pacing from a fixed epoch; fire-and-forget publish.
  """
  use GenServer

  alias Beamicom.NES.{Console, Output}

  # NTSC ~60.0988 fps.
  @period_ns round(1_000_000_000 / 60.0988)

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)

  @doc "Set controller `port` (1 or 2) to the pressed buttons."
  def set_buttons(server \\ __MODULE__, port, buttons),
    do: GenServer.cast(server, {:set_buttons, port, buttons})

  @impl true
  def init(opts) do
    console = Console.load(Keyword.fetch!(opts, :rom))
    pace = Keyword.get(opts, :pace, true)
    state = %{console: console, frame: -1, published: 0, epoch: now(), pace: pace, paused: false}
    {:ok, schedule(state)}
  end

  @doc "Pause / resume the loop, or advance a single frame while paused (debugger)."
  def pause(server \\ __MODULE__), do: GenServer.cast(server, :pause)
  def resume(server \\ __MODULE__), do: GenServer.cast(server, :resume)
  def step(server \\ __MODULE__), do: GenServer.cast(server, :step)

  @impl true
  def handle_cast({:set_buttons, port, buttons}, state),
    do: {:noreply, %{state | console: Console.set_buttons(state.console, port, buttons)}}

  def handle_cast(:pause, state), do: {:noreply, %{state | paused: true}}

  def handle_cast(:resume, state),
    do: {:noreply, schedule(%{state | paused: false, epoch: now(), published: 0})}

  def handle_cast(:step, state), do: {:noreply, run_frame(state)}

  @impl true
  def handle_info(:tick, %{paused: true} = state), do: {:noreply, state}
  def handle_info(:tick, state), do: {:noreply, schedule(run_frame(state))}

  defp run_frame(state) do
    {console, frame} = next_frame(state.console, state.frame)
    Output.publish(frame)
    # Drain this frame's audio and stream it to subscribers (also bounds memory).
    {samples, apu} = Beamicom.NES.APU.take_samples(console.bus.apu)
    Output.publish_audio(samples)
    console = put_in(console.bus.apu, apu)
    %{state | console: console, frame: frame.number, published: state.published + 1}
  end

  # Step the console until a new fully-rendered frame is ready.
  defp next_frame(console, after_number) do
    Enum.reduce_while(1..1_000_000, console, fn _, c ->
      c = Console.step(c)
      fb = c.bus.ppu.frame_ready
      if fb && fb.number > after_number, do: {:halt, {c, fb}}, else: {:cont, c}
    end)
  end

  defp schedule(%{pace: false} = state) do
    send(self(), :tick)
    state
  end

  defp schedule(state) do
    deadline = state.epoch + state.published * @period_ns
    Process.send_after(self(), :tick, max(0, div(deadline - now(), 1_000_000)))
    state
  end

  defp now, do: System.monotonic_time(:nanosecond)
end
