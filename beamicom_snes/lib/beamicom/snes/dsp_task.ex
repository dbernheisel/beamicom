defmodule Beamicom.SNES.DSPTask do
  @moduledoc """
  Owner-linked worker for asynchronous DSP and PPU rendering.

  One-shot workers stop after `await/1`. Reusable workers remain attached to
  their owner so renderer process-dictionary caches survive across frames.

  ```mermaid
  flowchart LR
    O[Emulator owner] -->|submit| W[Renderer worker]
    W -->|run function| R[Ready result]
    O -->|await or peek| R
    R -->|reusable| W
    R -->|one-shot| S[Stop]
  ```
  """

  use GenServer

  @enforce_keys [:pid]
  defstruct [:pid, :token, reusable?: false]

  @spec start((-> term())) :: %__MODULE__{}
  def start(function) when is_function(function, 0) do
    owner = self()
    {:ok, pid} = GenServer.start(__MODULE__, {owner, {:one_shot, function}})
    %__MODULE__{pid: pid}
  end

  @doc "Starts work on an owner-local worker that survives `await/1`."
  @spec start_reusable(term(), (-> term())) :: %__MODULE__{}
  def start_reusable(key, function) when is_function(function, 0) do
    pid = reusable_worker(key)
    token = make_ref()

    case GenServer.call(pid, {:start, token, function}, :infinity) do
      :ok -> %__MODULE__{pid: pid, token: token, reusable?: true}
      {:error, :busy} -> start(function)
    end
  end

  @spec await(%__MODULE__{}) :: term()
  def await(%__MODULE__{pid: pid, token: token, reusable?: true}),
    do: GenServer.call(pid, {:await, token}, :infinity)

  def await(%__MODULE__{pid: pid}), do: GenServer.call(pid, :await, :infinity)

  @doc "Reads a completed result without consuming the task."
  def peek(%__MODULE__{pid: pid, token: token, reusable?: true}),
    do: GenServer.call(pid, {:peek, token}, :infinity)

  def peek(%__MODULE__{pid: pid}), do: GenServer.call(pid, :peek, :infinity)

  @impl true
  def init({owner, {:one_shot, function}}) do
    owner_ref = Process.monitor(owner)
    {:ok, {:one_shot, owner_ref, function}, {:continue, :run_once}}
  end

  def init({owner, :reusable}) do
    owner_ref = Process.monitor(owner)
    {:ok, {:reusable, owner_ref, :idle}}
  end

  @impl true
  def handle_continue(:run_once, {:one_shot, owner_ref, function}) do
    {:noreply, {:one_shot, owner_ref, {:ready, function.()}}}
  end

  def handle_continue(:run_reusable, {:reusable, owner_ref, {:running, token, function}}) do
    {:noreply, {:reusable, owner_ref, {:ready, token, function.()}}}
  end

  @impl true
  def handle_call(:await, _from, {:one_shot, owner_ref, {:ready, result}}) do
    Process.demonitor(owner_ref, [:flush])
    {:stop, :normal, result, nil}
  end

  def handle_call(:peek, _from, {:one_shot, _owner_ref, {:ready, result}} = state),
    do: {:reply, result, state}

  def handle_call(
        {:start, token, function},
        _from,
        {:reusable, owner_ref, :idle}
      ) do
    {:reply, :ok, {:reusable, owner_ref, {:running, token, function}}, {:continue, :run_reusable}}
  end

  def handle_call({:start, _token, _function}, _from, {:reusable, _owner_ref, _work} = state),
    do: {:reply, {:error, :busy}, state}

  def handle_call(
        {:await, token},
        _from,
        {:reusable, owner_ref, {:ready, token, result}}
      ),
      do: {:reply, result, {:reusable, owner_ref, :idle}}

  def handle_call(
        {:peek, token},
        _from,
        {:reusable, _owner_ref, {:ready, token, result}} = state
      ),
      do: {:reply, result, state}

  @impl true
  def handle_info({:DOWN, owner_ref, :process, _owner, _reason}, state) do
    case state do
      {:one_shot, ^owner_ref, _work} -> {:stop, :normal, nil}
      {:reusable, ^owner_ref, _work} -> {:stop, :normal, nil}
    end
  end

  defp reusable_worker(key) do
    process_key = {__MODULE__, :reusable_worker, key}

    case Process.get(process_key) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: pid, else: start_reusable_worker(process_key)

      _other ->
        start_reusable_worker(process_key)
    end
  end

  defp start_reusable_worker(process_key) do
    {:ok, pid} = GenServer.start(__MODULE__, {self(), :reusable})
    Process.put(process_key, pid)
    pid
  end
end
