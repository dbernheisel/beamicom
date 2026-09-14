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
  def open(title, filters, initial_directory),
    do: Beamicom.Scenic.FileDialog.Linux.open(title, filters, initial_directory)

  @impl true
  def save(title, filters, initial_directory, default_name),
    do: Beamicom.Scenic.FileDialog.Linux.save(title, filters, initial_directory, default_name)

  @impl true
  def directory(title, initial_directory),
    do: Beamicom.Scenic.FileDialog.Linux.directory(title, initial_directory)
end
