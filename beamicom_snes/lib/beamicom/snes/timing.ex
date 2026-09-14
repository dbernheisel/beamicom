defmodule Beamicom.SNES.Timing do
  @moduledoc """
  SNES master-clock and beam-position state.

  CPU work advances this clock in master clocks, allowing access speed to vary
  independently for every bus cycle. PPU rendering, refresh, DMA, and HDMA can
  subsequently share this boundary without converting through a fictional
  fixed CPU frequency.
  """

  @enforce_keys [:region]
  defstruct region: :ntsc,
            hclock: 0,
            vline: 0,
            field: 0,
            frame: 0,
            interlace?: false,
            overscan?: false,
            master_clocks: 0

  @type region :: :ntsc | :pal
  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    region = Keyword.get(opts, :region, :ntsc)

    unless region in [:ntsc, :pal], do: raise(ArgumentError, "region must be :ntsc or :pal")

    %__MODULE__{
      region: region,
      interlace?: Keyword.get(opts, :interlace, false),
      overscan?: Keyword.get(opts, :overscan, false)
    }
  end

  @spec master_clock_hz(region()) :: float()
  def master_clock_hz(:ntsc), do: 945_000_000 / 44
  def master_clock_hz(:pal), do: 21_281_370.0

  @spec vblank?(t()) :: boolean()
  def vblank?(%__MODULE__{vline: 0}), do: false
  def vblank?(%__MODULE__{overscan?: true, vline: line}), do: line >= 240
  def vblank?(%__MODULE__{vline: line}), do: line >= 225

  @spec line_clocks(t()) :: pos_integer()
  def line_clocks(%__MODULE__{region: :ntsc, interlace?: false, field: 1, vline: 240}),
    do: 1360

  def line_clocks(%__MODULE__{region: :pal, interlace?: true, field: 1, vline: 311}),
    do: 1368

  def line_clocks(%__MODULE__{}), do: 1364

  @spec advance(t(), non_neg_integer()) :: t()
  def advance(%__MODULE__{} = timing, clocks)
      when is_integer(clocks) and clocks >= 0 do
    advance_lines(%{timing | master_clocks: timing.master_clocks + clocks}, clocks)
  end

  defp advance_lines(timing, 0), do: timing

  defp advance_lines(timing, clocks) do
    remaining = line_clocks(timing) - timing.hclock

    if clocks < remaining do
      %{timing | hclock: timing.hclock + clocks}
    else
      timing
      |> next_line()
      |> advance_lines(clocks - remaining)
    end
  end

  defp next_line(timing) do
    next = timing.vline + 1

    if next >= frame_lines(timing) do
      %{timing | hclock: 0, vline: 0, field: 1 - timing.field, frame: timing.frame + 1}
    else
      %{timing | hclock: 0, vline: next}
    end
  end

  defp frame_lines(%__MODULE__{region: :ntsc, interlace?: true, field: 1}), do: 263
  defp frame_lines(%__MODULE__{region: :ntsc}), do: 262
  defp frame_lines(%__MODULE__{region: :pal, interlace?: true, field: 1}), do: 313
  defp frame_lines(%__MODULE__{region: :pal}), do: 312
end
