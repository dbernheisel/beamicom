defmodule NxNes.Batch do
  def stack([%Nx.Tensor{} | _] = xs), do: Nx.stack(xs) |> Nx.vectorize(:sample)

  def stack([%{} = first | _] = xs),
    do: Map.new(first, fn {k, _} -> {k, stack(Enum.map(xs, &Map.fetch!(&1, k)))} end)

  def host(%Nx.Tensor{} = t), do: t |> Nx.devectorize() |> Nx.backend_copy(Nx.BinaryBackend)
  def host(m) when is_map(m), do: Map.new(m, fn {k, v} -> {k, host(v)} end)
  def host(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.map(&host/1) |> List.to_tuple()
  def resident(s), do: Nx.backend_copy(s, {EXLA.Backend, client: :host})
end
