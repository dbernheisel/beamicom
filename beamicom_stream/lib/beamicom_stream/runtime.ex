defmodule BeamicomStream.Runtime do
  @moduledoc "Compatibility API for the shared `Beamicom.Host.Runtime`."

  alias Beamicom.Host.{Input, Runtime}

  def child_spec(options) do
    name = Keyword.get(options, :name)
    id = if is_nil(name), do: __MODULE__, else: {__MODULE__, name}

    %{Runtime.child_spec(options) | id: id, start: {__MODULE__, :start_link, [options]}}
  end

  def start_link(options), do: Runtime.start_link(options)

  @spec load(module(), binary(), keyword()) :: {:ok, term()} | {:error, term()}
  def load(system, media, options \\ []), do: Runtime.load(system, media, options)

  @spec set_input(GenServer.server(), Input.t()) :: :ok
  def set_input(server, %Input{} = input), do: Runtime.set_input(server, input)

  @spec snapshot(GenServer.server()) :: term()
  def snapshot(server), do: Runtime.snapshot(server)
end
