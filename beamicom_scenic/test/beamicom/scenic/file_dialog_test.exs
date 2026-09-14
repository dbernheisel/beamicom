defmodule Beamicom.Scenic.FileDialogTest do
  use ExUnit.Case, async: false

  alias Beamicom.Scenic.FileDialog
  alias Beamicom.Scenic.FileDialog.Linux

  defmodule FakeBackend do
    @behaviour Beamicom.Scenic.FileDialog.Backend

    @impl true
    def open(title, filters, initial_directory) do
      send(self(), {:open, title, filters, initial_directory})
      Process.get(:file_dialog_result, {:ok, nil})
    end

    @impl true
    def save(title, filters, initial_directory, default_name) do
      send(self(), {:save, title, filters, initial_directory, default_name})
      Process.get(:file_dialog_result, {:ok, nil})
    end

    @impl true
    def directory(title, initial_directory) do
      send(self(), {:directory, title, initial_directory})
      Process.get(:file_dialog_result, {:ok, nil})
    end
  end

  setup do
    previous = Application.get_env(:beamicom_scenic, :file_dialog_backend)
    Application.put_env(:beamicom_scenic, :file_dialog_backend, FakeBackend)

    on_exit(fn ->
      if previous do
        Application.put_env(:beamicom_scenic, :file_dialog_backend, previous)
      else
        Application.delete_env(:beamicom_scenic, :file_dialog_backend)
      end
    end)

    :ok
  end

  test "opens a native selector with normalized filters and an absolute directory" do
    Process.put(:file_dialog_result, {:ok, "/tmp/game.nes"})

    assert {:ok, "/tmp/game.nes"} =
             FileDialog.open([{"ROMs", [".nes", "gb", "gbc"]}], "roms")

    assert_receive {:open, "Load media", [{"ROMs", ["nes", "gb", "gbc"]}], directory}
    assert directory == Path.expand("roms")
  end

  test "maps native cancellation to :cancel" do
    Process.put(:file_dialog_result, {:ok, nil})

    assert :cancel = FileDialog.open([])
    assert_receive {:open, "Load media", [], nil}
  end

  test "opens a save selector with a default file name" do
    Process.put(:file_dialog_result, {:ok, "/tmp/save.png"})

    assert {:ok, "/tmp/save.png"} =
             FileDialog.save([{"Beamicom states", ["png"]}], "/tmp", "game-state.png")

    assert_receive {:save, "Save state", [{"Beamicom states", ["png"]}], "/tmp", "game-state.png"}
  end

  test "opens a native directory selector" do
    Process.put(:file_dialog_result, {:ok, "/tmp/states"})

    assert {:ok, "/tmp/states"} = FileDialog.directory("/tmp")
    assert_receive {:directory, "Select save-state folder", "/tmp"}
  end

  test "returns native errors without rewriting them" do
    Process.put(:file_dialog_result, {:error, "dialog unavailable"})

    assert {:error, "dialog unavailable"} = FileDialog.open([])
  end

  test "rejects malformed filters and options before calling native code" do
    assert {:error, :invalid_filters} = FileDialog.open([{"ROMs", ["*.nes"]}])
    assert {:error, :invalid_filters} = FileDialog.open([{"ROMs", []}])
    assert {:error, :invalid_initial_directory} = FileDialog.open([], :cwd)
    assert {:error, :invalid_initial_directory} = FileDialog.directory(:cwd)
    assert {:error, :invalid_default_name} = FileDialog.save([], nil, "")

    refute_received {:open, _, _, _}
    refute_received {:save, _, _, _, _}
    refute_received {:directory, _, _}
  end

  test "builds isolated Linux selector commands without shell interpolation" do
    assert Linux.command_args(
             :open,
             "Load media",
             [{"ROMs", ["nes", "gb"]}],
             "/tmp/roms",
             nil
           ) == [
             "--file-selection",
             "--title=Load media",
             "--filename=/tmp/roms/",
             "--file-filter=ROMs | *.nes *.gb"
           ]

    assert Linux.command_args(:save, "Save state", [], "/tmp", "state.png") == [
             "--file-selection",
             "--title=Save state",
             "--save",
             "--confirm-overwrite",
             "--filename=/tmp/state.png"
           ]
  end
end
