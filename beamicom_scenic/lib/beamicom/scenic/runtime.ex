defmodule Beamicom.Scenic.Runtime do
  @moduledoc false

  use GenServer

  alias Beamicom.Host.{AudioChunk, Input, Output, VideoFrame}

  @heap_words 65_536
  @spawn_options [
    spawn_opt: [
      {:min_heap_size, @heap_words},
      {:min_bin_vheap_size, @heap_words}
    ]
  ]

  @enforce_keys [:system, :machine, :output, :period_ns, :epoch, :pace, :speed]
  defstruct @enforce_keys ++ [slice: 0, paused: false, generation: 0, timer: nil]

  def start_link(options) do
    case Keyword.get(options, :name) do
      nil -> GenServer.start_link(__MODULE__, options, @spawn_options)
      name -> GenServer.start_link(__MODULE__, options, [{:name, name} | @spawn_options])
    end
  end

  def set_input(server, %Input{} = input), do: GenServer.cast(server, {:set_input, input})
  def pause(server), do: GenServer.cast(server, :pause)
  def resume(server), do: GenServer.cast(server, :resume)
  def step(server), do: GenServer.cast(server, :step)
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @impl true
  def init(options) do
    Process.flag(:priority, :high)
    system = Keyword.fetch!(options, :system)
    capabilities = system.capabilities()

    state = %__MODULE__{
      system: system,
      machine: Keyword.fetch!(options, :machine),
      output: Keyword.fetch!(options, :output),
      period_ns: round(1_000_000_000 / capabilities.video.frame_rate),
      epoch: now(),
      pace: Keyword.get(options, :pace, true),
      speed: Keyword.get(options, :speed, 1.0)
    }

    {:ok, schedule(state)}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state.machine, state}

  @impl true
  def handle_cast({:set_input, input}, state) do
    {:noreply, %{state | machine: state.system.set_input(state.machine, input)}}
  end

  def handle_cast(:pause, state) do
    cancel_timer(state.timer)
    {:noreply, %{state | paused: true, generation: state.generation + 1, timer: nil}}
  end

  def handle_cast(:resume, state) do
    cancel_timer(state.timer)

    state = %{
      state
      | paused: false,
        epoch: now(),
        slice: 0,
        generation: state.generation + 1,
        timer: nil
    }

    {:noreply, schedule(state)}
  end

  def handle_cast(:step, %{paused: true} = state), do: {:noreply, run_slice(state)}
  def handle_cast(:step, state), do: {:noreply, state}

  @impl true
  def handle_info({:tick, generation}, %{generation: generation, paused: true} = state),
    do: {:noreply, %{state | timer: nil}}

  def handle_info({:tick, generation}, %{generation: generation} = state) do
    state = %{state | timer: nil}
    {:noreply, schedule(%{run_slice(state) | slice: state.slice + 1})}
  end

  def handle_info({:tick, _stale_generation}, state), do: {:noreply, state}

  defp run_slice(state) do
    {machine, outputs} = state.system.run_slice(state.machine)
    publish(outputs, state.output)
    %{state | machine: machine}
  end

  defp publish([], _output), do: :ok

  defp publish([%VideoFrame{} = frame | rest], output) do
    Output.publish_video(output, frame)
    publish(rest, output)
  end

  defp publish([%AudioChunk{} = chunk | rest], output) do
    Output.publish_audio(output, chunk)
    publish(rest, output)
  end

  defp schedule(%__MODULE__{paused: true} = state), do: state

  defp schedule(%__MODULE__{pace: false} = state) do
    timer = Process.send_after(self(), {:tick, state.generation}, 0)
    %{state | timer: timer}
  end

  defp schedule(state) do
    deadline = state.epoch + round(state.slice * state.period_ns / state.speed)

    timer =
      Process.send_after(
        self(),
        {:tick, state.generation},
        max(0, div(deadline - now(), 1_000_000))
      )

    %{state | timer: timer}
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) do
    Process.cancel_timer(timer)
    :ok
  end

  defp now, do: System.monotonic_time(:nanosecond)
end
