defmodule Beamicom.Scenic.Settings do
  @moduledoc "Persistent user settings for the Scenic application shell."

  @version 2
  @nes_video_filters [:none, :composite, :svideo, :rgb]
  @gbc_video_filters [:none, :pixel_transparency]

  @type t :: %{
          save_state_folder: String.t(),
          nes_video_filter: :none | :composite | :svideo | :rgb,
          nes_lighting: boolean(),
          nes_remove_sprite_limit: boolean(),
          nes_trim_borders: boolean(),
          gbc_video_filter: :none | :pixel_transparency,
          integer_scaling: boolean(),
          audio: boolean(),
          volume: 0..100
        }

  def nes_video_filters, do: @nes_video_filters
  def gbc_video_filters, do: @gbc_video_filters

  @spec defaults() :: t()
  def defaults do
    %{
      save_state_folder: Path.join([data_home(), "beamicom", "states"]),
      nes_video_filter: :none,
      nes_lighting: false,
      nes_remove_sprite_limit: false,
      nes_trim_borders: false,
      gbc_video_filter: :none,
      integer_scaling: true,
      audio: true,
      volume: 100
    }
  end

  @spec path() :: String.t()
  def path do
    Path.join([config_home(), "beamicom", "config.json"])
  end

  @spec load(String.t()) :: {:ok, t()} | {:error, term()}
  def load(path \\ path()) when is_binary(path) do
    case File.read(path) do
      {:ok, json} -> decode(json)
      {:error, :enoent} -> {:ok, defaults()}
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  @spec load_or_defaults(String.t()) :: t()
  def load_or_defaults(path \\ path()) do
    case load(path) do
      {:ok, settings} -> settings
      {:error, _reason} -> defaults()
    end
  end

  @spec save(map(), String.t()) :: :ok | {:error, term()}
  def save(settings, path \\ path()) when is_map(settings) and is_binary(path) do
    with {:ok, settings} <- normalize(settings),
         :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, encoded} <- encode(settings) do
      write_atomic(path, encoded <> "\n")
    end
  end

  @spec next_nes_video_filter(atom()) :: atom()
  def next_nes_video_filter(current), do: next(@nes_video_filters, current)

  @spec next_gbc_video_filter(atom()) :: atom()
  def next_gbc_video_filter(current), do: next(@gbc_video_filters, current)

  @spec player_options(:nes | :gbc | :snes, keyword(), t()) :: keyword()
  def player_options(system, options, settings \\ load_or_defaults())

  def player_options(system, options, settings)
      when system in [:nes, :gbc] and is_list(options) and is_map(settings) do
    configured_filter =
      case system do
        :nes -> settings.nes_video_filter
        :gbc -> settings.gbc_video_filter
      end

    options =
      options
      |> Keyword.put_new(:video_filter, filter_option(configured_filter))
      |> Keyword.put_new(:audio, settings.audio)
      |> Keyword.put_new(:volume, settings.volume)

    if system == :nes do
      options
      |> Keyword.put_new(:nes_lighting, settings.nes_lighting)
      |> Keyword.put_new(:enhancements,
        unlimited_sprites: settings.nes_remove_sprite_limit,
        hide_horizontal_overscan: settings.nes_trim_borders
      )
    else
      options
    end
  end

  def player_options(:snes, options, settings) when is_list(options) and is_map(settings),
    do:
      options
      |> Keyword.put_new(:audio, settings.audio)
      |> Keyword.put_new(:volume, settings.volume)

  defp decode(json) do
    with {:ok, decoded} <- decode_json(json),
         true <- is_map(decoded) || {:error, :invalid_root},
         settings <- %{
           save_state_folder: Map.get(decoded, "save_state_folder"),
           nes_video_filter: Map.get(decoded, "nes_video_filter"),
           nes_lighting: Map.get(decoded, "nes_lighting"),
           nes_remove_sprite_limit: Map.get(decoded, "nes_remove_sprite_limit"),
           nes_trim_borders: Map.get(decoded, "nes_trim_borders"),
           gbc_video_filter: Map.get(decoded, "gbc_video_filter"),
           integer_scaling: Map.get(decoded, "integer_scaling"),
           audio: Map.get(decoded, "audio"),
           volume: Map.get(decoded, "volume")
         },
         {:ok, settings} <- normalize(settings, defaults()) do
      {:ok, settings}
    end
  end

  defp decode_json(json) do
    {:ok, :json.decode(json)}
  rescue
    _error -> {:error, :invalid_json}
  catch
    _kind, _reason -> {:error, :invalid_json}
  end

  defp encode(settings) do
    json = %{
      "version" => @version,
      "save_state_folder" => settings.save_state_folder,
      "nes_video_filter" => Atom.to_string(settings.nes_video_filter),
      "nes_lighting" => settings.nes_lighting,
      "nes_remove_sprite_limit" => settings.nes_remove_sprite_limit,
      "nes_trim_borders" => settings.nes_trim_borders,
      "gbc_video_filter" => Atom.to_string(settings.gbc_video_filter),
      "integer_scaling" => settings.integer_scaling,
      "audio" => settings.audio,
      "volume" => settings.volume
    }

    {:ok, json |> :json.encode() |> IO.iodata_to_binary()}
  rescue
    error -> {:error, {:encode_failed, error}}
  end

  defp normalize(settings, fallbacks \\ nil) do
    with {:ok, save_state_folder} <-
           setting(settings, :save_state_folder, fallbacks, &normalize_folder/1),
         {:ok, nes_video_filter} <-
           setting(settings, :nes_video_filter, fallbacks, &normalize_nes_filter/1),
         {:ok, nes_lighting} <-
           setting(settings, :nes_lighting, fallbacks, &normalize_boolean/1),
         {:ok, nes_remove_sprite_limit} <-
           setting(settings, :nes_remove_sprite_limit, fallbacks, &normalize_boolean/1),
         {:ok, nes_trim_borders} <-
           setting(settings, :nes_trim_borders, fallbacks, &normalize_boolean/1),
         {:ok, gbc_video_filter} <-
           setting(settings, :gbc_video_filter, fallbacks, &normalize_gbc_filter/1),
         {:ok, integer_scaling} <-
           setting(settings, :integer_scaling, fallbacks, &normalize_boolean/1),
         {:ok, audio} <- setting(settings, :audio, fallbacks, &normalize_boolean/1),
         {:ok, volume} <- setting(settings, :volume, fallbacks, &normalize_volume/1) do
      {:ok,
       %{
         save_state_folder: save_state_folder,
         nes_video_filter: nes_video_filter,
         nes_lighting: nes_lighting,
         nes_remove_sprite_limit: nes_remove_sprite_limit,
         nes_trim_borders: nes_trim_borders,
         gbc_video_filter: gbc_video_filter,
         integer_scaling: integer_scaling,
         audio: audio,
         volume: volume
       }}
    end
  end

  defp setting(settings, key, fallbacks, normalize) do
    value = Map.get(settings, key)

    cond do
      not is_nil(value) -> normalize.(value)
      is_map(fallbacks) -> {:ok, Map.fetch!(fallbacks, key)}
      true -> {:error, {:invalid_setting, key}}
    end
  end

  defp normalize_folder(folder) when is_binary(folder) and byte_size(folder) > 0,
    do: {:ok, Path.expand(folder)}

  defp normalize_folder(_folder), do: {:error, {:invalid_setting, :save_state_folder}}

  defp normalize_nes_filter(filter) when filter in @nes_video_filters, do: {:ok, filter}

  defp normalize_nes_filter(filter) when is_binary(filter) do
    normalize_enum(filter, @nes_video_filters, :nes_video_filter)
  end

  defp normalize_nes_filter(_filter), do: {:error, {:invalid_setting, :nes_video_filter}}

  defp normalize_gbc_filter(filter) when filter in @gbc_video_filters, do: {:ok, filter}

  defp normalize_gbc_filter(filter) when is_binary(filter) do
    normalize_enum(filter, @gbc_video_filters, :gbc_video_filter)
  end

  defp normalize_gbc_filter(_filter), do: {:error, {:invalid_setting, :gbc_video_filter}}

  defp normalize_boolean(value) when is_boolean(value), do: {:ok, value}
  defp normalize_boolean(_value), do: {:error, :invalid_boolean}

  defp normalize_volume(value) when is_integer(value) and value in 0..100, do: {:ok, value}
  defp normalize_volume(_value), do: {:error, {:invalid_setting, :volume}}

  defp normalize_enum(value, choices, key) do
    case Enum.find(choices, &(Atom.to_string(&1) == value)) do
      nil -> {:error, {:invalid_setting, key}}
      choice -> {:ok, choice}
    end
  end

  defp next(choices, current) do
    index = Enum.find_index(choices, &(&1 == current)) || -1
    Enum.at(choices, Integer.mod(index + 1, length(choices)))
  end

  defp filter_option(:none), do: nil
  defp filter_option(filter), do: filter

  defp write_atomic(path, contents) do
    temporary = "#{path}.tmp-#{System.unique_integer([:positive])}"

    case File.write(temporary, contents) do
      :ok ->
        case File.rename(temporary, path) do
          :ok ->
            :ok

          {:error, reason} ->
            File.rm(temporary)
            {:error, {:rename_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:write_failed, reason}}
    end
  end

  defp config_home, do: xdg_home("XDG_CONFIG_HOME", ".config")
  defp data_home, do: xdg_home("XDG_DATA_HOME", Path.join(".local", "share"))

  defp xdg_home(variable, fallback) do
    case System.get_env(variable) do
      value when is_binary(value) and value != "" ->
        if Path.type(value) == :absolute,
          do: value,
          else: Path.join(System.user_home!(), fallback)

      _missing ->
        Path.join(System.user_home!(), fallback)
    end
  end
end
