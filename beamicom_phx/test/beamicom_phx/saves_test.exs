defmodule BeamicomPhx.SavesTest do
  use ExUnit.Case, async: true

  alias BeamicomPhx.Saves

  @tag :tmp_dir
  test "atomic_write/2 publishes a complete file without leaving its temporary file", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "save.png")

    assert :ok = Saves.atomic_write(path, "complete PNG")
    assert File.read(path) == {:ok, "complete PNG"}
    assert temporary_files(path) == []
  end

  @tag :tmp_dir
  test "atomic_write/2 removes its temporary file when rename fails", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "save.png")
    File.mkdir!(path)

    assert {:error, _reason} = Saves.atomic_write(path, "complete PNG")
    assert File.dir?(path)
    assert temporary_files(path) == []
  end

  defp temporary_files(path), do: Path.wildcard(path <> ".tmp-*")
end
