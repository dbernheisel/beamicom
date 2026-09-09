defmodule BeamicomV4L2.Runtime do
  @moduledoc "Compatibility API for the shared `Beamicom.Host.Runtime`."

  alias Beamicom.Host.{Input, Runtime}

  def child_spec(options) do
    name = Keyword.get(options, :name)
    id = if is_nil(name), do: __MODULE__, else: {__MODULE__, name}
    options = Keyword.put_new(options, :system, Beamicom.GB.System)

    %{Runtime.child_spec(options) | id: id, start: {__MODULE__, :start_link, [options]}}
  end

  def start_link(options) do
    options
    |> Keyword.put_new(:system, Beamicom.GB.System)
    |> Runtime.start_link()
  end

  @spec set_input(GenServer.server(), Input.t()) :: :ok
  def set_input(server, %Input{} = input), do: Runtime.set_input(server, input)

  @spec snapshot(GenServer.server()) :: term()
  def snapshot(server), do: Runtime.snapshot(server)
end
