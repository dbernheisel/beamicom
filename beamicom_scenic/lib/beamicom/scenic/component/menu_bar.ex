defmodule Beamicom.Scenic.Component.MenuBar do
  @moduledoc "Keyboard- and pointer-driven ZSNES-style application menu."

  use Scenic.Component, has_children: false

  import Scenic.Primitives, only: [group: 3, rect: 3, text: 3]

  alias Beamicom.Scenic.Component.{MenuItem, PopupMenu}
  alias Beamicom.Scenic.Theme
  alias Scenic.{Graph, Scene}

  @height 66

  @impl Scenic.Component
  def validate(%{width: width, menus: menus} = data)
      when is_number(width) and width > 0 and is_list(menus) and menus != [],
      do: {:ok, data}

  def validate(data),
    do: {:error, "expected menu data with :width and non-empty :menus, got: #{inspect(data)}"}

  @impl Scenic.Component
  def bounds(%{width: width}, _styles), do: {0, 0, width, @height}

  @impl Scenic.Scene
  def init(scene, data, opts) do
    state = %{
      selected_menu: 0,
      open_menu: nil,
      selected_item: nil,
      open_submenu: nil,
      selected_subitem: nil
    }

    graph = render(data, state)

    {:ok,
     scene
     |> assign(data: data, menu_state: state, graph: graph, id: opts[:id])
     |> push_graph(graph)}
  end

  @impl Scenic.Scene
  def handle_update(data, _opts, scene) do
    state = normalize_state(scene.assigns.menu_state, data.menus)
    {:noreply, put_menu_state(scene |> assign(data: data), state)}
  end

  @impl Scenic.Scene
  def handle_put({:key, key}, scene), do: {:noreply, handle_key(scene, key)}
  def handle_put(:close, scene), do: {:noreply, close_menu(scene)}

  def handle_put({:open, menu_id}, scene) do
    index = Enum.find_index(scene.assigns.data.menus, &(&1.id == menu_id))

    if index do
      :ok = capture_input(scene, [:cursor_button, :cursor_pos])

      {:noreply,
       put_menu_state(
         scene,
         open_menu(scene.assigns.menu_state, scene.assigns.data.menus, index)
       )}
    else
      {:noreply, scene}
    end
  end

  @impl Scenic.Scene
  def handle_input({:cursor_pos, _point}, {:menu_title, index}, scene) do
    state = scene.assigns.menu_state
    state = %{state | selected_menu: index}

    state =
      if is_integer(state.open_menu),
        do: open_menu(state, scene.assigns.data.menus, index),
        else: state

    {:noreply, put_menu_state(scene, state)}
  end

  def handle_input({:cursor_pos, _point}, {:menu_item, index}, scene) do
    {:noreply, select_item(scene, index)}
  end

  def handle_input({:cursor_pos, _point}, {:submenu_item, index}, scene) do
    {:noreply, select_subitem(scene, index)}
  end

  def handle_input({:cursor_button, {:btn_left, 1, _, _}}, {:menu_title, index}, scene) do
    {:noreply, activate_title(scene, index)}
  end

  def handle_input({:cursor_button, {:btn_left, 1, _, _}}, {:menu_item, index}, scene) do
    {:noreply, activate_item(scene, index)}
  end

  def handle_input(
        {:cursor_button, {:btn_left, 1, _, _}},
        {:submenu_item, index},
        scene
      ) do
    {:noreply, activate_subitem(scene, index)}
  end

  def handle_input({:cursor_button, {:btn_left, 1, _, _}}, _id, scene) do
    {:noreply, close_menu(scene)}
  end

  def handle_input({:key, {key, 1, _mods}}, _id, scene) do
    {:noreply, handle_key(scene, key)}
  end

  def handle_input(_input, _id, scene), do: {:noreply, scene}

  @doc false
  def next_enabled(items, current, direction) when direction in [-1, 1] do
    enabled =
      items
      |> Enum.with_index()
      |> Enum.reject(fn {item, _index} ->
        item == :separator or not Map.get(item, :enabled, true)
      end)
      |> Enum.map(&elem(&1, 1))

    case enabled do
      [] -> nil
      indices -> cycle(indices, current, direction)
    end
  end

  defp render(data, state) do
    positions = menu_positions(data.menus)

    graph =
      Graph.build()
      |> rect({data.width, @height}, fill: {7, 28, 72, 226}, stroke: {2, Theme.cyan()})

    graph =
      data.menus
      |> Enum.with_index()
      |> Enum.reduce(graph, fn {menu, index}, graph ->
        {x, width} = Enum.at(positions, index)
        selected = index == state.selected_menu

        graph
        |> rect({width, @height - 12},
          id: {:menu_title, index},
          fill: if(selected, do: {151, 235, 255, 92}, else: :transparent),
          input: [:cursor_button, :cursor_pos],
          t: {x, 6}
        )
        |> text(menu.label,
          fill: Theme.white(),
          font: :beamicom_ui,
          font_size: 27,
          t: {x + 16, 43}
        )
      end)

    case state.open_menu do
      nil ->
        graph

      index ->
        menu = Enum.at(data.menus, index)
        {x, _width} = Enum.at(positions, index)

        graph =
          group(graph, &PopupMenu.add_to_graph(&1, menu.items, state.selected_item),
            t: {x, @height + 8}
          )

        render_submenu(graph, menu.items, state, x, data.width)
    end
  end

  defp render_submenu(graph, items, %{open_submenu: index} = state, x, available_width)
       when is_integer(index) do
    case Enum.at(items, index) do
      %{submenu: submenu} when is_list(submenu) and submenu != [] ->
        parent_width = PopupMenu.width(items)
        submenu_width = PopupMenu.width(submenu)
        right = x + parent_width + 4
        left = x - submenu_width - 4

        submenu_x =
          cond do
            right + submenu_width <= available_width -> right
            left >= 0 -> left
            true -> max(available_width - submenu_width, 0)
          end

        group(
          graph,
          &PopupMenu.add_to_graph(&1, submenu, state.selected_subitem, :submenu_item),
          t: {submenu_x, @height + 14 + index * MenuItem.height()}
        )

      _item ->
        graph
    end
  end

  defp render_submenu(graph, _items, _state, _x, _available_width), do: graph

  defp menu_positions(menus) do
    {positions, _x} =
      Enum.map_reduce(menus, 0, fn menu, x ->
        width = max(140, String.length(menu.label) * 27 + 32)
        {{x, width}, x + width}
      end)

    positions
  end

  defp activate_title(scene, index) do
    menu = Enum.at(scene.assigns.data.menus, index)

    cond do
      Map.has_key?(menu, :action) ->
        send_parent_event(scene, {:menu_action, menu.action})
        close_menu(scene)

      scene.assigns.menu_state.open_menu == index ->
        close_menu(scene)

      true ->
        :ok = capture_input(scene, [:cursor_button, :cursor_pos])
        send_parent_event(scene, {:menu_opened, menu.id})

        put_menu_state(
          scene,
          open_menu(scene.assigns.menu_state, scene.assigns.data.menus, index)
        )
    end
  end

  defp activate_item(scene, index) do
    state = scene.assigns.menu_state

    with open when is_integer(open) <- state.open_menu,
         menu <- Enum.at(scene.assigns.data.menus, open),
         item when is_map(item) <- Enum.at(menu.items, index),
         true <- Map.get(item, :enabled, true) do
      case item do
        %{submenu: submenu} when is_list(submenu) and submenu != [] ->
          put_menu_state(scene, open_submenu(state, index, submenu))

        %{action: action} ->
          send_parent_event(scene, {:menu_action, action})
          close_menu(scene)
      end
    else
      _ -> scene
    end
  end

  defp activate_subitem(scene, index) do
    state = scene.assigns.menu_state

    with {:ok, submenu} <- current_submenu(scene, state),
         item when is_map(item) <- Enum.at(submenu, index),
         true <- Map.get(item, :enabled, true),
         action <- Map.fetch!(item, :action) do
      send_parent_event(scene, {:menu_action, action})
      close_menu(scene)
    else
      _ -> scene
    end
  end

  defp select_item(scene, index) do
    state = scene.assigns.menu_state

    case state.open_menu do
      nil ->
        scene

      open ->
        items = Enum.at(scene.assigns.data.menus, open).items
        item = Enum.at(items, index)

        if is_map(item) and Map.get(item, :enabled, true) do
          state = %{state | selected_item: index}

          state =
            case item do
              %{submenu: submenu} when is_list(submenu) and submenu != [] ->
                open_submenu(state, index, submenu)

              _item ->
                %{state | open_submenu: nil, selected_subitem: nil}
            end

          put_menu_state(scene, state)
        else
          scene
        end
    end
  end

  defp select_subitem(scene, index) do
    state = scene.assigns.menu_state

    with {:ok, submenu} <- current_submenu(scene, state),
         item when is_map(item) <- Enum.at(submenu, index),
         true <- Map.get(item, :enabled, true) do
      put_menu_state(scene, %{state | selected_subitem: index})
    else
      _ -> scene
    end
  end

  defp handle_key(scene, :key_escape) do
    state = scene.assigns.menu_state

    if is_integer(state.open_submenu),
      do: put_menu_state(scene, %{state | open_submenu: nil, selected_subitem: nil}),
      else: close_menu(scene)
  end

  defp handle_key(scene, :key_left) do
    state = scene.assigns.menu_state

    if is_integer(state.open_submenu),
      do: put_menu_state(scene, %{state | open_submenu: nil, selected_subitem: nil}),
      else: move_menu(scene, -1)
  end

  defp handle_key(scene, :key_right) do
    state = scene.assigns.menu_state

    cond do
      is_integer(state.open_submenu) ->
        scene

      is_integer(state.open_menu) ->
        case selected_submenu(scene, state) do
          {:ok, submenu} ->
            put_menu_state(scene, open_submenu(state, state.selected_item, submenu))

          :error ->
            move_menu(scene, 1)
        end

      true ->
        move_menu(scene, 1)
    end
  end

  defp handle_key(scene, key) when key in [:key_up, :key_down] do
    state = scene.assigns.menu_state
    direction = if key == :key_down, do: 1, else: -1

    cond do
      is_integer(state.open_submenu) ->
        {:ok, submenu} = current_submenu(scene, state)
        selected = next_enabled(submenu, state.selected_subitem, direction)
        put_menu_state(scene, %{state | selected_subitem: selected})

      is_nil(state.open_menu) ->
        activate_title(scene, state.selected_menu)

      true ->
        items = Enum.at(scene.assigns.data.menus, state.open_menu).items
        selected = next_enabled(items, state.selected_item, direction)

        put_menu_state(scene, %{
          state
          | selected_item: selected,
            open_submenu: nil,
            selected_subitem: nil
        })
    end
  end

  defp handle_key(scene, key) when key in [:key_enter, :key_space] do
    state = scene.assigns.menu_state

    cond do
      is_integer(state.open_submenu) -> activate_subitem(scene, state.selected_subitem)
      is_nil(state.open_menu) -> activate_title(scene, state.selected_menu)
      true -> activate_item(scene, state.selected_item)
    end
  end

  defp handle_key(scene, _key), do: scene

  defp move_menu(scene, direction) when direction in [-1, 1] do
    state = scene.assigns.menu_state
    count = length(scene.assigns.data.menus)
    index = Integer.mod(state.selected_menu + direction, count)

    state =
      if is_integer(state.open_menu),
        do: open_menu(state, scene.assigns.data.menus, index),
        else: %{state | selected_menu: index}

    put_menu_state(scene, state)
  end

  defp open_menu(state, menus, index) do
    menu = Enum.at(menus, index)

    if Map.has_key?(menu, :items) do
      %{
        state
        | selected_menu: index,
          open_menu: index,
          selected_item: next_enabled(menu.items, nil, 1),
          open_submenu: nil,
          selected_subitem: nil
      }
    else
      %{
        state
        | selected_menu: index,
          open_menu: nil,
          selected_item: nil,
          open_submenu: nil,
          selected_subitem: nil
      }
    end
  end

  defp open_submenu(state, index, submenu) do
    %{
      state
      | selected_item: index,
        open_submenu: index,
        selected_subitem: next_enabled(submenu, nil, 1)
    }
  end

  defp selected_submenu(scene, state) do
    menu = Enum.at(scene.assigns.data.menus, state.open_menu)

    case Enum.at(menu.items, state.selected_item) do
      %{submenu: submenu} when is_list(submenu) and submenu != [] -> {:ok, submenu}
      _item -> :error
    end
  end

  defp current_submenu(scene, state) do
    menu = Enum.at(scene.assigns.data.menus, state.open_menu)

    case Enum.at(menu.items, state.open_submenu) do
      %{submenu: submenu} when is_list(submenu) and submenu != [] -> {:ok, submenu}
      _item -> :error
    end
  end

  defp close_menu(%Scene{} = scene) do
    if is_integer(scene.assigns.menu_state.open_menu), do: release_input(scene)

    put_menu_state(scene, %{
      scene.assigns.menu_state
      | open_menu: nil,
        selected_item: nil,
        open_submenu: nil,
        selected_subitem: nil
    })
  end

  defp put_menu_state(scene, state) do
    graph = render(scene.assigns.data, state)
    scene |> assign(menu_state: state, graph: graph) |> push_graph(graph)
  end

  defp normalize_state(state, menus) do
    selected_menu = min(state.selected_menu, length(menus) - 1)

    if is_integer(state.open_menu),
      do: open_menu(%{state | selected_menu: selected_menu}, menus, selected_menu),
      else: %{state | selected_menu: selected_menu}
  end

  defp cycle(indices, nil, 1), do: hd(indices)
  defp cycle(indices, nil, -1), do: List.last(indices)

  defp cycle(indices, current, direction) do
    position = Enum.find_index(indices, &(&1 == current)) || if(direction == 1, do: -1, else: 0)
    Enum.at(indices, Integer.mod(position + direction, length(indices)))
  end
end
