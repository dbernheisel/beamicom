defmodule Beamicom.Scenic.Shutdown do
  @moduledoc false

  @doc "Start an orderly, non-blocking Scenic and system shutdown."
  def fun(status) when is_integer(status) do
    spawn(fn -> run(status) end)
    :ok
  end

  @doc false
  def run(status, system_stop \\ &System.stop/1)
      when is_integer(status) and is_function(system_stop, 1) do
    try do
      Beamicom.Scenic.stop()
    after
      system_stop.(status)
    end
  end
end
