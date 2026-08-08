defmodule BeamicomV4L2.Stream do
  @moduledoc false
  use GenServer

  alias BeamicomV4L2.Native

  @defaults [
    framebuffer: "/dev/fb0",
    output: "/dev/video-beamicom",
    fps: 60,
    x: 0,
    y: 0,
    width: 0,
    height: 0
  ]

  def start_link(options) do
    {name, options} = Keyword.pop(options, :name)
    GenServer.start_link(__MODULE__, options, name_option(name))
  end

  def status(server), do: GenServer.call(server, :status)

  @impl true
  def init(options) do
    options = Keyword.merge(@defaults, options)

    with {:ok, framebuffer} <- fetch_string(options, :framebuffer),
         {:ok, output} <- fetch_string(options, :output),
         {:ok, fps} <- fetch_fps(options),
         {:ok, x} <- fetch_coordinate(options, :x),
         {:ok, y} <- fetch_coordinate(options, :y),
         {:ok, width} <- fetch_coordinate(options, :width),
         {:ok, height} <- fetch_coordinate(options, :height),
         {:ok, resource} <- Native.start(framebuffer, output, fps, x, y, width, height) do
      {:ok, resource}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:status, _from, resource) do
    {running, frames, error} = Native.status(resource)
    {:reply, %{running: running, frames: frames, error: error}, resource}
  end

  @impl true
  def terminate(_reason, resource) when is_reference(resource) do
    Native.stop(resource)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp fetch_string(options, key) do
    case Keyword.fetch!(options, key) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _value -> {:error, {:invalid_option, key}}
    end
  end

  defp fetch_fps(options) do
    case Keyword.fetch!(options, :fps) do
      fps when is_integer(fps) and fps in 1..1_000 -> {:ok, fps}
      _fps -> {:error, {:invalid_option, :fps}}
    end
  end

  defp fetch_coordinate(options, key) do
    case Keyword.fetch!(options, key) do
      value when is_integer(value) and value in 0..4_294_967_295 -> {:ok, value}
      _value -> {:error, {:invalid_option, key}}
    end
  end

  defp name_option(nil), do: []
  defp name_option(name), do: [name: name]
end
