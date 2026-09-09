defmodule Beamicom.Scenic.Assets do
  @moduledoc """
  Static asset library for the multi-system Scenic host.

  Scenic text and button components require a font from this library. Scenic's
  default fonts (`:roboto`, `:roboto_mono`) are included automatically; the
  default `assets/` source covers everything else.
  """
  use Scenic.Assets.Static, otp_app: :beamicom_scenic
end
