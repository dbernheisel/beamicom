defmodule Beamicom.GB.Nx.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    if Application.get_env(:beamicom_gbc_nx, :auto_enable, false) do
      Beamicom.GB.Nx.enable(
        ppu_renderer:
          Application.get_env(
            :beamicom_gbc_nx,
            :ppu_renderer,
            Beamicom.GB.Nx.PPURenderer
          ),
        apu_renderer:
          Application.get_env(
            :beamicom_gbc_nx,
            :apu_renderer,
            Beamicom.GB.Nx.APUBlockRenderer
          )
      )
    end

    Supervisor.start_link([], strategy: :one_for_one, name: Beamicom.GB.Nx.Supervisor)
  end
end
