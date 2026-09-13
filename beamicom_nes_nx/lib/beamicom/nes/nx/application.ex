defmodule Beamicom.NES.Nx.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    if Application.get_env(:beamicom_nes_nx, :auto_enable, true) do
      Beamicom.NES.Nx.enable(
        ppu_renderer:
          Application.get_env(
            :beamicom_nes_nx,
            :ppu_renderer,
            Beamicom.NES.Nx.PPUAtlasRenderer
          ),
        apu_renderer:
          Application.get_env(
            :beamicom_nes_nx,
            :apu_renderer,
            Beamicom.NES.Nx.APUBlockRenderer
          )
      )
    end

    Supervisor.start_link([], strategy: :one_for_one, name: Beamicom.NES.Nx.Supervisor)
  end
end
