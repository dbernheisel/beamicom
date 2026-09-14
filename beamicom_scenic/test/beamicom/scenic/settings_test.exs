defmodule Beamicom.Scenic.SettingsTest do
  use ExUnit.Case, async: true

  alias Beamicom.Scenic.Settings

  test "missing files load defaults" do
    path = temporary_path()
    assert {:ok, settings} = Settings.load(path)
    assert settings == Settings.defaults()
  end

  test "settings round-trip through versioned JSON" do
    path = temporary_path()

    settings = %{
      Settings.defaults()
      | save_state_folder: "/tmp/beamicom states",
        nes_video_filter: :svideo,
        nes_lighting: true,
        nes_remove_sprite_limit: true,
        nes_trim_borders: true,
        gbc_video_filter: :pixel_transparency,
        integer_scaling: false,
        audio: false,
        volume: 35
    }

    assert :ok = Settings.save(settings, path)
    assert {:ok, ^settings} = Settings.load(path)

    decoded = path |> File.read!() |> :json.decode()
    assert decoded["version"] == 2
    assert decoded["nes_video_filter"] == "svideo"
    assert decoded["nes_lighting"] == true
    assert decoded["nes_remove_sprite_limit"] == true
    assert decoded["nes_trim_borders"] == true
    assert decoded["gbc_video_filter"] == "pixel_transparency"
    assert decoded["integer_scaling"] == false
    assert decoded["audio"] == false
    assert decoded["volume"] == 35
  end

  test "missing JSON keys inherit defaults while invalid values are rejected" do
    path = temporary_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, ~s({"nes_video_filter":"rgb"}))

    assert {:ok, settings} = Settings.load(path)
    assert settings.nes_video_filter == :rgb
    assert settings.nes_lighting == false
    assert settings.nes_remove_sprite_limit == false
    assert settings.nes_trim_borders == false
    assert settings.gbc_video_filter == :none
    assert settings.volume == 100

    File.write!(path, ~s({"nes_video_filter":"crt-magic"}))
    assert {:error, {:invalid_setting, :nes_video_filter}} = Settings.load(path)

    File.write!(path, "not json")
    assert {:error, :invalid_json} = Settings.load(path)
  end

  test "filter choices cycle and saved defaults do not override explicit play options" do
    settings = %{
      Settings.defaults()
      | nes_video_filter: :composite,
        nes_lighting: true,
        nes_remove_sprite_limit: true,
        audio: false,
        volume: 40
    }

    assert Settings.next_nes_video_filter(:none) == :composite
    assert Settings.next_nes_video_filter(:rgb) == :none
    assert Settings.next_gbc_video_filter(:none) == :pixel_transparency
    assert Settings.next_gbc_video_filter(:pixel_transparency) == :none

    options = Settings.player_options(:nes, [], settings)
    assert options[:audio] == false
    assert options[:volume] == 40
    assert options[:video_filter] == :composite
    assert options[:nes_lighting] == true
    assert options[:enhancements] == [unlimited_sprites: true, hide_horizontal_overscan: false]

    explicit =
      Settings.player_options(
        :nes,
        [
          video_filter: :rgb,
          nes_lighting: false,
          audio: true,
          volume: 75,
          enhancements: [unlimited_sprites: false]
        ],
        settings
      )

    assert explicit[:video_filter] == :rgb
    assert explicit[:nes_lighting] == false
    assert explicit[:audio] == true
    assert explicit[:volume] == 75
    assert explicit[:enhancements] == [unlimited_sprites: false]

    snes_options = Settings.player_options(:snes, [], settings)
    assert snes_options[:audio] == false
    assert snes_options[:volume] == 40
  end

  test "volume must be an integer percentage" do
    path = temporary_path()
    File.mkdir_p!(Path.dirname(path))

    for volume <- [-1, 101, 50.0, "50"] do
      File.write!(path, :json.encode(%{"volume" => volume}))
      assert {:error, {:invalid_setting, :volume}} = Settings.load(path)
    end
  end

  defp temporary_path do
    directory =
      Path.join(
        System.tmp_dir!(),
        "beamicom-settings-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(directory) end)
    Path.join(directory, "config.json")
  end
end
