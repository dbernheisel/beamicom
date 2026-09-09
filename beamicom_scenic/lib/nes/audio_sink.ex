defmodule Beamicom.NES.AudioSink do
  @moduledoc """
  Compatibility wrapper for `Beamicom.Scenic.AudioSink`.

  New integrations should use the system-neutral module. Calls through this
  module retain the historical default registered name.
  """

  def child_spec(options) do
    %{
      Beamicom.Scenic.AudioSink.child_spec(options)
      | id: __MODULE__,
        start: {__MODULE__, :start_link, [options]}
    }
  end

  def start_link(options \\ []) do
    options
    |> Keyword.put_new(:name, __MODULE__)
    |> Beamicom.Scenic.AudioSink.start_link()
  end

  defdelegate default_command(speed), to: Beamicom.Scenic.AudioSink
  defdelegate default_command(speed, audio), to: Beamicom.Scenic.AudioSink
  defdelegate default_command(speed, audio, os), to: Beamicom.Scenic.AudioSink
end
