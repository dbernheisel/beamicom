defmodule BeamicomV4L2.Runtime do
  @moduledoc "Frame-paced runtime for the Game Boy implementation."

  use GenServer

  alias Beamicom.GB.System, as: GBSystem
  alias Beamicom.Host.{AudioChunk, Input, Output, VideoFrame}

  @enforce_keys [:machine, :output, :period_ns, :epoch, :pace, :speed]
  defstruct @enforce_keys ++ [slice: 0]

  def start_link(options) do
    case Keyword.get(options, :name) do
      nil -> GenServer.start_link(__MODULE__, options)
      name -> GenServer.start_link(__MODULE__, options, name: name)
    end
  end

  @spec set_input(GenServer.server(), Input.t()) :: :ok
  def set_input(server, %Input{} = input), do: GenServer.cast(server, {:set_input, input})

  @spec snapshot(GenServer.server()) :: term()
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @impl true
  def init(options) do
    Process.flag(:priority, :high)
    capabilities = GBSystem.capabilities()
    period_ns = round(1_000_000_000 / capabilities.video.frame_rate)

    state = %__MODULE__{
      machine: Keyword.fetch!(options, :machine),
      output: Keyword.fetch!(options, :output),
      period_ns: period_ns,
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
    {:noreply, %{state | machine: GBSystem.set_input(state.machine, input)}}
  end

  @impl true
  def handle_info(:tick, state) do
    {machine, outputs} = GBSystem.run_slice(state.machine)
    publish(outputs, state.output)
    {:noreply, schedule(%{state | machine: machine, slice: state.slice + 1})}
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

  defp schedule(%__MODULE__{pace: false} = state) do
    send(self(), :tick)
    state
  end

  defp schedule(state) do
    deadline = state.epoch + round(state.slice * state.period_ns / state.speed)
    Process.send_after(self(), :tick, max(0, div(deadline - now(), 1_000_000)))
    state
  end

  defp now, do: System.monotonic_time(:nanosecond)
end
