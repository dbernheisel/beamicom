defmodule Beamicom.EI do
  @moduledoc "Pure-Elixir sender-mode implementation of the EI input protocol."

  def default_path do
    Path.join(System.get_env("XDG_RUNTIME_DIR") || System.tmp_dir!(), "beamicom-ei.sock")
  end
end
