defmodule Beamicom.GBA.ShareImage do
  @moduledoc """
  Self-contained Game Boy Advance save-state screenshots.

  The native RGB frame remains an ordinary PNG preview. Compressed, versioned
  machine state and immutable ROM data follow PNG IEND in a framed trailer.
  """

  alias Beamicom.GBA.{Machine, PNG, SaveState}

  @trailer_magic "BMIC\0GBAV"
  @width 240
  @height 160

  @doc "Classifies a PNG by its framed GBA state trailer."
  def classify(png) when is_binary(png) do
    case PNG.trailing_data(png) do
      {:ok, <<@trailer_magic, _framing::binary>>} -> :gba
      {:ok, _none_or_foreign_trailer} -> :not_gba
      {:error, :invalid_png} -> {:error, :invalid_png}
    end
  end

  @doc "Builds a self-contained save-state PNG from a machine and native frame."
  def to_png(%Machine{} = machine, frame)
      when is_binary(frame) and byte_size(frame) == @width * @height * 3 do
    {state, rom} = SaveState.split(machine)
    PNG.encode(frame) |> put_trailer(state, rom)
  end

  @doc "Loads and validates a self-contained GBA save-state PNG."
  def load_image(png) when is_binary(png) do
    with {:ok, {@width, @height}} <- decode_preview(png),
         {:ok, {state, rom}} <- get_trailer(png) do
      SaveState.merge(state, rom)
    end
  end

  @doc "Appends the framed state and ROM trailer used by GBA share images."
  def put_trailer(png, state, rom)
      when is_binary(png) and is_binary(state) and is_binary(rom) do
    png <>
      @trailer_magic <>
      <<byte_size(state)::32, byte_size(rom)::32, state::binary, rom::binary>>
  end

  @doc "Extracts the compressed state and ROM blobs from a GBA share image."
  def get_trailer(png) when is_binary(png) do
    case PNG.trailing_data(png) do
      {:ok,
       <<@trailer_magic, state_size::32, rom_size::32, state::binary-size(state_size),
         rom::binary-size(rom_size)>>} ->
        {:ok, {state, rom}}

      {:ok, _none_or_invalid_trailer} ->
        {:error, :corrupt_trailer}

      {:error, :invalid_png} ->
        {:error, :invalid_png}
    end
  end

  defp decode_preview(png) do
    case PNG.decode_rgb(png) do
      {@width, @height, _rgb} -> {:ok, {@width, @height}}
      {_width, _height, _rgb} -> {:error, :invalid_dimensions}
    end
  rescue
    _error -> {:error, :invalid_png}
  end
end
