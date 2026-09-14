defmodule Beamicom.Scenic.FileDialog.Native do
  @moduledoc false

  @behaviour Beamicom.Scenic.FileDialog.Backend

  @on_load :load_nif

  def load_nif do
    case :os.type() do
      {:unix, :darwin} ->
        path = :filename.join(:code.priv_dir(:beamicom_scenic), ~c"native/file_dialog")
        :erlang.load_nif(path, 0)

      _other ->
        :ok
    end
  end

  @impl true
  def open(title, filters, initial_directory) do
    case :os.type() do
      {:unix, :darwin} -> mac_open(title, filters, initial_directory, mac_helper_path())
      _other -> Beamicom.Scenic.FileDialog.Linux.open(title, filters, initial_directory)
    end
  end

  @impl true
  def save(title, filters, initial_directory, default_name) do
    case :os.type() do
      {:unix, :darwin} ->
        mac_save(title, filters, initial_directory, default_name, mac_helper_path())

      _other ->
        Beamicom.Scenic.FileDialog.Linux.save(title, filters, initial_directory, default_name)
    end
  end

  @impl true
  def directory(title, initial_directory) do
    case :os.type() do
      {:unix, :darwin} -> mac_directory(title, initial_directory, mac_helper_path())
      _other -> Beamicom.Scenic.FileDialog.Linux.directory(title, initial_directory)
    end
  end

  @doc false
  def mac_open(_title, _filters, _initial_directory, _helper_path),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def mac_save(_title, _filters, _initial_directory, _default_name, _helper_path),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def mac_directory(_title, _initial_directory, _helper_path),
    do: :erlang.nif_error(:nif_not_loaded)

  defp mac_helper_path do
    :beamicom_scenic
    |> :code.priv_dir()
    |> List.to_string()
    |> Path.join("native/BeamicomFileDialog.app")
  end
end
