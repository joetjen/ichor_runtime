defmodule Ichor.Backtrack.TreeTest do
  use ExUnit.Case, async: true

  alias Ichor.Backtrack.Tree

  # A goal succeeding once per value in `values`, in order -- the
  # minimal fixture every test below composes larger goals from.
  defp goal_of(values), do: fn _bindings -> solutions_of(values) end

  defp solutions_of(values) do
    Enum.reduce(Enum.reverse(values), Tree.empty(), fn v, acc ->
      Tree.concat(Tree.of_one(v), acc)
    end)
  end

  describe "unit/0 and fail/0" do
    test "unit succeeds exactly once, with the bindings passed straight through" do
      assert Tree.next(Tree.unit().(:some_bindings)) ==
               {:solution, :some_bindings, Tree.empty()}
    end

    test "fail never succeeds" do
      assert Tree.next(Tree.fail().(:some_bindings)) == :empty
    end
  end

  describe "empty/0 and of_one/1" do
    test "empty/0 is the empty solution sequence" do
      assert Tree.next(Tree.empty()) == :empty
    end

    test "of_one/1 is a single solution followed by nothing else" do
      assert {:solution, :v, rest} = Tree.next(Tree.of_one(:v))
      assert Tree.next(rest) == :empty
    end
  end

  describe "concat/2" do
    test "every solution of the first sequence, then every solution of the second" do
      assert Tree.to_list(Tree.concat(solutions_of([1, 2]), solutions_of([3, 4]))) == [1, 2, 3, 4]
    end

    test "concatenating with an empty sequence is the identity" do
      assert Tree.to_list(Tree.concat(Tree.empty(), solutions_of([1]))) == [1]
      assert Tree.to_list(Tree.concat(solutions_of([1]), Tree.empty())) == [1]
    end
  end

  describe "disjunction/2" do
    test "every solution of goal1, then every solution of goal2" do
      goal = Tree.disjunction(goal_of([1, 2]), goal_of([3, 4]))
      assert Tree.to_list(goal.(:b)) == [1, 2, 3, 4]
    end

    test "a failing first goal falls through entirely to the second" do
      goal = Tree.disjunction(Tree.fail(), goal_of([1]))
      assert Tree.to_list(goal.(:b)) == [1]
    end
  end

  describe "conjunction/2" do
    test "every solution of goal1 feeds into goal2, results concatenated in order" do
      goal2 = fn v -> solutions_of([{v, :x}, {v, :y}]) end
      goal = Tree.conjunction(goal_of([1, 2]), goal2)

      assert Tree.to_list(goal.(:b)) == [{1, :x}, {1, :y}, {2, :x}, {2, :y}]
    end

    test "no solutions from goal1 means no solutions at all, goal2 never invoked" do
      poison = fn _v -> raise "should never be called" end
      goal = Tree.conjunction(Tree.fail(), poison)
      assert Tree.to_list(goal.(:b)) == []
    end
  end

  describe "once/1" do
    test "keeps only the first solution, discarding the rest" do
      goal = Tree.once(goal_of([1, 2, 3]))
      assert Tree.to_list(goal.(:b)) == [1]
    end

    test "a goal with no solutions still has none" do
      goal = Tree.once(Tree.fail())
      assert Tree.to_list(goal.(:b)) == []
    end
  end

  describe "flat_map/2" do
    test "maps every solution through fun, concatenating the resulting sequences in order" do
      fun = fn v -> solutions_of([v * 10, v * 100]) end
      assert Tree.to_list(Tree.flat_map(solutions_of([1, 2]), fun)) == [10, 100, 20, 200]
    end

    test "flat_map over an empty sequence is empty" do
      assert Tree.to_list(Tree.flat_map(Tree.empty(), fn v -> solutions_of([v]) end)) == []
    end
  end

  describe "take/2" do
    test "the first n solutions, in order" do
      assert Tree.to_list(Tree.take(solutions_of([1, 2, 3, 4]), 2)) == [1, 2]
    end

    test "n = 0 takes nothing, regardless of how many solutions exist" do
      assert Tree.to_list(Tree.take(solutions_of([1, 2, 3]), 0)) == []
    end

    test "asking for more than exist just returns what's there" do
      assert Tree.to_list(Tree.take(solutions_of([1, 2]), 10)) == [1, 2]
    end
  end

  describe "to_list/1" do
    test "eagerly collects every solution into a plain list, in order" do
      assert Tree.to_list(solutions_of([1, 2, 3])) == [1, 2, 3]
    end

    test "an empty sequence collects to an empty list" do
      assert Tree.to_list(Tree.empty()) == []
    end
  end
end
