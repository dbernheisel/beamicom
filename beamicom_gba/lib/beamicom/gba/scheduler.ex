defmodule Beamicom.GBA.Scheduler do
  @moduledoc """
  Serializable master-cycle event calendar.

  Events at the same cycle are ordered by explicit priority and then insertion
  sequence. Event tags and data remain ordinary terms so save states do not
  contain closures or process identifiers.
  """

  @enforce_keys [:now, :next_sequence, :events, :deadline]
  defstruct now: 0, next_sequence: 0, events: :gb_sets.empty(), deadline: nil

  @doc "Creates an empty scheduler at cycle zero."
  def new,
    do: %__MODULE__{now: 0, next_sequence: 0, events: :gb_sets.empty(), deadline: nil}

  @doc "Schedules an event relative to the current master cycle."
  def schedule_in(%__MODULE__{} = scheduler, cycles, priority, tag, data \\ nil)
      when is_integer(cycles) and cycles >= 0 and is_integer(priority) and is_atom(tag) do
    schedule_at(scheduler, scheduler.now + cycles, priority, tag, data)
  end

  @doc "Schedules an event at an absolute master cycle."
  def schedule_at(%__MODULE__{} = scheduler, cycle, priority, tag, data \\ nil)
      when is_integer(cycle) and cycle >= scheduler.now and is_integer(priority) and is_atom(tag) do
    event = {cycle, priority, scheduler.next_sequence, tag, data}

    %{
      scheduler
      | events: :gb_sets.add(event, scheduler.events),
        next_sequence: scheduler.next_sequence + 1,
        deadline: earliest(scheduler.deadline, cycle)
    }
  end

  @doc "Returns the absolute cycle of the next event, if one exists."
  def next_cycle(%__MODULE__{deadline: deadline}), do: deadline

  @doc "Advances the calendar without crossing the next scheduled event."
  def elapse(%__MODULE__{} = scheduler, cycles)
      when is_integer(cycles) and cycles >= 0 do
    target = scheduler.now + cycles

    case next_cycle(scheduler) do
      nil -> %{scheduler | now: target}
      next when target <= next -> %{scheduler | now: target}
      next -> raise ArgumentError, "cannot elapse past scheduled event at cycle #{next}"
    end
  end

  @doc "Advances exactly to the next event cycle."
  def elapse_to_next(%__MODULE__{} = scheduler) do
    case next_cycle(scheduler) do
      nil -> {:empty, scheduler}
      cycle -> {:ok, %{scheduler | now: cycle}}
    end
  end

  @doc "Removes every event due at the current cycle in deterministic order."
  def pop_due(%__MODULE__{now: now, deadline: deadline} = scheduler) when deadline != now,
    do: {scheduler, []}

  def pop_due(%__MODULE__{} = scheduler) do
    pop_due(scheduler.events, scheduler.now, [])
    |> then(fn {events, due} ->
      scheduler = %{scheduler | events: events, deadline: first_cycle(events)}
      {scheduler, Enum.reverse(due)}
    end)
  end

  defp pop_due(events, now, due) do
    {{^now, _priority, _sequence, tag, data}, events} = :gb_sets.take_smallest(events)
    due = [{tag, data} | due]

    if first_cycle(events) == now,
      do: pop_due(events, now, due),
      else: {events, due}
  end

  defp earliest(nil, cycle), do: cycle
  defp earliest(deadline, cycle), do: min(deadline, cycle)

  defp first_cycle(events) do
    if :gb_sets.is_empty(events), do: nil, else: events |> :gb_sets.smallest() |> elem(0)
  end
end
