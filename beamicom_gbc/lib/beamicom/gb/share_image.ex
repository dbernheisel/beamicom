defmodule Beamicom.GB.ShareImage do
  @moduledoc """
  Self-contained Game Boy save-state screenshots.

  The compressed, ROM-stripped machine state is visible in the dot-code border;
  the compressed immutable ROM is appended after PNG IEND for exact file
  transfer. If that trailer is stripped, callers may provide ROM search paths.
  """

  alias Beamicom.GB.{Cartridge, Machine, PNG, PPU, SaveState, VisualCode}

  @trailer_magic "BMIC\0GBSV"

  @doc "Classifies a PNG by its visible border marker without decoding save data."
  @spec classify(binary()) :: :gb | :not_gb | {:error, term()}
  def classify(png) when is_binary(png) do
    with {:ok, {width, height, rgb}} <- decode_png(png) do
      case PNG.trailing_data(png) do
        {:ok, <<@trailer_magic, _framing::binary>>} -> :gb
        {:ok, _none_or_foreign_trailer} -> VisualCode.classify(rgb, width, height)
        {:error, :invalid_png} -> {:error, :invalid_png}
      end
    end
  end

  @doc "Builds a bordered save-state PNG from a machine and native frame."
  @spec to_png(Machine.t(), binary()) :: binary()
  def to_png(%Machine{} = machine, frame) when is_binary(frame) do
    {state, rom} = SaveState.split(machine)
    rgb = PNG.to_rgb(frame, PPU.pixel_format(machine.bus.ppu), :dmg_green)
    {width, height, bordered} = VisualCode.encode(state, rgb)
    PNG.encode_rgb(width, height, bordered) |> put_trailer(rom)
  end

  @doc "Loads a Game Boy share PNG, optionally finding a stripped ROM by identity."
  @spec load_image(binary(), [Path.t()]) :: {:ok, Machine.t()} | {:error, term()}
  def load_image(png, rom_search_dirs \\ []) when is_binary(png) and is_list(rom_search_dirs) do
    with {:ok, {width, height, rgb}} <- decode_png(png),
         {:ok, state} <- VisualCode.decode(rgb, width, height),
         {:ok, rom} <- find_rom(png, state, rom_search_dirs) do
      SaveState.merge(state, rom)
    end
  end

  @doc "Appends the compressed ROM trailer used by Game Boy share images."
  @spec put_trailer(binary(), binary()) :: binary()
  def put_trailer(png, blob) when is_binary(png) and is_binary(blob),
    do: png <> @trailer_magic <> <<byte_size(blob)::32>> <> blob

  @doc "Extracts a Game Boy ROM trailer."
  @spec get_trailer(binary()) :: {:ok, binary()} | :none | {:error, :corrupt_trailer}
  def get_trailer(png) when is_binary(png) do
    case PNG.trailing_data(png) do
      {:ok, <<>>} ->
        :none

      {:ok, <<@trailer_magic, size::32, blob::binary-size(size)>>} ->
        {:ok, blob}

      {:ok, _trailing_data} ->
        {:error, :corrupt_trailer}

      {:error, :invalid_png} ->
        {:error, :corrupt_trailer}
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
      {:ok, blob} -> find_embedded_rom(blob)
      :none -> find_rom_in_dirs(state, dirs)
      {:error, _reason} = error -> error
    end
  end

  defp find_embedded_rom(blob), do: {:ok, blob}

  defp find_rom_in_dirs(state, dirs) do
    with {:ok, %{rom: identity}} <- SaveState.metadata(state) do
      find_matching_rom(dirs, identity)
    end
  end

  defp find_matching_rom([], _identity), do: {:error, :rom_unavailable}

  defp find_matching_rom([dir | dirs], identity) do
    match =
      ["**/*.gb", "**/*.gbc"]
      |> Enum.flat_map(&(dir |> Path.join(&1) |> Path.wildcard()))
      |> Enum.find_value(fn path ->
        with {:ok, rom} <- File.read(path),
             true <- SaveState.rom_identity(rom) == identity,
             {:ok, _cartridge} <- Cartridge.parse(rom) do
          :zlib.compress(rom)
        else
          _other -> nil
        end
      end)

    if match, do: {:ok, match}, else: find_matching_rom(dirs, identity)
  end
end
