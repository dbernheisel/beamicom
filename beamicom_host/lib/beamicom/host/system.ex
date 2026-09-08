defmodule Beamicom.Host.System do
  @moduledoc """
  Coarse-grained contract between an emulator core and its host.

  A core owns all timing-sensitive CPU, bus, graphics, and audio work. The host
  crosses this boundary only to load media, advance to the core's next useful
  output boundary, or replace a controller state. In particular, this behaviour
  is not intended for callbacks from individual instructions or bus accesses.
  """

  alias Beamicom.Host.{AudioChunk, Input, VideoFrame}

  @type machine :: term()
  @type output :: VideoFrame.t() | AudioChunk.t()

  @callback id() :: atom()
  @callback capabilities() :: map()
  @callback load(media :: binary(), options :: keyword()) :: {:ok, machine()} | {:error, term()}
  @callback run_slice(machine()) :: {machine(), [output()]}
  @callback set_input(machine(), Input.t()) :: machine()
end
