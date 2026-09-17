defmodule Beamicom.SNES.ShareImage do
  @moduledoc """
  Self-contained SNES save-state screenshots.

  The compressed, ROM-stripped machine state is visible in the dot-code border;
  the compressed immutable ROM follows PNG IEND for exact file transfer. If a
  service strips that trailer, callers may provide ROM search paths.
  """

  alias Beamicom.SNES.{Cartridge, Machine, PNG, SaveState, VisualCode}

  @trailer_magic "BMIC\0SNSV"

  @doc "Classifies a PNG by its SNES border or trailer marker."
  def classify(png) when is_binary(png) do
    with {:ok, {width, height, rgb}} <- decode_png(png) do
      case PNG.trailing_data(png) do
        {:ok, <<@trailer_magic, _framing::binary>>} -> :snes
        {:ok, _none_or_foreign_trailer} -> VisualCode.classify(rgb, width, height)
        {:error, :invalid_png} -> {:error, :invalid_png}
      end
    end
  end

  @doc "Builds a bordered save-state PNG from a machine and native 256×224 RGB frame."
  def to_png(%Machine{} = machine, frame) when is_binary(frame) do
    {state, rom} = SaveState.split(machine)
    {width, height, bordered} = VisualCode.encode(state, frame)
    PNG.encode_rgb(width, height, bordered) |> put_trailer(rom)
  end

  @doc "Loads an SNES share PNG, optionally finding a stripped ROM by identity."
  def load_image(png, rom_search_dirs \\ []) when is_binary(png) and is_list(rom_search_dirs) do
    with {:ok, {width, height, rgb}} <- decode_png(png),
         {:ok, state} <- VisualCode.decode(rgb, width, height),
         {:ok, rom} <- find_rom(png, state, rom_search_dirs) do
      SaveState.merge(state, rom)
    end
  end

  @doc "Appends the compressed-ROM trailer used by SNES share images."
  def put_trailer(png, blob) when is_binary(png) and is_binary(blob),
    do: png <> @trailer_magic <> <<byte_size(blob)::32>> <> blob

  @doc "Extracts an SNES ROM trailer."
  def get_trailer(png) when is_binary(png) do
    case PNG.trailing_data(png) do
      {:ok, <<>>} -> {:error, :no_trailer}
      {:ok, <<@trailer_magic, size::32, blob::binary-size(size)>>} -> {:ok, blob}
      {:ok, _trailing_data} -> {:error, :corrupt_trailer}
      {:error, :invalid_png} -> {:error, :corrupt_trailer}
    end
  end

  defp decode_png(png) do
    try do
      {:ok, PNG.decode_rgb(png)}
    rescue
      _error -> {:error, :invalid_png}
    end
  end

  defp find_rom(png, state, dirs) do
    case get_trailer(png) do
      {:ok, blob} -> {:ok, blob}
      {:error, :no_trailer} -> find_rom_in_dirs(state, dirs)
      {:error, _reason} = error -> error
    end
  end

  defp find_rom_in_dirs(state, dirs) do
    with {:ok, %{rom: identity}} <- SaveState.metadata(state) do
      find_matching_rom(dirs, identity)
    end
  end

  defp find_matching_rom([], _identity), do: {:error, :rom_unavailable}

  defp find_matching_rom([dir | dirs], identity) do
    match =
      ["**/*.sfc", "**/*.smc", "**/*.SFC", "**/*.SMC"]
      |> Enum.flat_map(&(dir |> Path.join(&1) |> Path.wildcard()))
      |> Enum.find_value(fn path ->
        with {:ok, media} <- File.read(path),
             {:ok, cartridge} <- Cartridge.load(media),
             true <- SaveState.rom_identity(cartridge.rom) == identity do
          :zlib.compress(cartridge.rom)
        else
          _other -> nil
        end
      end)

    if match, do: {:ok, match}, else: find_matching_rom(dirs, identity)
  end
end
