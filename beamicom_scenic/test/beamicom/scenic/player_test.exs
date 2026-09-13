defmodule Beamicom.Scenic.PlayerTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias Beamicom.Scenic.Player

  setup do
    original_viewport = Application.fetch_env!(:beamicom_scenic, :viewport)
    Application.put_env(:beamicom_scenic, :viewport, Keyword.put(original_viewport, :drivers, []))

    path =
      Path.join(System.tmp_dir!(), "beamicom-scenic-#{System.unique_integer([:positive])}.gbc")

    File.write!(path, rom())

    on_exit(fn ->
      Beamicom.Scenic.stop()
      Application.put_env(:beamicom_scenic, :viewport, original_viewport)
      File.rm(path)
    end)

    {:ok, path: path}
  end

  test "rejects a repeat launch before creating children and owns shutdown", %{path: path} do
    assert :ok = Beamicom.Scenic.play(path, audio: false, speed: 0.01)
    assert %{system: :gbc, video: %{width: 160, height: 144}} = Beamicom.Scenic.status()

    player = Process.whereis(Player)
    state = :sys.get_state(player)
    children = child_pids(state)
    assert length(children) == 5
    assert Enum.all?(children, &Process.alive?/1)
    assert :sys.get_state(state.input_server).ports == [1]
    assert :sys.get_state(state.input_client).ports == [1]
    assert Process.whereis(Beamicom.Scenic.EIServer) == state.input_server
    assert Process.whereis(Beamicom.Scenic.EIClient) == state.input_client

    assert :ok = Beamicom.EI.Client.set_buttons(state.input_client, 1, [:a])
    assert await_buttons(state.runtime, 0x10)
    assert {:error, :not_ready} = Beamicom.EI.Client.set_buttons(state.input_client, 2, [:a])

    links_before = links(player)

    assert_raise ArgumentError, "Beamicom Scenic is already running", fn ->
      Beamicom.Scenic.play(path, audio: false, speed: 0.01)
    end

    assert Process.whereis(Player) == player
    assert links(player) == links_before
    assert child_pids(:sys.get_state(player)) == children

    monitors = Enum.map(children, &Process.monitor/1)
    assert :ok = Beamicom.Scenic.stop()
    assert Process.whereis(Player) == nil

    for {child, monitor} <- Enum.zip(children, monitors) do
      assert_receive {:DOWN, ^monitor, :process, ^child, _reason}, 1_000
      refute Process.alive?(child)
    end

    assert {:error, :not_running} = Beamicom.Scenic.status()
  end

  test "legacy play facade routes NES and owns its lifecycle" do
    path =
      Path.join(System.tmp_dir!(), "beamicom-scenic-#{System.unique_integer([:positive])}.nes")

    File.write!(path, minimal_nes_rom())
    on_exit(fn -> File.rm(path) end)

    assert :ok = Beamicom.NES.Scenic.play(path, audio: false, speed: 0.01)

    assert %{
             system: :nes,
             video: %{width: 256, height: 240, scaled_width: 768, scaled_height: 720}
           } = Beamicom.Scenic.status()

    state = Player |> Process.whereis() |> :sys.get_state()
    assert Process.whereis(Beamicom.Scenic.EIServer) == state.input_server
    assert Process.whereis(Beamicom.Scenic.EIClient) == state.input_client
    assert :sys.get_state(state.runtime).audio_slices == 1
    assert :ok = Beamicom.Scenic.stop()
    assert eventually(fn -> is_nil(Process.whereis(Player)) end)

    assert :ok =
             Beamicom.NES.Scenic.play(path,
               audio: false,
               speed: 0.01,
               video_filter: :svideo
             )

    assert %{
             scale: 1,
             video_filter: :svideo,
             video: %{width: 602, height: 240, scaled_width: 602, scaled_height: 480}
           } = Beamicom.Scenic.status()
  end

  test "an initialization failure rolls back anonymous output and runtime children", %{path: path} do
    socket =
      Path.join(
        System.tmp_dir!(),
        "beamicom-scenic-conflict-#{System.unique_integer([:positive])}.sock"
      )

    on_exit(fn -> File.rm(socket) end)

    start_supervised!(
      {Beamicom.EI.Server,
       name: Beamicom.Scenic.EIServer, path: socket, ports: [1], on_buttons: fn _, _ -> :ok end}
    )

    outputs_before = processes_started_by(Beamicom.Host.Output)
    runtimes_before = processes_started_by(Beamicom.Host.Runtime)

    assert_raise ArgumentError, fn ->
      Beamicom.Scenic.play(path, audio: false, speed: 0.01)
    end

    assert Process.whereis(Player) == nil
    assert eventually(fn -> processes_started_by(Beamicom.Host.Output) == outputs_before end)
    assert eventually(fn -> processes_started_by(Beamicom.Host.Runtime) == runtimes_before end)
  end

  test "an optional audio exit leaves the player and video runtime alive", %{path: path} do
    assert :ok =
             Beamicom.Scenic.play(path,
               audio_command: ["true"],
               speed: 0.01
             )

    player = Process.whereis(Player)
    assert is_pid(player)
    assert eventually(fn -> is_nil(:sys.get_state(player).audio) end)

    state = :sys.get_state(player)
    assert Process.alive?(state.runtime)
    assert Process.alive?(state.scenic)
    assert %{system: :gbc, video: %{width: 160, height: 144}} = Beamicom.Scenic.status()
  end

  test "accepts the Game Boy Pixel Transparency presentation filter", %{path: path} do
    assert :ok =
             Beamicom.Scenic.play(path,
               audio: false,
               speed: 0.01,
               video_filter: :pixel_transparency,
               video_filter_options: [base_alpha: 0.3],
               scale: 2
             )

    assert %{
             system: :gbc,
             video_filter: :pixel_transparency,
             video: %{scaled_width: 320, scaled_height: 288}
           } = Beamicom.Scenic.status()

    assert :sys.get_state(Player).video_filter == {:pixel_transparency, [base_alpha: 0.3]}
  end

  defp child_pids(state) do
    [
      state.owned_output,
      state.audio,
      state.runtime,
      state.input_server,
      state.input_client,
      state.scenic
    ]
    |> Enum.filter(&is_pid/1)
  end

  defp links(pid) do
    {:links, links} = Process.info(pid, :links)
    Enum.sort(links)
  end

  defp await_buttons(runtime, expected, attempts \\ 100)
  defp await_buttons(_runtime, _expected, 0), do: false

  defp await_buttons(runtime, expected, attempts) do
    if :sys.get_state(runtime).machine.bus.buttons == expected do
      true
    else
      Process.sleep(5)
      await_buttons(runtime, expected, attempts - 1)
    end
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(5)
      eventually(fun, attempts - 1)
    end
  end

  defp processes_started_by(module) do
    Process.list()
    |> Enum.filter(fn pid ->
      try do
        match?({^module, _function, _arity}, :proc_lib.translate_initial_call(pid))
      catch
        :exit, _reason -> false
      end
    end)
    |> MapSet.new()
  end

  defp rom do
    :binary.copy(<<0>>, 0x8000)
    |> put_bytes(0x100, <<0xC3, 0x50, 0x01>>)
    |> put_bytes(0x134, "SCENIC OWNER" <> :binary.copy(<<0>>, 4))
    |> put_byte(0x143, 0x80)
    |> put_byte(0x147, 0)
    |> put_byte(0x148, 0)
    |> put_byte(0x149, 0)
    |> put_bytes(0x150, <<0x18, 0xFE>>)
    |> with_checksum()
  end

  defp minimal_nes_rom do
    prg = <<0x4C, 0x00, 0x80, 0::size((0x3FFC - 3) * 8), 0x00, 0x80, 0::16>>
    <<"NES", 0x1A, 1, 1, 0::size(10 * 8)>> <> prg <> <<0::size(8192 * 8)>>
  end

  defp with_checksum(rom) do
    checksum =
      rom
      |> binary_part(0x134, 0x19)
      |> :binary.bin_to_list()
      |> Enum.reduce(0, fn byte, checksum -> checksum - byte - 1 &&& 0xFF end)

    put_byte(rom, 0x14D, checksum)
  end

  defp put_byte(binary, offset, value), do: put_bytes(binary, offset, <<value>>)

  defp put_bytes(binary, offset, bytes) do
    suffix = offset + byte_size(bytes)

    binary_part(binary, 0, offset) <>
      bytes <> binary_part(binary, suffix, byte_size(binary) - suffix)
  end
end
