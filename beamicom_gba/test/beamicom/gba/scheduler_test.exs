defmodule Beamicom.GBA.SchedulerTest do
  use ExUnit.Case, async: true

  alias Beamicom.GBA.Scheduler

  test "orders equal-cycle events by priority and insertion sequence" do
    scheduler =
      Scheduler.new()
      |> Scheduler.schedule_at(20, 20, :late_priority)
      |> Scheduler.schedule_at(20, 10, :first)
      |> Scheduler.schedule_at(20, 10, :second)
      |> Scheduler.schedule_at(30, 0, :future)

    assert Scheduler.next_cycle(scheduler) == 20
    assert {:ok, scheduler} = Scheduler.elapse_to_next(scheduler)

    assert {scheduler, [first: nil, second: nil, late_priority: nil]} =
             Scheduler.pop_due(scheduler)

    assert scheduler.now == 20
    assert Scheduler.next_cycle(scheduler) == 30
  end

  test "relative recurring events do not drift when rescheduled at their deadline" do
    scheduler = Scheduler.new() |> Scheduler.schedule_in(7, 0, :tick)
    assert {:ok, scheduler} = Scheduler.elapse_to_next(scheduler)
    assert {scheduler, [tick: nil]} = Scheduler.pop_due(scheduler)
    scheduler = Scheduler.schedule_in(scheduler, 7, 0, :tick)
    assert Scheduler.next_cycle(scheduler) == 14
  end

  test "refuses to elapse across an unhandled event" do
    scheduler = Scheduler.new() |> Scheduler.schedule_at(5, 0, :deadline)
    assert_raise ArgumentError, fn -> Scheduler.elapse(scheduler, 6) end
  end
end
