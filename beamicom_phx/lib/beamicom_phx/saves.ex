defmodule BeamicomPhx.Saves do
  @moduledoc """
  On-disk gallery of save-state share PNGs. The directory is configured at
  runtime (`:beamicom_phx, :saves_dir`, default `$XDG_DATA_HOME/beamicom/saves`)
  and files are served by `BeamicomPhxWeb.SaveController` at `/saves/<file>`.

  Saves are global, matching the single shared emulator: capturing broadcasts on
  the `"saves"` PubSub topic so every connected `WatchLive` refreshes its grid.
  """

  alias Beamicom.GB.Machine
  alias Beamicom.GB.ShareImage, as: GBShareImage
  alias Beamicom.NES.Console
  alias Beamicom.NES.ShareImage, as: NESShareImage

  @topic "saves"

  @doc "Directory holding the save PNGs (configured at runtime; served at /saves/<file>)."
  def dir, do: Application.fetch_env!(:beamicom_phx, :saves_dir)

  @doc "Subscribe the caller to gallery-change notifications."
  def subscribe, do: Phoenix.PubSub.subscribe(BeamicomPhx.PubSub, @topic)

  @doc "URLs of every save, newest first."
  def list do
    case File.ls(dir()) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".png"))
        |> Enum.sort(:desc)
        |> Enum.map(&("/saves/" <> &1))

      {:error, _} ->
        []
    end
  end

  @doc """
  Snapshot the running emulator and write a new save PNG. Broadcasts on success.
  Returns `{:ok, url}` or `{:error, reason}`.
  """
  def capture do
    case BeamicomPhx.Emulator.snapshot() do
      {:ok, {_console, nil}} -> {:error, :no_frame}
      {:ok, {%Console{} = console, frame}} -> capture_nes(console, frame)
      {:ok, {%Machine{} = machine, frame}} -> capture_gb(machine, frame)
      {:error, _reason} = error -> error
    end
  end

  @doc "Load a save (by URL or basename) into the running emulator."
  def load(url) do
    path = Path.join(dir(), Path.basename(url))

    with {:ok, png} <- File.read(path),
         {:ok, saved} <- decode(png) do
      case saved do
        %Console{} = console -> BeamicomPhx.Emulator.load_console(console)
        %Machine{} = machine -> BeamicomPhx.Emulator.load_machine(machine)
      end
    end
  end

  defp decode(png) do
    case GBShareImage.classify(png) do
      :gb -> GBShareImage.load_image(png, [])
      :not_gb -> safe_load_nes(png)
      {:error, _reason} -> {:error, :invalid_save_image}
    end
  end

  defp safe_load_nes(png) do
    try do
      NESShareImage.load_image(png, [])
    rescue
      _error -> {:error, :invalid_save_image}
    catch
      _kind, _reason -> {:error, :invalid_save_image}
    end
  end

  defp capture_nes(console, frame) do
    File.mkdir_p!(dir())
    name = save_name()
    File.write!(Path.join(dir(), name), NESShareImage.to_png(console, frame))
    Phoenix.PubSub.broadcast(BeamicomPhx.PubSub, @topic, :saves_changed)
    {:ok, "/saves/" <> name}
  end

  defp capture_gb(machine, frame) do
    File.mkdir_p!(dir())
    name = save_name()
    File.write!(Path.join(dir(), name), GBShareImage.to_png(machine, frame))
    Phoenix.PubSub.broadcast(BeamicomPhx.PubSub, @topic, :saves_changed)
    {:ok, "/saves/" <> name}
  end

  defp save_name do
    timestamp = System.system_time(:millisecond)
    unique = System.unique_integer([:positive, :monotonic])
    "save-#{timestamp}-#{unique}.png"
  end
end
