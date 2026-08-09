defmodule Mix.Tasks.Beamicom.V4l2 do
  @shortdoc "Play a ROM through the framebuffer and V4L2 with socket controls"
  @moduledoc """
  Starts a Beamicom V4L2 player and a local Unix-domain controller socket.

      mix beamicom.v4l2 ROM [--socket PATH]

  The process runs until the player stops or the command is interrupted.
  """

  use Mix.Task

  alias Beamicom.EI.{Client, Server}
  alias Beamicom.TerminalInput
  alias BeamicomV4L2.{EvdevInput, Player}

  @switches [
    socket: :string,
    framebuffer: :string,
    output: :string,
    fps: :integer,
    scale: :integer,
    speed: :float,
    input: :string,
    no_audio: :boolean,
    help: :boolean
  ]

  @impl true
  def run(argv) do
    case parse_args(argv) do
      {:ok, opts} -> run_session(opts)
      {:help, text} -> Mix.shell().info(text)
      {:error, reason} -> Mix.raise(reason)
    end
  end

  @doc false
  def parse_args(argv) do
    {opts, positional, invalid} = OptionParser.parse(argv, strict: @switches)

    cond do
      opts[:help] -> {:help, usage()}
      invalid != [] -> {:error, "invalid options: #{inspect(invalid)}\n\n#{usage()}"}
      length(positional) != 1 -> {:error, usage()}
      Keyword.get(opts, :fps, 60) <= 0 -> {:error, "--fps must be positive"}
      Keyword.get(opts, :scale, 3) not in 1..8 -> {:error, "--scale must be between 1 and 8"}
      Keyword.get(opts, :speed, 1.0) <= 0 -> {:error, "--speed must be positive"}
      true -> {:ok, build_options(hd(positional), opts)}
    end
  end

  defp build_options(rom, opts) do
    %{
      rom: Path.expand(rom),
      socket: opts |> Keyword.get(:socket, Beamicom.EI.default_path()) |> Path.expand(),
      input: opts[:input],
      player_options: [
        framebuffer: Keyword.get(opts, :framebuffer, "/dev/fb0"),
        output: Keyword.get(opts, :output, "/dev/video-beamicom"),
        fps: Keyword.get(opts, :fps, 60),
        scale: Keyword.get(opts, :scale, 3),
        speed: Keyword.get(opts, :speed, 1.0),
        audio: not Keyword.get(opts, :no_audio, false)
      ]
    }
  end

  defp run_session(opts) do
    Mix.Task.run("app.start")

    if File.regular?(opts.rom) do
      start_player(opts)
    else
      Mix.raise("ROM does not exist: #{opts.rom}")
    end
  end

  defp start_player(opts) do
    case Player.start_link([rom: opts.rom] ++ opts.player_options) do
      {:ok, player} ->
        Process.unlink(player)

        try do
          start_input(opts, player)
        after
          stop_process(player)
        end

      {:error, reason} ->
        Mix.raise("could not start V4L2 player: #{inspect(reason)}")
    end
  end

  defp start_input(opts, player) do
    case Server.start_link(
           path: opts.socket,
           on_buttons: fn port, buttons -> Player.set_buttons(player, port, buttons) end
         ) do
      {:ok, server} ->
        Process.unlink(server)

        Mix.shell().info("Playing #{opts.rom}")
        Mix.shell().info("EI controller socket: #{opts.socket}")

        try do
          run_input(opts, player, server)
        after
          stop_process(server)
        end

      {:error, reason} ->
        Mix.raise("could not start controller socket: #{inspect(reason)}")
    end
  end

  defp run_input(opts, player, server) do
    {:ok, client} = Client.start_link(path: opts.socket, name: "beamicom-v4l2-local-input")
    Process.unlink(client)
    :ok = Client.await_ready(client)
    task = self()

    Mix.shell().info("Arrows move; X=A, Z=B, Enter=Start, Space=Select, Q/Escape quits")

    try do
      case TerminalInput.with_raw_terminal(fn device ->
             case run_evdev(opts.input, device, client, task, player, server) do
               {:error, reason} when is_nil(opts.input) ->
                 Mix.shell().info(
                   "Keyboard event input unavailable (#{reason}); " <>
                     "falling back to terminal key-repeat input"
                 )

                 run_terminal(device, client, task, player, server)

               {:error, reason} ->
                 {:error, reason}

               result ->
                 result
             end
           end) do
        {:error, reason} -> Mix.raise("terminal input failed: #{inspect(reason)}")
        _ -> :ok
      end
    after
      stop_process(client)
    end
  end

  defp run_evdev(path, terminal, client, task, player, server) do
    EvdevInput.with_keyboard(path, fn device, selected ->
      Mix.shell().info("Keyboard input: #{selected} (independent press/release enabled)")
      drainer = Task.async(fn -> drain_terminal(terminal) end)

      try do
        run_reader(
          EvdevInput,
          device,
          [
            on_buttons: fn port, buttons -> Client.set_buttons(client, port, buttons) end,
            on_quit: fn -> send(task, :quit) end
          ],
          player,
          server
        )
      after
        Task.shutdown(drainer, :brutal_kill)
      end
    end)
  end

  defp run_terminal(device, client, task, player, server) do
    run_reader(
      TerminalInput,
      device,
      [
        on_buttons: fn port, buttons -> Client.set_buttons(client, port, buttons) end,
        on_quit: fn -> send(task, :quit) end
      ],
      player,
      server
    )
  end

  defp run_reader(module, device, input_options, player, server) do
    {:ok, input} = module.start_link(input_options)
    reader = Task.async(fn -> module.read(input, device) end)

    try do
      await(player, server, reader)
    after
      Task.shutdown(reader, :brutal_kill)
      stop_process(input)
    end
  end

  defp drain_terminal(device) do
    case IO.binread(device, 64) do
      bytes when is_binary(bytes) -> drain_terminal(device)
      _eof_or_error -> :ok
    end
  end

  defp await(player, input, reader) do
    player_ref = Process.monitor(player)
    input_ref = Process.monitor(input)

    receive do
      :quit ->
        :ok

      {ref, _} when ref == reader.ref ->
        :ok

      {:DOWN, ^player_ref, :process, _pid, :normal} ->
        :ok

      {:DOWN, ^player_ref, :process, _pid, reason} ->
        Mix.raise("V4L2 player stopped: #{inspect(reason)}")

      {:DOWN, ^input_ref, :process, _pid, reason} ->
        Mix.raise("controller socket stopped: #{inspect(reason)}")
    end
  end

  defp stop_process(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
    :ok
  end

  defp usage do
    """
    Usage: mix beamicom.v4l2 ROM [options]

      --socket PATH       controller Unix socket (default: beamicom-ei.sock)
      --framebuffer PATH  framebuffer device (default: /dev/fb0)
      --output PATH       V4L2 output device (default: /dev/video-beamicom)
      --fps FPS           output frame rate (default: 60)
      --scale SCALE       integer framebuffer scale, 1 through 8 (default: 3)
      --speed SPEED       emulator speed multiplier (default: 1.0)
      --input PATH        Linux keyboard event device (default: auto-detect)
      --no-audio          disable local ffplay audio
    """
  end
end
