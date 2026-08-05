defmodule BeamicomPhxWeb.SaveController do
  @moduledoc """
  Serves save-state PNGs from the runtime-configured saves directory
  (`BeamicomPhx.Saves.dir/0`), which lives outside `priv/static` and so can't be
  served by `Plug.Static`.
  """
  use BeamicomPhxWeb, :controller

  def show(conn, %{"name" => name}) do
    # basename strips any path-traversal; restrict to .png files that exist.
    file = Path.join(BeamicomPhx.Saves.dir(), Path.basename(name))

    if String.ends_with?(file, ".png") and File.regular?(file) do
      conn
      |> put_resp_content_type("image/png")
      |> send_file(200, file)
    else
      send_resp(conn, 404, "not found")
    end
  end
end
