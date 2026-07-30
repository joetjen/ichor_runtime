defmodule Ichor.Toolkit.TermWalkTest do
  use ExUnit.Case, async: true

  alias Ichor.Toolkit.TermWalk

  defmodule Terms do
    @behaviour Ichor.Backtrack.Term

    @impl true
    def variable?({:var, _id}), do: true
    def variable?(_), do: false

    @impl true
    def var_id({:var, id}), do: id

    @impl true
    def compound?({:compound, _f, _args}), do: true
    def compound?(_), do: false

    @impl true
    def deconstruct({:compound, f, args}), do: {f, args}

    @impl true
    def reconstruct(f, args), do: {:compound, f, args}
  end

  describe "fold/4" do
    test "a bare atomic (non-compound) term visits just itself" do
      assert TermWalk.fold(Terms, 42, [], fn t, acc -> [t | acc] end) == [42]
      assert TermWalk.fold(Terms, {:var, :x}, [], fn t, acc -> [t | acc] end) == [{:var, :x}]
    end

    test "visits a compound term, then recurses into every argument" do
      term = {:compound, :f, [1, 2]}

      assert TermWalk.fold(Terms, term, [], fn t, acc -> [t | acc] end) ==
               [2, 1, term]
    end

    test "collects every variable id anywhere in a nested term" do
      term = {:compound, :add, [{:var, :x}, {:compound, :mul, [{:var, :y}, 2]}]}

      ids =
        TermWalk.fold(Terms, term, MapSet.new(), fn
          {:var, id}, acc -> MapSet.put(acc, id)
          _other, acc -> acc
        end)

      assert ids == MapSet.new([:x, :y])
    end

    test "a node is visited before its children (pre-order)" do
      term = {:compound, :f, [{:compound, :g, [1]}]}

      order =
        TermWalk.fold(Terms, term, [], fn t, acc -> [t | acc] end)
        |> Enum.reverse()

      assert order == [term, {:compound, :g, [1]}, 1]
    end

    test "a compound with no arguments visits just itself" do
      term = {:compound, :nullary, []}
      assert TermWalk.fold(Terms, term, [], fn t, acc -> [t | acc] end) == [term]
    end
  end

  describe "rewrite/3" do
    test "transforms a bare atomic term directly" do
      assert TermWalk.rewrite(Terms, {:var, :x}, fn
               {:var, :x} -> 10
               other -> other
             end) == 10
    end

    test "leaves an untransformed term as-is" do
      assert TermWalk.rewrite(Terms, 42, & &1) == 42
    end

    test "transforms every matching leaf, rebuilding compounds around them" do
      term = {:compound, :add, [{:var, :x}, {:compound, :mul, [{:var, :y}, 2]}]}

      transform = fn
        {:var, :x} -> 10
        {:var, :y} -> 20
        other -> other
      end

      assert TermWalk.rewrite(Terms, term, transform) ==
               {:compound, :add, [10, {:compound, :mul, [20, 2]}]}
    end

    test "transform runs once per node, on the way down -- never re-applied to a rebuilt compound" do
      calls = :counters.new(1, [])

      transform = fn t ->
        :counters.add(calls, 1, 1)
        t
      end

      term = {:compound, :f, [{:compound, :g, [1]}]}
      TermWalk.rewrite(Terms, term, transform)

      # once for the outer compound, once for the inner compound, once
      # for the leaf -- three nodes, three calls, not four (which a
      # rewrite that re-examined its own freshly-rebuilt output would
      # produce).
      assert :counters.get(calls, 1) == 3
    end

    test "a transform that turns a leaf into a fresh compound is not itself recursed into" do
      # transform only ever sees pre-existing nodes, top-down, once each
      # -- a variable resolving to a brand-new compound value doesn't
      # get that compound's own arguments rewritten too.
      term = {:var, :x}

      transform = fn
        {:var, :x} -> {:compound, :f, [{:var, :y}]}
        other -> other
      end

      assert TermWalk.rewrite(Terms, term, transform) == {:compound, :f, [{:var, :y}]}
    end
  end
end
