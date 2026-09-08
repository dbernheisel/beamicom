defmodule BeamicomStream.Core do
  @moduledoc false

  alias Beamicom.GB.System, as: GBSystem
  alias Beamicom.NES.System, as: NESSystem

  @enforce_keys [:id, :system, :runtime, :capabilities]
  defstruct @enforce_keys

  @type runtime :: :nes | :host
  @type t :: %__MODULE__{
          id: :nes | :gbc,
          system: module(),
          runtime: runtime(),
          capabilities: map()
        }

  @spec resolve(Path.t()) :: {:ok, t()} | {:error, {:unsupported_media_extension, String.t()}}
  def resolve(path) when is_binary(path),
    do: path |> Path.extname() |> String.downcase() |> resolve_ext()

  defp resolve_ext(".nes"),
    do: {:ok, config(:nes, NESSystem, :nes, NESSystem.capabilities())}

  defp resolve_ext(ext) when ext in [".gb", ".gbc"],
    do: {:ok, config(:gbc, GBSystem, :host, GBSystem.capabilities())}

  defp resolve_ext(ext), do: {:error, {:unsupported_media_extension, ext}}

  defp config(id, system, runtime, capabilities),
    do: %__MODULE__{id: id, system: system, runtime: runtime, capabilities: capabilities}
end
