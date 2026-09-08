defmodule BeamicomStream.Runtime do
  @moduledoc """
  Frame-paced runtime for the Game Boy implementation of `Beamicom.Host.System`.

  Core work remains coarse grained: one callback advances to the next complete
  output boundary, after which typed video and audio envelopes are published
  without waiting for consumers. Deadlines are derived from a fixed epoch so
  scheduler jitter does not accumulate.
  """

  use GenServer

  alias Beamicom.GB.System, as: GBSystem
  alias Beamicom.Host.{AudioChunk, Input, Output, VideoFrame}

  @enforce_keys [:machine, :output, :period_ns, :epoch, :pace]
  defstruct @enforce_keys ++ [slice: 0]

  @type t :: %__MODULE__{}

  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec set_input(GenServer.server(), Input.t()) :: :ok
  def set_input(server, %Input{} = input), do: GenServer.cast(server, {:set_input, input})

  @spec snapshot(GenServer.server()) :: term()
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @doc false
  def load(GBSystem, media, opts), do: GBSystem.load(media, opts)

  @impl true
  def init(opts) do
    Process.flag(:priority, :high)
    system = Keyword.fetch!(opts, :system)
    media = Keyword.fetch!(opts, :media)
    output = Keyword.fetch!(opts, :output)
    capabilities = capabilities(system)
    period_ns = round(1_000_000_000 / capabilities.video.frame_rate)

    case machine(opts, system, media) do
      {:ok, machine} ->
        state = %__MODULE__{
          machine: machine,
          output: output,
          period_ns: period_ns,
          epoch: now(),
          pace: Keyword.get(opts, :pace, true)
        }

        {:ok, schedule(state)}

      {:error, reason} ->
        {:stop, reason}
    end
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

  defp publish([%VideoFrame{} = frame | outputs], output) do
    Output.publish_video(output, frame)
    publish(outputs, output)
  end

  defp publish([%AudioChunk{} = chunk | outputs], output) do
    Output.publish_audio(output, chunk)
    publish(outputs, output)
  end

  defp schedule(%__MODULE__{pace: false} = state) do
    send(self(), :tick)
    state
  end

  defp schedule(state) do
    deadline = state.epoch + state.slice * state.period_ns
    Process.send_after(self(), :tick, max(0, div(deadline - now(), 1_000_000)))
    state
  end

  defp now, do: System.monotonic_time(:nanosecond)

  defp capabilities(GBSystem), do: GBSystem.capabilities()

  defp machine(opts, system, media) do
    case Keyword.fetch(opts, :machine) do
      {:ok, machine} -> {:ok, machine}
      :error -> load(system, media, Keyword.get(opts, :load_options, []))
    end
  end
end
