defmodule Beamicom.Scenic.Component.MenuBarTest do
  use ExUnit.Case, async: true

  alias Beamicom.Scenic.Component.{MenuBar, MenuItem, PopupMenu}
  alias Beamicom.Scenic.{Menu, Settings}

  test "the menu model derives session-only action availability" do
    settings = %{
      Settings.defaults()
      | recent_roms: ["/roms/Chrono Trigger.sfc", "/roms/Metroid.nes"]
    }

    idle = Menu.model(false, settings)
    running = Menu.model(true, settings)

    idle_game = Enum.find(idle, &(&1.id == :game))
    running_game = Enum.find(running, &(&1.id == :game))

    assert enabled?(idle_game, :load)
    refute enabled?(idle_game, :reset)
    assert item(idle_game, :run) == nil
    assert item(idle_game, :save_state) == nil
    assert item(idle_game, :load_state) == nil

    assert Enum.map(Enum.filter(idle_game.items, &is_map/1), &{&1.label, &1.action}) == [
             {"Load", :load},
             {"Reset", :reset},
             {"Chrono Trigger.sfc", {:load_recent, "/roms/Chrono Trigger.sfc"}},
             {"Metroid.nes", {:load_recent, "/roms/Metroid.nes"}}
           ]

    assert enabled?(running_game, :reset)
    assert enabled?(running_game, :save_state)
    assert enabled?(running_game, :load_state)
    assert item(running_game, :save_state).label == "Save State"
    assert item(running_game, :load_state).label == "Load State"
  end

  test "the Config menu exposes persisted settings and their selected values" do
    settings = %{
      Settings.defaults()
      | save_state_folder: "/tmp/my-states",
        nes_video_filter: :composite,
        nes_lighting: true,
        nes_remove_sprite_limit: true,
        nes_trim_borders: false,
        gbc_video_filter: :pixel_transparency,
        integer_scaling: false,
        audio: false,
        volume: 35
    }

    config = Menu.model(false, settings) |> Enum.find(&(&1.id == :config))
    items = Enum.filter(config.items, &is_map/1)

    assert Enum.map(Menu.model(false, settings), & &1.id) == [:game, :config]

    assert Enum.map(items, & &1.id) == [
             :save_state_folder,
             :nes,
             :gbc,
             :integer_scaling,
             :audio,
             :volume
           ]

    assert item(config, :save_state_folder).label == "State folder..."
    assert item(config, :nes).label == "NES"
    assert item(config, :gbc).label == "GBC"

    nes_submenu = item(config, :nes).submenu
    gbc_submenu = item(config, :gbc).submenu

    assert Enum.map(filter_choices(nes_submenu, :nes_video_filter), & &1.action) == [
             {:nes_video_filter, :none},
             {:nes_video_filter, :composite},
             {:nes_video_filter, :svideo},
             {:nes_video_filter, :rgb}
           ]

    assert Enum.find(filter_choices(nes_submenu, :nes_video_filter), & &1.checked).action ==
             {:nes_video_filter, :composite}

    assert item_in(nes_submenu, {:nes_video_filter, :composite}).label == "Composite"

    assert Enum.map(filter_choices(gbc_submenu, :gbc_video_filter), & &1.action) == [
             {:gbc_video_filter, :none},
             {:gbc_video_filter, :pixel_transparency}
           ]

    assert Enum.find(filter_choices(gbc_submenu, :gbc_video_filter), & &1.checked).action ==
             {:gbc_video_filter, :pixel_transparency}

    assert item_in(nes_submenu, :nes_filter_section).label == "FILTER"
    assert item_in(nes_submenu, :nes_enhancements_section).label == "ENHANCEMENTS"
    assert item_in(gbc_submenu, :gbc_filter_section).label == "FILTER"
    assert item_in(nes_submenu, :nes_lighting).checked
    assert item_in(nes_submenu, :nes_lighting).label == "Sprite lighting"
    assert item_in(nes_submenu, :nes_remove_sprite_limit).checked
    refute item_in(nes_submenu, :nes_trim_borders).checked

    assert item(config, :integer_scaling).label == "Integer scaling"
    refute item(config, :integer_scaling).checked
    refute item(config, :audio).checked
    assert item(config, :volume).slider == %{min: 0, max: 100, value: 35, step: 1}

    assert MenuItem.display_label(item(config, :integer_scaling)) ==
             "  Integer scaling  OFF"

    assert MenuItem.display_label(item(config, :audio)) == "  Audio  OFF"
    assert MenuItem.display_label(item(config, :volume)) == "  Volume  35"
    assert MenuItem.slider_value(item(config, :volume), PopupMenu.width(config.items), 0) == 0

    assert MenuItem.slider_value(
             item(config, :volume),
             PopupMenu.width(config.items),
             PopupMenu.width(config.items)
           ) == 100

    assert PopupMenu.width(nes_submenu) >= 286
    assert PopupMenu.width(gbc_submenu) >= 286
    assert PopupMenu.width(config.items) >= 520

    {:ok, {Scenic.Assets.Static.Font, metrics}} =
      Scenic.Assets.Static.meta(:beamicom_ui)

    for popup_items <- [config.items, nes_submenu, gbc_submenu],
        popup_item <- popup_items,
        popup_item != :separator do
      text_width = FontMetrics.width(MenuItem.display_label(popup_item), 23, metrics)
      assert text_width + 30 <= PopupMenu.width(popup_items)
    end
  end

  test "keyboard selection skips separators and disabled entries and wraps" do
    items = [
      %{id: :load, enabled: true},
      %{id: :run, enabled: false},
      :separator,
      %{id: :controller, enabled: true}
    ]

    assert MenuBar.next_enabled(items, nil, 1) == 0
    assert MenuBar.next_enabled(items, 0, 1) == 3
    assert MenuBar.next_enabled(items, 3, 1) == 0
    assert MenuBar.next_enabled(items, 0, -1) == 3
  end

  test "unfinished systems can reset while showing disabled save-state actions" do
    game = Menu.model(true, Settings.defaults(), false) |> Enum.find(&(&1.id == :game))

    assert item(game, :run) == nil
    assert enabled?(game, :reset)
    refute enabled?(game, :save_state)
    refute enabled?(game, :load_state)
  end

  defp enabled?(menu, id) do
    menu |> item(id) |> Map.fetch!(:enabled)
  end

  defp item(menu, id), do: Enum.find(menu.items, &(is_map(&1) and &1.id == id))

  defp item_in(items, id), do: Enum.find(items, &(is_map(&1) and &1.id == id))

  defp filter_choices(items, setting) do
    Enum.filter(items, fn
      %{action: {^setting, _value}} -> true
      _item -> false
    end)
  end
end
