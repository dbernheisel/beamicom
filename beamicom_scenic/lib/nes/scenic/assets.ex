defmodule Beamicom.NES.Scenic.Assets do
  @moduledoc """
  Static asset library for Scenic. Required as soon as any component renders text
  (e.g. the `Save` button on `Beamicom.NES.Scenic.Screen`), since text needs a font
  from the library. Scenic's default fonts (`:roboto`, `:roboto_mono`) are included
  automatically; the default `assets/` source covers everything else.
  """
  use Scenic.Assets.Static, otp_app: :beamicom_scenic
end
