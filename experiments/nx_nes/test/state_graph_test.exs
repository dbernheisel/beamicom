defmodule NxNes.StateGraphTest do
  use ExUnit.Case, async: false
  import Nx.Defn

  defn example(state, rounds) do
    {state, _} =
      while {state, rounds}, rounds > 0 do
        state =
          if Nx.remainder(rounds, 2) == 0 do
            %{state | n: state.n + 2}
          else
            %{
              state
              | n: state.n + 1,
                ram: Nx.put_slice(state.ram, [rounds], Nx.tensor([7], type: :u8))
            }
          end

        {state, rounds - 1}
      end

    state
  end

  test "pruning preserves nested loop updates and unchanged ROM across both branches" do
    state = %{
      n: Nx.tensor(0),
      ram: Nx.broadcast(Nx.tensor(0, type: :u8), {16}),
      rom: Nx.iota({32}, type: :u8)
    }

    plain = EXLA.jit(&example/2)
    pruned = EXLA.jit(fn s, n -> NxNes.StateGraph.prune(example(s, n)) end)

    for n <- [0, 1, 8, 11] do
      expected = plain.(state, Nx.tensor(n))
      actual = pruned.(state, Nx.tensor(n))

      for key <- [:n, :ram, :rom],
          do: assert(Nx.to_binary(actual[key]) == Nx.to_binary(expected[key]))
    end
  end
end
