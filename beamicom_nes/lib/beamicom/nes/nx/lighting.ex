if Code.ensure_loaded?(Nx.Defn) do
  defmodule Beamicom.NES.Nx.Lighting do
    @moduledoc """
    Verified, ROM-specific lighting profiles for the Nx NES renderers.

    Profiles are selected by the SHA-256 digest of parsed PRG plus CHR data, so
    iNES headers and trainers do not affect identity. A profile describes exact
    sprite tile identities and pattern-color slots; visual brightness alone never
    turns a pixel into a light source.
    """

    alias Beamicom.NES.Cart

    @zelda_hash "085e5397a3487357c263dfa159fb0fe20a5f3ea8ef82d7af6a7e848d3b9364e8"

    @zelda [
      radius: 8,
      sigma: 4.0,
      strength: 1.25,
      emitters: [
        [
          id: :flame,
          layer: :sprite,
          tile_space: :ppu,
          tiles: [92, 93, 94, 95],
          subpalettes: [2],
          color_slots: [1, 2, 3],
          intensity: 1.0,
          flicker: :organic
        ],
        [
          id: :sword_and_beam,
          layer: :sprite,
          tile_space: :ppu,
          tiles: [130, 131, 132, 133],
          subpalettes: [0, 1, 2, 3],
          color_slots: [3],
          intensity: 1.0
        ],
        [
          id: :sword_beam_particles,
          layer: :sprite,
          tile_space: :ppu,
          tiles: [48, 49],
          subpalettes: [0, 1, 2, 3],
          color_slots: [3],
          intensity: 1.0
        ],
        [
          id: :rupee,
          layer: :sprite,
          tile_space: :ppu,
          tiles: [50, 51],
          subpalettes: [1, 2],
          color_slots: [2, 3],
          intensity: 0.6
        ],
        [
          id: :enemy_fireball,
          layer: :sprite,
          tile_space: :ppu,
          tiles: [68, 69],
          subpalettes: [0, 1, 2, 3],
          color_slots: [2, 3],
          intensity: 1.0
        ],
        [
          id: :enemy_death,
          layer: :sprite,
          tile_space: :ppu,
          tiles: [98, 100],
          subpalettes: [0, 1, 2, 3],
          color_slots: [1, 2, 3],
          intensity: 1.0
        ],
        [
          id: :heart_pickup,
          layer: :sprite,
          tile_space: :ppu,
          tiles: [498, 499],
          subpalettes: [1, 2],
          color_slots: [1],
          intensity: 1.0
        ]
      ]
    ]

    @doc "SHA-256 of parsed PRG plus CHR data for the verified Zelda ROM."
    def zelda_hash, do: @zelda_hash

    @doc "The verified Zelda emissive-sprite profile."
    def zelda, do: @zelda

    @doc "Return the verified lighting profile for an iNES ROM binary."
    @spec for_rom(binary()) :: {:ok, keyword()} | :error
    def for_rom(media) when is_binary(media) do
      with {:ok, cart} <- Cart.parse(media) do
        case content_hash(cart) do
          @zelda_hash -> {:ok, @zelda}
          _hash -> :error
        end
      else
        _error -> :error
      end
    end

    @doc "Return the verified lighting profile for a parsed-content SHA-256 digest."
    @spec for_hash(String.t()) :: {:ok, keyword()} | :error
    def for_hash(@zelda_hash), do: {:ok, @zelda}
    def for_hash(_hash), do: :error

    @doc "Return the parsed-content SHA-256 digest used for profile selection."
    @spec content_hash(Cart.t() | binary()) :: String.t()
    def content_hash(media) when is_binary(media) do
      {:ok, cart} = Cart.parse(media)
      content_hash(cart)
    end

    def content_hash(%Cart{prg_rom: prg, chr_rom: chr}) do
      :sha256
      |> :crypto.hash(prg <> chr)
      |> Base.encode16(case: :lower)
    end
  end
end
