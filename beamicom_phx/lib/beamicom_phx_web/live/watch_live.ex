defmodule BeamicomPhxWeb.WatchLive do
  @moduledoc """
  Watch page: one WebRTC-streamed view of the server's running game. On the
  connected mount it creates a shared `Membrane.WebRTC.Signaling`, starts a
  linked A/V pipeline whose `WebRTC.Sink` uses that signaling, and attaches the
  `Live.Player` (which uses the same signaling) — so browser and Sink negotiate
  over the LiveView socket. The pipeline is linked to this process, so it is torn
  down automatically when the browser disconnects.
  """
  use BeamicomPhxWeb, :live_view

  alias BeamicomPhx.{Input, Saves}
  alias Membrane.WebRTC.Live.Player

  # The on-screen controller graphic, inlined so the Gamepad JS hook can reach its
  # elements by id (mapping in assets/js/app.js). Recompile if the SVG changes.
  @external_resource "priv/static/controller.svg"
  @controller_svg File.read!("priv/static/controller.svg")

  @impl true
  def mount(_params, _session, socket) do
    mode = Application.get_env(:beamicom_phx, :mode, :server)

    socket =
      if connected?(socket) do
        signaling = Membrane.WebRTC.Signaling.new()

        case mode do
          :client ->
            BeamicomPhx.AV.Relay.add_browser(socket.id, self(), signaling)

          _server ->
            {:ok, _supervisor, _pipeline} =
              Membrane.Pipeline.start_link(BeamicomPhx.AV.Pipeline, egress_signaling: signaling)
        end

        # Both modes watch the gallery (read-only for clients); saving/loading is
        # gated to server mode in the render and the event handlers.
        Saves.subscribe()
        Player.attach(socket, id: "videoPlayer", signaling: signaling)
      else
        socket
      end

    # `held` = controller buttons currently down (the NES controller is stateful, so
    # we resend the whole set on every change). Server mode also accepts a dropped
    # ROM to (re)load the emulator.
    socket =
      assign(socket,
        held: MapSet.new(),
        mode: mode,
        rom_name: nil,
        saves: Saves.list()
      )

    socket =
      if mode == :server do
        allow_upload(socket, :rom,
          accept: ["application/x-nes-rom", ".nes"],
          max_entries: 1,
          auto_upload: true,
          progress: &handle_rom_progress/3
        )
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="game"
      phx-hook="PreventGameKeyScroll"
      phx-window-keyup="keyup"
      class="crt-room"
    >
      <div class="crt">
        <div class="crt__cabinet">
          <div class="crt__bezel">
            <div class="crt__screen">
              <Player.live_render socket={@socket} player_id="videoPlayer" />
              <canvas
                id="crt-canvas"
                phx-hook="Crt"
                phx-update="ignore"
                class="crt__glass"
                aria-hidden="true"
              ></canvas>
            </div>
          </div>
          <div class="crt__plate">
            <div class="crt__buttons">
              <button type="button" id="crt-toggle" class="crt__btn">CRT filter: on</button>
              <button
                :if={@mode == :server}
                type="button"
                class="crt__btn"
                phx-click="save_state"
              >
                Save
              </button>
            </div>
            <div class="crt__badge">
              <span class="crt__brand">BEAMICOM</span>
              <span class="crt__led" aria-hidden="true"></span>
            </div>
          </div>
        </div>
      </div>
      <p :if={@mode == :server} class="crt__controls">
        Arrows = D-pad &nbsp;·&nbsp; X = A &nbsp;·&nbsp; Z = B &nbsp;·&nbsp; Enter = Start &nbsp;·&nbsp; Shift = Select
      </p>

      <div
        :if={@mode == :server}
        id="gamepad"
        class="gamepad"
        phx-hook="Gamepad"
        data-held={held_names(@held)}
      >
        {raw(controller_svg())}
      </div>
      <form :if={@mode == :server} phx-change="validate">
        <label class="crt__rom" phx-drop-target={@uploads.rom.ref}>
          <.live_file_input upload={@uploads.rom} class="crt__rom-input" />
          {if @rom_name,
            do: "▸ #{@rom_name} — drop a .nes to change",
            else: "Drop a .nes ROM here to load"}
        </label>
      </form>

      <div :if={@saves != []} class="save-gallery">
        <button
          :for={url <- @saves}
          type="button"
          class={["save-thumb", @mode != :server && "save-thumb--readonly"]}
          phx-click={@mode == :server && "load_save"}
          phx-value-url={url}
          title={if @mode == :server, do: "Load this save", else: "Saves (view only)"}
        >
          <img src={url} alt="save state" />
        </button>
      </div>
    </div>
    """
  end

  # A dropped/selected .nes finished uploading: copy it out of the temp dir and
  # (re)load the emulator. All viewers pick up the new game via the shared Output.
  defp handle_rom_progress(:rom, %{done?: false}, socket), do: {:noreply, socket}

  defp handle_rom_progress(:rom, entry, socket) do
    name = entry.client_name || ""
    dest = Path.join(System.tmp_dir!(), "beamicom_current_rom.nes")

    path =
      consume_uploaded_entry(socket, entry, fn %{path: tmp} ->
        File.cp!(tmp, dest)
        {:ok, dest}
      end)

    socket =
      case BeamicomPhx.Emulator.load(path) do
        :ok -> assign(socket, rom_name: name)
        {:error, _reason} -> put_flash(socket, :error, "Couldn't load #{name}")
      end

    File.rm(dest)
    {:noreply, socket}
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  # Saving and loading are server-only writes; the guards make clients read-only
  # even if they forge the event. Capturing broadcasts, so every viewer's gallery
  # refreshes via handle_info(:saves_changed, …).
  def handle_event("save_state", _params, %{assigns: %{mode: :server}} = socket) do
    case Saves.capture() do
      {:ok, _url} -> {:noreply, socket}
      {:error, _reason} -> {:noreply, put_flash(socket, :error, "Nothing to save yet")}
    end
  end

  def handle_event("load_save", %{"url" => url}, %{assigns: %{mode: :server}} = socket) do
    case Saves.load(url) do
      :ok -> {:noreply, socket}
      _ -> {:noreply, put_flash(socket, :error, "Couldn't load that save")}
    end
  end

  # Client mode is read-only: ignore any save/load attempt.
  def handle_event(event, _params, socket) when event in ~w(save_state load_save) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("keydown", %{"key" => key}, socket) do
    {:noreply, commit(socket, Input.apply_key(socket.assigns.held, :down, key))}
  end

  def handle_event("keyup", %{"key" => key}, socket) do
    {:noreply, commit(socket, Input.apply_key(socket.assigns.held, :up, key))}
  end

  # On-screen controller (pointer down/up via the Gamepad JS hook) — same path as keys.
  def handle_event("button_down", %{"button" => name}, socket) do
    {:noreply, commit(socket, button_event(socket, :down, name))}
  end

  def handle_event("button_up", %{"button" => name}, socket) do
    {:noreply, commit(socket, button_event(socket, :up, name))}
  end

  @impl true
  def handle_info(:saves_changed, socket), do: {:noreply, assign(socket, saves: Saves.list())}

  defp button_event(socket, dir, name) do
    case Input.button_from_name(name) do
      nil -> :ignore
      button -> Input.apply_button(socket.assigns.held, dir, button)
    end
  end

  # Push the held set to the emulator and re-render the controller, but only when
  # the set actually changed (browsers fire keydown repeatedly while a key is held).
  defp commit(socket, :ignore), do: socket

  defp commit(socket, {held, buttons}) do
    if MapSet.equal?(held, socket.assigns.held) do
      socket
    else
      Input.press(1, buttons)
      assign(socket, held: held)
    end
  end

  # Space-joined held button names for the controller's data-held attribute; the
  # Gamepad hook reads it and highlights the matching SVG elements.
  defp held_names(held), do: held |> Enum.map(&Atom.to_string/1) |> Enum.join(" ")

  # The inlined controller SVG (compile-time constant, kept out of assigns).
  defp controller_svg, do: @controller_svg
end
