defmodule NxNes.StateGraph do
  @moduledoc """
  Removes unchanged values from conditional and loop results before EXLA lowering.

  Nx represents a conditional returning a state container as one tuple,
  including fields which are identical in every branch. XLA may copy those
  fields to satisfy conditional buffer ownership. Hoist identical expression
  IDs out of the result; keep all changed fields in one conditional so its
  predicate and branch computations still execute together. Loop outputs which
  return an unmodified loop parameter reuse that parameter's initial value.

  This experiment targets the pure, terminating NES graphs on Nx 1.0.0.
  It uses Nx expression internals; it is not a general optimizer for graphs
  with hooks, runtime callbacks or nonterminating loops.
  """
  alias Nx.Defn.{Composite, Expr, Tree}
  alias Nx.Tensor, as: T

  def prune(result) do
    {result, _cache} = Composite.traverse(result, %{}, &visit/2)
    result
  end

  defp visit(%T{data: %Expr{id: id}} = t, cache) do
    case cache do
      %{^id => result} ->
        {result, cache}

      _ ->
        {result, cache} = rewrite(t, cache)
        {result, Map.put(cache, id, result)}
    end
  end

  defp visit(t, cache), do: {t, cache}

  defp rewrite(%T{data: %Expr{op: :elem, args: [source, index]}} = t, cache) do
    case source do
      %T{data: %Expr{op: op}} when op in [:cond, :while] ->
        {fields, cache} = visit(source, cache)
        {elem(fields, index), cache}

      _ ->
        descend(t, cache)
    end
  end

  defp rewrite(%T{data: %Expr{op: :cond}} = t, cache) do
    {[clauses, last], cache} = Tree.apply_args(t, cache, &visit/2)

    if is_tuple(last) do
      branches = [last | Enum.map(clauses, &elem(&1, 1))]
      indices = indices(last)

      changed =
        Enum.filter(indices, fn i ->
          not Enum.all?(branches, &same?(elem(&1, i), elem(last, i)))
        end)

      if changed == [] do
        {last, cache}
      else
        take = fn branch -> changed |> Enum.map(&elem(branch, &1)) |> List.to_tuple() end
        reduced = Expr.cond(Enum.map(clauses, fn {p, b} -> {p, take.(b)} end), take.(last))
        replacements = Enum.zip(changed, Tuple.to_list(reduced)) |> Map.new()
        fields = Enum.map(indices, &Map.get(replacements, &1, elem(last, &1))) |> List.to_tuple()
        {fields, cache}
      end
    else
      if Enum.all?(clauses, fn {_, b} -> same?(b, last) end) do
        {last, cache}
      else
        {%{t | data: %{t.data | args: [clauses, last]}}, cache}
      end
    end
  end

  defp rewrite(%T{data: %Expr{op: :while}} = t, cache) do
    {[initial, arg, _pred, body] = args, cache} = Tree.apply_args(t, cache, &visit/2)
    updated = %{t | data: %{t.data | args: args}}

    if is_tuple(initial) do
      fields =
        for i <- indices(initial) do
          if same?(elem(arg, i), elem(body, i)) do
            elem(initial, i)
          else
            template = elem(initial, i)

            %{
              template
              | data: %Expr{
                  id: make_ref(),
                  op: :elem,
                  args: [updated, i],
                  context: t.data.context
                }
            }
          end
        end

      {List.to_tuple(fields), cache}
    else
      # Retain the loop even when its sole result is unchanged: it may not terminate.
      {updated, cache}
    end
  end

  defp rewrite(t, cache), do: descend(t, cache)

  defp descend(t, cache) do
    {args, cache} = Tree.apply_args(t, cache, &visit/2)
    {%{t | data: %{t.data | args: args}}, cache}
  end

  defp indices(tuple), do: Enum.to_list(0..(tuple_size(tuple) - 1)//1)

  defp same?(%T{data: %Expr{id: id}}, %T{data: %Expr{id: id}}), do: true
  defp same?(_, _), do: false
end
