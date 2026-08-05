defmodule BeamicomPhx.OutputSync do
  @moduledoc """
  Test helper: wait until a Membrane source has actually subscribed to
  `Beamicom.NES.Output` before publishing.

  The sources subscribe inside `handle_playing/2`, which can complete slightly
  *after* the pipeline reports the child playing. A test that publishes the
  instant it sees `:handle_child_playing` therefore races the subscription and
  occasionally delivers to no one. Polling the subscriber set closes that window
  deterministically. (Production is unaffected — frames stream continuously, so a
  one-time subscription race is invisible there.)
  """

  def await_subscriber(kind) when kind in [:video, :audio] do
    result =
      Enum.reduce_while(1..250, :timeout, fn _, _ ->
        state = :sys.get_state(Beamicom.NES.Output)

        if MapSet.size(Map.fetch!(state, kind)) > 0 do
          {:halt, :ok}
        else
          Process.sleep(2)
          {:cont, :timeout}
        end
      end)

    if result == :timeout do
      raise "await_subscriber(#{inspect(kind)}): no #{kind} subscriber registered within ~500ms"
    end

    :ok
  end
end
