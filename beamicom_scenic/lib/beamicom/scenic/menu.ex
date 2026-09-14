defmodule Beamicom.Scenic.Menu do
  @moduledoc false

  alias Beamicom.Scenic.Settings

  def model(session?, settings \\ Settings.defaults(), state_actions? \\ nil)
      when is_boolean(session?) do
    state_actions? = if is_nil(state_actions?), do: session?, else: state_actions?

    [
      %{
        id: :game,
        label: "Game",
        items: [
          item(:load, "Load..."),
          item(:run, "Run", session?),
          item(:reset, "Reset", session?),
          :separator,
          item(:save_state, "Save state...", session? and state_actions?),
          item(:load_state, "Load state...", session? and state_actions?)
        ]
      },
      %{
        id: :config,
        label: "Config",
        items: [
          item(:save_state_folder, "State folder..."),
          :separator,
          item(:nes, "NES", true, submenu: nes_menu(settings)),
          item(:gbc, "GBC", true, submenu: gbc_menu(settings)),
          :separator,
          item(:integer_scaling, "Integer scaling", true,
            toggle: true,
            checked: settings.integer_scaling
          ),
          item(:audio, "Audio", true, toggle: true, checked: settings.audio)
        ]
      }
    ]
  end

  defp nes_menu(settings) do
    [section(:nes_filter_section, "Filter")] ++
      Enum.map(Settings.nes_video_filters(), fn filter ->
        choice(:nes_video_filter, filter, nes_filter_label(filter), settings.nes_video_filter)
      end) ++
      [
        :separator,
        section(:nes_enhancements_section, "Enhancements"),
        item(:nes_lighting, "Sprite lighting", true,
          toggle: true,
          checked: settings.nes_lighting
        ),
        item(:nes_remove_sprite_limit, "Remove sprite limit", true,
          toggle: true,
          checked: settings.nes_remove_sprite_limit
        ),
        item(:nes_trim_borders, "Trim borders", true,
          toggle: true,
          checked: settings.nes_trim_borders
        )
      ]
  end

  defp gbc_menu(settings) do
    [section(:gbc_filter_section, "Filter")] ++
      Enum.map(Settings.gbc_video_filters(), fn filter ->
        choice(:gbc_video_filter, filter, gbc_filter_label(filter), settings.gbc_video_filter)
      end)
  end

  defp item(id, label, enabled \\ true, options \\ []) do
    %{id: id, label: label, action: id, enabled: enabled}
    |> Map.merge(Map.new(options))
  end

  defp choice(setting, value, label, selected) do
    %{
      id: {setting, value},
      label: label,
      action: {setting, value},
      enabled: true,
      checked: value == selected
    }
  end

  defp section(id, label), do: %{id: id, label: String.upcase(label), enabled: false}

  defp nes_filter_label(:none), do: "None"
  defp nes_filter_label(:composite), do: "Blargg composite"
  defp nes_filter_label(:svideo), do: "S-Video"
  defp nes_filter_label(:rgb), do: "RGB"

  defp gbc_filter_label(:none), do: "None"
  defp gbc_filter_label(:pixel_transparency), do: "Pixel transparency"
end
