defmodule Beamicom.SNES.DSPTask do
  @moduledoc false

  use GenServer

  @enforce_keys [:pid]
  defstruct [:pid]

  @spec start((-> term())) :: %__MODULE__{}
  def start(function) when is_function(function, 0) do
    owner = self()
    {:ok, pid} = GenServer.start(__MODULE__, {owner, function})
    %__MODULE__{pid: pid}
  end

  @spec await(%__MODULE__{}) :: term()
  def await(%__MODULE__{pid: pid}), do: GenServer.call(pid, :await, :infinity)

  @impl true
  def init({owner, function}) do
    owner_ref = Process.monitor(owner)
    {:ok, {owner_ref, function}, {:continue, :run}}
  end

  @impl true
  def handle_continue(:run, {owner_ref, function}) do
    {:noreply, {owner_ref, {:ready, function.()}}}
  end

  @impl true
  def handle_call(:await, _from, {owner_ref, {:ready, result}}) do
    Process.demonitor(owner_ref, [:flush])
    {:stop, :normal, result, nil}
  end

  @impl true
  def handle_info({:DOWN, owner_ref, :process, _owner, _reason}, {owner_ref, _work}) do
    {:stop, :normal, nil}
  end
end
