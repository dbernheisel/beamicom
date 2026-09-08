defmodule BeamicomV4L2.Core do
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
  def resolve(path) when is_binary(path) do
    path
    |> Path.extname()
    |> String.downcase()
    |> resolve_extension()
  end

  @spec load(t(), binary(), keyword()) :: {:ok, term()} | {:error, term()}
  def load(%__MODULE__{system: system}, media, options) do
    system.load(media, options)
  rescue
    exception -> {:error, {:media_load_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:media_load_failed, {kind, reason}}}
  end

  defp resolve_extension(".nes"),
    do: {:ok, core(:nes, NESSystem, :nes)}

  defp resolve_extension(extension) when extension in [".gb", ".gbc"],
    do: {:ok, core(:gbc, GBSystem, :host)}

  defp resolve_extension(extension), do: {:error, {:unsupported_media_extension, extension}}

  defp core(id, system, runtime) do
    %__MODULE__{id: id, system: system, runtime: runtime, capabilities: system.capabilities()}
  end
end
