defmodule Beamicom.Scenic.Component.Background do
  @moduledoc "A time-based, looping vector background for the Beamicom shell."

  use Scenic.Component, has_children: false

  import Scenic.Primitives, only: [circle: 3, group: 3, line: 3, triangle: 3]

  alias Beamicom.Scenic.Theme
  alias Scenic.{Graph, Primitive}

  @frame_rate 60
  @grid_lines 11
  @ship_count 3

  @impl Scenic.Component
  def validate({width, height} = size)
      when is_number(width) and width > 0 and is_number(height) and height > 0,
      do: {:ok, size}

  def validate(data), do: {:error, "expected a positive {width, height}, got: #{inspect(data)}"}

  @impl Scenic.Component
  def bounds({width, height}, _styles), do: {0, 0, width, height}

  @impl Scenic.Scene
  def init(scene, size, _opts) do
    started_at = now_ms()
    graph = size |> build_graph() |> animate(size, 0)
    schedule_tick(started_at)

    {:ok,
     scene
     |> assign(size: size, graph: graph, started_at: started_at)
     |> push_graph(graph)}
  end

  @impl Scenic.Scene
  def handle_update(size, _opts, scene) do
    elapsed = now_ms() - scene.assigns.started_at
    graph = size |> build_graph() |> animate(size, elapsed)
    {:noreply, scene |> assign(size: size, graph: graph) |> push_graph(graph)}
  end

  @impl true
  def handle_info(:background_tick, scene) do
    elapsed = now_ms() - scene.assigns.started_at
    graph = animate(scene.assigns.graph, scene.assigns.size, elapsed)
    schedule_tick(scene.assigns.started_at)
    {:noreply, scene |> assign(graph: graph) |> push_graph(graph)}
  end

  @doc false
  def animation_frame({width, height}, elapsed_ms) do
    horizon = height * 0.59
    floor_height = height - horizon
    grid_phase = rem(elapsed_ms, 1_400) / 1_400
    star_offset = rem(elapsed_ms, round(height * 110)) / 110

    grid =
      for index <- 0..(@grid_lines - 1) do
        phase = index / @grid_lines + grid_phase
        depth = phase - Float.floor(phase)
        horizon + floor_height * depth * depth
      end

    ships = for index <- 0..(@ship_count - 1), do: ship_frame(index, width, height, elapsed_ms)

    %{grid: grid, star_offset: star_offset, ships: ships}
  end

  defp build_graph({width, height}) do
    horizon = height * 0.59

    Graph.build()
    |> add_stars(width, height)
    |> add_grid(width, horizon)
    |> add_ships()
  end

  defp add_stars(graph, width, height) do
    stars = fn graph ->
      Enum.reduce(star_positions(width, height), graph, fn {x, y, radius}, graph ->
        circle(graph, radius, fill: {232, 246, 255, 180}, t: {x, y})
      end)
    end

    graph
    |> group(stars, id: :stars_a)
    |> group(stars, id: :stars_b)
  end

  defp star_positions(width, height) do
    for index <- 0..17 do
      x = 34 + rem(index * 137 + index * index * 11, max(round(width - 68), 1))
      y = 34 + rem(index * 83 + index * index * 7, max(round(height - 68), 1))
      radius = if rem(index, 5) == 0, do: 1.8, else: 1.1
      {x, y, radius}
    end
  end

  defp add_grid(graph, width, horizon) do
    Enum.reduce(0..(@grid_lines - 1), graph, fn index, graph ->
      line(graph, {{0, horizon}, {width, horizon}},
        id: {:grid_line, index},
        stroke: {1, {24, 94, 202, 210}}
      )
    end)
  end

  defp add_ships(graph) do
    Enum.reduce(0..(@ship_count - 1), graph, fn index, graph ->
      group(graph, &ship/1, id: {:ship, index})
    end)
  end

  defp ship(graph) do
    graph
    |> triangle({{-34, 10}, {0, -23}, {0, 7}},
      fill: {68, 204, 238, 205},
      stroke: {1, Theme.bright_cyan()}
    )
    |> triangle({{0, -23}, {34, 10}, {0, 7}},
      fill: {35, 102, 216, 210},
      stroke: {1, Theme.cyan()}
    )
    |> line({{-34, 10}, {0, 25}}, stroke: {2, Theme.cyan()})
    |> line({{34, 10}, {0, 25}}, stroke: {2, Theme.cyan()})
    |> line({{0, 7}, {0, 25}}, stroke: {1, {151, 235, 255, 170}})
  end

  defp animate(graph, size, elapsed_ms) do
    %{grid: grid, star_offset: star_offset, ships: ships} = animation_frame(size, elapsed_ms)

    graph =
      graph
      |> Graph.modify(:stars_a, &Primitive.put_transform(&1, :translate, {0, star_offset}))
      |> Graph.modify(
        :stars_b,
        &Primitive.put_transform(&1, :translate, {0, star_offset - elem(size, 1)})
      )

    graph =
      grid
      |> Enum.with_index()
      |> Enum.reduce(graph, fn {y, index}, graph ->
        Graph.modify(
          graph,
          {:grid_line, index},
          &line(&1, {{0, y}, {elem(size, 0), y}}, [])
        )
      end)

    ships
    |> Enum.with_index()
    |> Enum.reduce(graph, fn {%{position: position, scale: scale}, index}, graph ->
      Graph.modify(graph, {:ship, index}, fn primitive ->
        primitive
        |> Primitive.put_transform(:translate, position)
        |> Primitive.put_transform(:scale, scale)
      end)
    end)
  end

  defp ship_frame(0, width, height, elapsed_ms) do
    progress = progress(elapsed_ms, 10_800, 0)

    %{
      position:
        {-70 + (width + 140) * progress,
         height * (0.29 + 0.05 * :math.sin(progress * :math.pi() * 2))},
      scale: 0.42 + 0.72 * depth(progress)
    }
  end

  defp ship_frame(1, width, height, elapsed_ms) do
    progress = progress(elapsed_ms, 14_600, 4_700)

    %{
      position:
        {width + 80 - (width + 160) * progress,
         height * (0.43 - 0.08 * :math.sin(progress * :math.pi()))},
      scale: 0.55 + 1.05 * depth(progress)
    }
  end

  defp ship_frame(2, width, height, elapsed_ms) do
    progress = progress(elapsed_ms, 17_200, 9_100)

    %{
      position:
        {-80 + (width + 160) * progress,
         height * (0.71 + 0.06 * :math.sin(progress * :math.pi() * 2))},
      scale: 0.72 + 0.9 * depth(progress)
    }
  end

  defp progress(elapsed_ms, duration, offset), do: rem(elapsed_ms + offset, duration) / duration
  defp depth(progress), do: 1.0 - abs(progress * 2.0 - 1.0)

  defp schedule_tick(started_at) do
    elapsed = max(now_ms() - started_at, 0)
    next_frame = div(elapsed * @frame_rate, 1_000) + 1
    deadline = div(next_frame * 1_000 + @frame_rate - 1, @frame_rate)
    Process.send_after(self(), :background_tick, max(deadline - elapsed, 1))
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
