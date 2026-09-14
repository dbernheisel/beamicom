defmodule Beamicom.Scenic.Assets do
  @moduledoc """
  Static asset library for the multi-system Scenic host.

  Scenic text and button components require a font from this library. The UI
  uses the same Nintendo NES font asset as `beamicom_phx`.
  """
  use Scenic.Assets.Static,
    otp_app: :beamicom_scenic,
    alias: [beamicom_ui: "fonts/nintendo-nes-font.ttf"]
end
