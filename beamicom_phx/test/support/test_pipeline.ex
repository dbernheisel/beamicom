defmodule BeamicomPhx.TestPipeline do
  @moduledoc false

  def child_spec({module, _options, _test_process} = arguments) do
    %{
      id: {__MODULE__, module},
      start: {__MODULE__, :start_link, [arguments]},
      restart: :temporary,
      type: :supervisor,
      modules: [module]
    }
  end

  def start_link({module, options, test_process}) do
    case Membrane.Pipeline.start_link(module, options) do
      {:ok, supervisor, pipeline} ->
        send(test_process, {:test_pipeline_started, pipeline})
        {:ok, supervisor}

      {:error, _reason} = error ->
        error
    end
  end
end
