defmodule Beamicom.Scenic.SaveState do
  @moduledoc false

  alias Beamicom.GB.ShareImage, as: GBShareImage
  alias Beamicom.NES.ShareImage, as: NESShareImage

  @spec rom_hash(:nes | :gbc | :snes, struct()) :: String.t()
  def rom_hash(:nes, %{bus: %{prg: prg, ppu: %{chr: chr}}})
      when is_binary(prg) and is_binary(chr),
      do: digest(prg <> chr)

  def rom_hash(:gbc, %{bus: %{cartridge: %{rom: rom}}}) when is_binary(rom),
    do: digest(rom)

  def rom_hash(:snes, %{machine: %{cartridge: %{rom: rom}}}) when is_binary(rom),
    do: digest(rom)

  @spec quick_path(Path.t(), String.t()) :: Path.t()
  def quick_path(folder, rom_hash) when is_binary(folder) and is_binary(rom_hash),
    do: Path.join(folder, rom_hash <> ".png")

  @spec list(Path.t(), String.t()) :: [Path.t()]
  def list(folder, rom_hash) when is_binary(folder) and is_binary(rom_hash) do
    case File.ls(folder) do
      {:ok, names} ->
        names
        |> Enum.filter(&state_name?(&1, rom_hash))
        |> Enum.map(&Path.join(folder, &1))
        |> Enum.filter(&File.regular?/1)
        |> Enum.sort_by(&modified_at/1, :desc)

      {:error, _reason} ->
        []
    end
  end

  @spec label(Path.t(), String.t()) :: String.t()
  def label(path, rom_hash) do
    name = Path.basename(path)
    prefix = rom_hash <> "-"

    cond do
      name == rom_hash <> ".png" ->
        "Quick state"

      String.starts_with?(name, prefix) ->
        name |> String.replace_prefix(prefix, "") |> Path.rootname() |> String.replace("-", " ")

      true ->
        Path.rootname(name)
    end
  end

  def write({:nes, console, framebuffer}, path) when is_binary(path),
    do: write_file(path, fn -> NESShareImage.to_png(console, framebuffer) end)

  def write({:gbc, machine, frame}, path) when is_binary(path),
    do: write_file(path, fn -> GBShareImage.to_png(machine, frame) end)

  defp write_file(path, encode) do
    case File.write(path, encode.()) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp digest(rom) do
    :sha256
    |> :crypto.hash(rom)
    |> Base.encode16(case: :lower)
  end

  defp state_name?(name, rom_hash),
    do: name == rom_hash <> ".png" or String.starts_with?(name, rom_hash <> "-")

  defp modified_at(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> stat.mtime
      {:error, _reason} -> 0
    end
  end
end
