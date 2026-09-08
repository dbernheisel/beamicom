defmodule BeamicomPhxWeb.WatchLive do
  @moduledoc """
  Watch page: one WebRTC-streamed view of the server's running game. On the
  connected mount it creates a shared `Membrane.WebRTC.Signaling`, starts an
  A/V pipeline whose `WebRTC.Sink` uses that signaling, and attaches the
  `Live.Player` (which uses the same signaling). The pipeline monitors this
  LiveView and is also terminated explicitly during orderly disconnects.
  """
  use BeamicomPhxWeb, :live_view

  alias BeamicomPhx.{Emulator, Input, Saves}
  alias BeamicomStream.Core
  alias Membrane.WebRTC.Live.Player

  # The on-screen controller graphic, inlined so the Gamepad JS hook can reach its
  # elements by id (mapping in assets/js/app.js). Recompile if the SVG changes.
  @external_resource "priv/static/controller.svg"
  @controller_svg File.read!("priv/static/controller.svg")

  @impl true
  def mount(_params, _session, socket) do
    mode = Application.get_env(:beamicom_phx, :mode, :server)

    profile =
      if mode == :server and not connected?(socket),
        do: Emulator.profile(),
        else: nil

    # `held` = controller buttons currently down (the NES controller is stateful, so
    # we resend the whole set on every change). Server mode also accepts a dropped
    # ROM to (re)load the emulator.
    socket =
      assign(socket,
        held: MapSet.new(),
        keyboard_held: MapSet.new(),
        pointer_held: MapSet.new(),
        gamepad_held: MapSet.new(),
        mode: mode,
        signaling: nil,
        av_pipeline: nil,
        av_profile: profile,
        system: profile_system(profile),
        controller_url:
          if(mode == :client,
            do: Application.get_env(:beamicom_phx, :controller_url),
            else: nil
          ),
        player_notification: nil,
        player_notification_token: nil,
        rom_name: profile_name(profile),
        saves: Saves.list()
      )

    socket = if connected?(socket), do: connect_player(socket), else: socket

    socket =
      if mode == :server do
        allow_upload(socket, :rom,
          accept: [".nes", ".gb", ".gbc"],
          max_file_size: 16_000_000,
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
    <Layouts.app flash={@flash}>
      <div
        id="game"
        phx-hook="PreventGameKeyScroll"
        phx-window-keyup="keyup"
        data-controller-url={@controller_url}
        class="crt-room"
      >
        <div
          id="player-notification-slot"
          class="player-notification-slot"
          phx-update={if(@mode == :client, do: "ignore", else: nil)}
        >
          <div
            id="player-notification"
            class={[
              "player-notification",
              @mode == :server && @player_notification && "is-visible"
            ]}
            role="status"
            aria-live="polite"
            aria-atomic="true"
          >
            <span class="player-notification__badge" aria-hidden="true">P2</span>
            <span id="player-status">
              {if(@mode == :client,
                do: "Joining the Player 2 queue…",
                else: @player_notification || ""
              )}
            </span>
          </div>
        </div>
        <div class="crt" data-system={@system}>
          <div class="crt__cabinet">
            <div class="crt__bezel">
              <div class="crt__screen">
                <Player.live_render socket={@socket} player_id="videoPlayer" />
                <canvas
                  id="crt-canvas"
                  phx-hook="Crt"
                  phx-update="ignore"
                  class="crt__glass"
                  data-video-width={video_dimension(@av_profile, :width)}
                  data-video-height={video_dimension(@av_profile, :height)}
                  aria-hidden="true"
                ></canvas>
              </div>
            </div>
            <div class="crt__plate">
              <div class="crt__buttons">
                <button
                  type="button"
                  id="crt-toggle"
                  class="crt__btn crt__filter-toggle"
                  aria-label="Toggle CRT filter"
                  aria-pressed="true"
                  title="Toggle CRT filter"
                >
                  <span>CRT filter</span>
                  <span class="crt__filter-led" aria-hidden="true"></span>
                </button>
                <button
                  :if={@mode == :server}
                  type="button"
                  id="save-state"
                  class="crt__btn"
                  phx-click="save_state"
                  title="Save state"
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
        <p class="crt__controls">
          Arrows = D-pad &nbsp;·&nbsp; X = A &nbsp;·&nbsp; Z = B &nbsp;·&nbsp; Enter = Start &nbsp;·&nbsp; Shift = Select
        </p>
        <div
          id="gamepad"
          class="gamepad"
          phx-hook="Gamepad"
          data-held={held_names(@held)}
        >
          {raw(controller_svg())}
        </div>
        <form :if={@mode == :server} id="rom-upload" phx-change="validate">
          <label id="rom-drop-label" class="crt__rom" phx-drop-target={@uploads.rom.ref}>
            <.live_file_input upload={@uploads.rom} class="crt__rom-input" />
            {if @rom_name,
              do: "▸ #{@rom_name} — drop a .nes, .gb, or .gbc to change",
              else: "Drop a .nes, .gb, or .gbc ROM here to load"}
          </label>
        </form>

        <div :if={@saves != []} class="save-gallery">
          <button
            :for={url <- @saves}
            type="button"
            id={"load-" <> Path.basename(url, ".png")}
            class={["save-thumb", @mode != :server && "save-thumb--readonly"]}
            phx-click={@mode == :server && "load_save"}
            phx-value-url={url}
            title={save_title(@mode)}
          >
            <img src={url} alt="save state" />
          </button>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # Load synchronously while Phoenix still owns its private upload path. The
  # display name selects the core, so no predictable shared-temporary staging
  # path is needed.
  defp handle_rom_progress(:rom, %{done?: false}, socket), do: {:noreply, socket}

  defp handle_rom_progress(:rom, entry, socket) do
    name = Path.basename(entry.client_name || "")

    case Core.resolve(name) do
      {:ok, _core} ->
        load_uploaded_rom(socket, entry, name)

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Unsupported ROM type")}
    end
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  # Saving and loading are server-only writes; the guards make clients read-only
  # even if they forge the event. Capturing broadcasts, so every viewer's gallery
  # refreshes via handle_info(:saves_changed, …).
  def handle_event("save_state", _params, %{assigns: %{mode: :server}} = socket) do
    case Saves.capture() do
      {:ok, _url} ->
        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Nothing to save yet")}
    end
  end

  def handle_event("load_save", %{"url" => url}, %{assigns: %{mode: :server}} = socket) do
    case Saves.load(url) do
      :ok ->
        {:noreply, socket}

      _ ->
        {:noreply, put_flash(socket, :error, "Couldn't load that save")}
    end
  end

  # Client mode is read-only: ignore any save/load attempt.
  def handle_event(event, _params, socket) when event in ~w(save_state load_save) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("keydown", %{"key" => key}, socket) do
    {:noreply,
     commit_source(
       socket,
       :keyboard_held,
       Input.apply_key(socket.assigns.keyboard_held, :down, key)
     )}
  end

  def handle_event("keyup", %{"key" => key}, socket) do
    {:noreply,
     commit_source(
       socket,
       :keyboard_held,
       Input.apply_key(socket.assigns.keyboard_held, :up, key)
     )}
  end

  # On-screen controller (pointer down/up via the Gamepad JS hook) — same path as keys.
  def handle_event("button_down", %{"button" => name}, socket) do
    {:noreply, commit_source(socket, :pointer_held, button_event(socket, :down, name))}
  end

  def handle_event("button_up", %{"button" => name}, socket) do
    {:noreply, commit_source(socket, :pointer_held, button_event(socket, :up, name))}
  end

  def handle_event("gamepad_buttons", %{"buttons" => names}, socket) do
    case Input.buttons_from_names(names) do
      {:ok, held} ->
        {:noreply, commit_source(socket, :gamepad_held, {held, MapSet.to_list(held)})}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:saves_changed, socket), do: {:noreply, assign(socket, saves: Saves.list())}

  def handle_info(
        {:emulator_profile, %{system: system} = profile},
        %{assigns: %{mode: :server, system: system}} = socket
      ),
      do: {:noreply, assign(socket, rom_name: profile_name(profile))}

  def handle_info(
        {:emulator_profile, _profile},
        %{assigns: %{mode: :server}} = socket
      ) do
    # A WebRTC Player's signaling handshake is one-shot. Remount the entire
    # LiveView on a format-family transition so both the Player and its sink get
    # a fresh signaling object; changing assigns under the same child id does not.
    epoch = System.unique_integer([:positive, :monotonic])
    {:noreply, push_navigate(socket, to: ~p"/?stream_epoch=#{epoch}")}
  end

  def handle_info({:emulator_loaded, profile}, socket) do
    {:noreply, assign(socket, rom_name: profile_name(profile))}
  end

  def handle_info({:player_notification, message}, socket) do
    token = make_ref()
    Process.send_after(self(), {:hide_player_notification, token}, 4_000)

    socket =
      socket
      |> assign(
        player_notification: message,
        player_notification_token: token
      )
      |> push_event("player_notification_sound", %{})

    {:noreply, socket}
  end

  def handle_info(
        {:hide_player_notification, token},
        %{assigns: %{player_notification_token: token}} = socket
      ) do
    {:noreply, assign(socket, player_notification: nil, player_notification_token: nil)}
  end

  def handle_info({:hide_player_notification, _stale_token}, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    stop_browser_pipeline(socket.assigns[:av_pipeline])
    :ok
  end

  defp button_event(socket, dir, name) do
    case Input.button_from_name(name) do
      nil -> :ignore
      button -> Input.apply_button(socket.assigns.pointer_held, dir, button)
    end
  end

  # Keep each browser input source independent, then send their union. Releasing
  # a gamepad button must not cancel the same button held on the keyboard/touch UI.
  defp commit_source(socket, _source, :ignore), do: socket

  defp commit_source(socket, source, {source_held, _buttons}) do
    socket = assign(socket, source, source_held)

    held =
      socket.assigns.keyboard_held
      |> MapSet.union(socket.assigns.pointer_held)
      |> MapSet.union(socket.assigns.gamepad_held)

    unless MapSet.equal?(held, socket.assigns.held), do: Input.press(1, MapSet.to_list(held))
    assign(socket, held: held)
  end

  # Space-joined held button names for the controller's data-held attribute; the
  # Gamepad hook reads it and highlights the matching SVG elements.
  defp held_names(held), do: held |> Enum.map(&Atom.to_string/1) |> Enum.join(" ")

  # The inlined controller SVG (compile-time constant, kept out of assigns).
  defp controller_svg, do: @controller_svg

  defp connect_player(%{assigns: %{mode: :client}} = socket) do
    signaling = Membrane.WebRTC.Signaling.new()
    BeamicomPhx.AV.Relay.add_browser(socket.id, self(), signaling)
    Saves.subscribe()

    socket
    |> assign(signaling: signaling)
    |> Player.attach(id: "videoPlayer", signaling: signaling)
  end

  defp connect_player(%{assigns: %{mode: :server}} = socket) do
    Emulator.subscribe()
    profile = Emulator.profile()
    signaling = Membrane.WebRTC.Signaling.new()
    Saves.subscribe()
    BeamicomPhx.PlayerQueue.subscribe()

    socket =
      case start_browser_pipeline(profile, signaling) do
        {:ok, pipeline} ->
          assign(socket,
            av_pipeline: pipeline,
            av_profile: profile,
            system: profile_system(profile),
            rom_name: profile_name(profile)
          )

        {:error, reason} ->
          put_flash(socket, :error, "Couldn't start video: #{inspect(reason)}")
      end

    socket
    |> assign(signaling: signaling)
    |> Player.attach(id: "videoPlayer", signaling: signaling)
  end

  defp start_browser_pipeline(nil, _signaling), do: {:ok, nil}

  defp start_browser_pipeline(profile, signaling) do
    case Membrane.Pipeline.start_link(BeamicomPhx.AV.Pipeline,
           egress_signaling: signaling,
           profile: profile,
           owner: self()
         ) do
      {:ok, supervisor, pipeline} ->
        Process.unlink(supervisor)
        {:ok, pipeline}

      {:error, _reason} = error ->
        error
    end
  end

  defp stop_browser_pipeline(nil), do: :ok

  defp stop_browser_pipeline(pipeline) do
    try do
      Membrane.Pipeline.terminate(pipeline)
    catch
      :exit, _reason -> :ok
    end
  end

  defp profile_system(nil), do: nil
  defp profile_system(profile), do: profile.system
  defp profile_name(nil), do: nil
  defp profile_name(profile), do: profile.rom_name

  defp video_dimension(nil, :width), do: 256
  defp video_dimension(nil, :height), do: 240
  defp video_dimension(profile, dimension), do: Map.fetch!(profile.video, dimension)

  defp save_title(:server), do: "Load this save"
  defp save_title(_mode), do: "Saves (view only)"

  defp load_uploaded_rom(socket, entry, name) do
    live_view = socket.root_pid

    result =
      consume_uploaded_entry(socket, entry, fn %{path: path} ->
        {:ok, Emulator.load(path, rom_name: name, notify_from: live_view)}
      end)

    socket =
      case result do
        {:ok, :ok} -> finish_uploaded_load(socket, name)
        :ok -> finish_uploaded_load(socket, name)
        {:ok, {:error, _reason}} -> put_flash(socket, :error, "Couldn't load #{name}")
        {:error, _reason} -> put_flash(socket, :error, "Couldn't load #{name}")
      end

    {:noreply, socket}
  end

  defp finish_uploaded_load(socket, name) do
    profile = Emulator.profile()

    if profile_system(profile) == socket.assigns.system do
      assign(socket, rom_name: name)
    else
      epoch = System.unique_integer([:positive, :monotonic])

      socket
      |> assign(rom_name: name, system: profile_system(profile))
      |> redirect(to: ~p"/?stream_epoch=#{epoch}")
    end
  end
end
