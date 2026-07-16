defmodule Beamicom.NES.ShareImage do
  @moduledoc "Load a save-state PNG (with or without ROM trailer) back into a Console."

  alias Beamicom.NES.{PNG, VisualCode, SaveState, Cart}

  @doc """
  Load a PNG produced by `mix nes.save`. Tries the ROM trailer first, then searches
  `rom_search_dirs` for a matching .nes by CRC.
  Returns `{:ok, %Console{}}` or `{:error, reason}`.
  """
  def load_image(png_binary, rom_search_dirs) do
    with {img_w, img_h, rgb} <- PNG.decode(png_binary),
         {:ok, state_bin} <- VisualCode.decode(rgb, img_w, img_h),
         {:ok, rom_blob} <- find_rom(png_binary, state_bin, rom_search_dirs) do
      SaveState.merge(state_bin, rom_blob)
    end
  end

  defp find_rom(png_binary, state_bin, rom_search_dirs) do
    case PNG.get_trailer(png_binary) do
      {:ok, blob} ->
        {:ok, blob}

      :none ->
        %{rom_crc: expected_crc} =
          :erlang.binary_to_term(:zlib.uncompress(state_bin), [:safe])

        find_rom_by_crc(rom_search_dirs, expected_crc)
    end
  end

  defp find_rom_by_crc([], _crc), do: {:error, :rom_unavailable}

  defp find_rom_by_crc([dir | rest], expected_crc) do
    match =
      dir
      |> Path.join("**/*.nes")
      |> Path.wildcard()
      |> Enum.find_value(fn path ->
        try do
          if SaveState.rom_crc(path) == expected_crc do
            {:ok, cart} = Cart.parse(File.read!(path))
            :zlib.compress(:erlang.term_to_binary({cart.prg_rom, cart.chr_rom}))
          end
        rescue
          _ -> nil
        end
      end)

    case match do
      nil -> find_rom_by_crc(rest, expected_crc)
      blob -> {:ok, blob}
    end
  end
end
