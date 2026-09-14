defmodule Beamicom.Scenic.Component.SaveStateBrowser do
  @moduledoc "In-window, horizontally scrolling browser for ROM-associated save states."

  use Scenic.Component, has_children: false

  import Scenic.Primitives, only: [group: 3, rect: 3, text: 3]

  alias Beamicom.Scenic.{SaveState, Theme}
  alias Scenic.Assets.Stream
  alias Scenic.Assets.Stream.Image
  alias Scenic.Graph

  @card_width 220
  @card_gap 20
  @card_span @card_width + @card_gap
  @strip_height 238
  @preview_width 196
  @preview_height 166
  @button_width 112
  @button_gap 12

  @impl Scenic.Component
  def validate(%{size: {width, height}, paths: paths, rom_hash: rom_hash} = data)
      when is_number(width) and width >= 480 and is_number(height) and height >= 330 and
             is_list(paths) and is_binary(rom_hash),
      do: {:ok, data}

  def validate(data),
    do: {:error, "expected save-state browser size, paths, and ROM hash, got: #{inspect(data)}"}

  @impl Scenic.Component
  def bounds(%{size: {width, height}}, _styles), do: {0, 0, width, height}

  @impl Scenic.Scene
  def init(scene, data, _opts) do
    Stream.start_link(nil)
    entries = load_entries(data.paths, data.rom_hash)
    selected = if entries == [], do: nil, else: 0
    graph = render(data.size, entries, selected)

    {:ok,
     scene
     |> assign(data: data, entries: entries, selected: selected, graph: graph)
     |> push_graph(graph)}
  end

  @impl Scenic.Scene
  def handle_update(data, opts, scene) do
    delete_streams(scene)
    init(scene, data, opts)
  end

  @impl Scenic.Scene
  def handle_put({:key, key}, scene), do: {:noreply, handle_key(scene, key)}

  @impl Scenic.Scene
  def handle_input({:cursor_button, {:btn_left, 1, _, _}}, {:state, index}, scene),
    do: {:noreply, select(scene, index)}

  def handle_input({:cursor_button, {:btn_left, 1, _, _}}, :previous, scene),
    do: {:noreply, move(scene, -1)}

  def handle_input({:cursor_button, {:btn_left, 1, _, _}}, :next, scene),
    do: {:noreply, move(scene, 1)}

  def handle_input({:cursor_button, {:btn_left, 1, _, _}}, :load, scene),
    do: {:noreply, activate(scene)}

  def handle_input({:cursor_button, {:btn_left, 1, _, _}}, :open, scene) do
    send_parent_event(scene, {:state_browser, :open})
    {:noreply, scene}
  end

  def handle_input({:cursor_button, {:btn_left, 1, _, _}}, :cancel, scene) do
    send_parent_event(scene, {:state_browser, :cancel})
    {:noreply, scene}
  end

  def handle_input({:cursor_scroll, {{offset_x, offset_y}, _position}}, _id, scene) do
    offset = if abs(offset_x) > abs(offset_y), do: offset_x, else: offset_y
    direction = if offset < 0, do: 1, else: -1
    {:noreply, move(scene, direction)}
  end

  def handle_input(_input, _id, scene), do: {:noreply, scene}

  @impl true
  def terminate(_reason, scene) do
    delete_streams(scene)
    :ok
  end

  @doc false
  def next_index(0, _selected, _direction), do: nil
  def next_index(count, nil, _direction) when count > 0, do: 0

  def next_index(count, selected, direction) when count > 0 and direction in [-1, 1],
    do: min(max(selected + direction, 0), count - 1)

  @doc false
  def scroll_offset(width, count, selected) when count > 0 and is_integer(selected) do
    viewport_width = width - 96
    content_width = count * @card_span - @card_gap
    centered = selected * @card_span - (viewport_width - @card_width) / 2
    round(centered |> max(0) |> min(max(content_width - viewport_width, 0)))
  end

  def scroll_offset(_width, _count, _selected), do: 0

  @doc false
  def preview_layout(image_width, image_height)
      when image_width > 0 and image_height > 0 do
    scale = min(@preview_width / image_width, @preview_height / image_height)

    %{
      scale: scale,
      position: {
        (@preview_width - image_width * scale) / 2,
        (@preview_height - image_height * scale) / 2
      },
      display_size: {image_width * scale, image_height * scale}
    }
  end

  defp handle_key(scene, key) when key in [:key_left, :key_up], do: move(scene, -1)
  defp handle_key(scene, key) when key in [:key_right, :key_down], do: move(scene, 1)
  defp handle_key(scene, key) when key in [:key_enter, :key_space], do: activate(scene)

  defp handle_key(scene, :key_o) do
    send_parent_event(scene, {:state_browser, :open})
    scene
  end

  defp handle_key(scene, :key_escape) do
    send_parent_event(scene, {:state_browser, :cancel})
    scene
  end

  defp handle_key(scene, _key), do: scene

  defp move(scene, direction) do
    select(scene, next_index(length(scene.assigns.entries), scene.assigns.selected, direction))
  end

  defp select(scene, selected) do
    graph = render(scene.assigns.data.size, scene.assigns.entries, selected)
    scene |> assign(selected: selected, graph: graph) |> push_graph(graph)
  end

  defp activate(%{assigns: %{selected: nil}} = scene), do: scene

  defp activate(scene) do
    entry = Enum.at(scene.assigns.entries, scene.assigns.selected)
    send_parent_event(scene, {:state_browser, :load, entry.path})
    scene
  end

  defp load_entries(paths, rom_hash) do
    paths
    |> Enum.with_index()
    |> Enum.flat_map(fn {path, index} ->
      with {:ok, png} <- File.read(path),
           {:ok, {Image, {width, height, _mime}, _data} = image} <- Image.from_binary(png) do
        stream = "beamicom_state_#{:erlang.phash2({self(), path, index})}"
        :ok = Stream.put(stream, image)

        [
          %{
            path: path,
            label: SaveState.label(path, rom_hash),
            stream: stream,
            image_size: {width, height}
          }
        ]
      else
        _error -> []
      end
    end)
  end

  defp delete_streams(scene) do
    scene.assigns
    |> Map.get(:entries, [])
    |> Enum.each(&Stream.delete(&1.stream))
  end

  defp render({width, height}, entries, selected) do
    graph =
      Graph.build()
      |> rect({width, height}, fill: {5, 10, 32, 252}, stroke: {3, Theme.cyan()})
      |> text("LOAD STATE",
        fill: Theme.white(),
        font: :beamicom_ui,
        font_size: 27,
        t: {24, 42}
      )

    graph =
      if entries == [] do
        text(graph, "No states for this ROM",
          fill: Theme.muted(),
          font: :beamicom_ui,
          font_size: 22,
          text_align: :center,
          t: {width / 2, 176}
        )
      else
        add_strip(graph, width, entries, selected)
      end

    cancel_x = width - 24 - @button_width
    open_x = cancel_x - @button_gap - @button_width
    load_x = open_x - @button_gap - @button_width

    graph
    |> text("ARROWS SCROLL   ENTER LOAD   O OPEN   ESC CANCEL",
      fill: Theme.muted(),
      font: :beamicom_ui,
      font_size: 13,
      t: {24, height - 76}
    )
    |> add_button(:load, "Load", load_x, height - 58, not is_nil(selected))
    |> add_button(:open, "Open...", open_x, height - 58, true)
    |> add_button(:cancel, "Cancel", cancel_x, height - 58, true)
  end

  defp add_strip(graph, width, entries, selected) do
    viewport_width = width - 96
    offset = scroll_offset(width, length(entries), selected)

    graph
    |> rect({viewport_width, @strip_height},
      id: :strip,
      fill: :transparent,
      input: [:cursor_scroll],
      t: {48, 62}
    )
    |> text("PREV",
      id: :previous,
      fill: if(selected == 0, do: Theme.muted(), else: Theme.cyan()),
      font: :beamicom_ui,
      font_size: 24,
      input: [:cursor_button],
      t: {8, 180}
    )
    |> group(
      fn clipped ->
        group(
          clipped,
          fn strip ->
            entries
            |> Enum.with_index()
            |> Enum.reduce(strip, fn {entry, index}, strip ->
              add_card(strip, entry, index, index == selected)
            end)
          end,
          t: {-offset, 0}
        )
      end,
      t: {48, 62},
      scissor: {viewport_width, @strip_height}
    )
    |> text("NEXT",
      id: :next,
      fill: if(selected == length(entries) - 1, do: Theme.muted(), else: Theme.cyan()),
      font: :beamicom_ui,
      font_size: 24,
      input: [:cursor_button],
      text_align: :right,
      t: {width - 8, 180}
    )
    |> add_scrollbar(width, length(entries), offset)
  end

  defp add_card(graph, entry, index, selected?) do
    x = index * @card_span
    {image_width, image_height} = entry.image_size
    preview = preview_layout(image_width, image_height)

    graph
    |> rect({@card_width, 222},
      id: {:state, index},
      fill: if(selected?, do: {105, 213, 255, 58}, else: {7, 28, 72, 235}),
      stroke:
        {if(selected?, do: 3, else: 1), if(selected?, do: Theme.white(), else: Theme.blue())},
      input: [:cursor_button, :cursor_scroll],
      t: {x, 0}
    )
    |> group(
      fn clipped ->
        group(
          clipped,
          &rect(&1, {image_width, image_height}, fill: {:stream, entry.stream}),
          t: preview.position,
          scale: preview.scale
        )
      end,
      t: {x + 12, 10},
      scissor: {@preview_width, @preview_height}
    )
    |> group(
      fn clipped ->
        text(clipped, entry.label,
          fill: if(selected?, do: Theme.white(), else: Theme.muted()),
          font: :beamicom_ui,
          font_size: 13,
          text_align: :center,
          t: {@preview_width / 2, 24}
        )
      end,
      t: {x + 12, 178},
      scissor: {@preview_width, 34}
    )
  end

  defp add_scrollbar(graph, width, count, offset) do
    track_width = width - 96
    content_width = count * @card_span - @card_gap

    thumb_width =
      if content_width > 0,
        do: max(track_width * track_width / content_width, 42),
        else: track_width

    travel = max(track_width - thumb_width, 0)
    max_offset = max(content_width - track_width, 0)
    thumb_x = if max_offset > 0, do: offset / max_offset * travel, else: 0

    graph
    |> rect({track_width, 4}, fill: {24, 94, 202, 150}, t: {48, 306})
    |> rect({min(thumb_width, track_width), 6}, fill: Theme.cyan(), t: {48 + thumb_x, 305})
  end

  defp add_button(graph, id, label, right, top, enabled?) do
    graph
    |> rect({@button_width, 38},
      id: id,
      fill: if(enabled?, do: {24, 94, 202, 210}, else: {7, 28, 72, 220}),
      stroke: {1, if(enabled?, do: Theme.cyan(), else: Theme.muted())},
      input: if(enabled?, do: [:cursor_button], else: []),
      t: {right, top}
    )
    |> text(label,
      fill: if(enabled?, do: Theme.white(), else: Theme.muted()),
      font: :beamicom_ui,
      font_size: 18,
      text_align: :center,
      t: {right + @button_width / 2, top + 26}
    )
  end
end
