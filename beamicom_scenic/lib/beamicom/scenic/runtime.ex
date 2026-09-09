defmodule Beamicom.Scenic.Runtime do
  @moduledoc "Compatibility API for the shared `Beamicom.Host.Runtime`."

  alias Beamicom.Host.{Input, Runtime}

  def child_spec(options) do
    name = Keyword.get(options, :name)
    id = if is_nil(name), do: __MODULE__, else: {__MODULE__, name}

    %{Runtime.child_spec(options) | id: id, start: {__MODULE__, :start_link, [options]}}
  end

  def start_link(options), do: Runtime.start_link(options)

  def set_input(server, %Input{} = input), do: Runtime.set_input(server, input)
  def pause(server), do: Runtime.pause(server)
  def resume(server), do: Runtime.resume(server)
  def step(server), do: Runtime.step(server)
  def snapshot(server), do: Runtime.snapshot(server)
end
