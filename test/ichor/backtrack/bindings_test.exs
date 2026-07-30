defmodule Ichor.Backtrack.BindingsTest do
  use ExUnit.Case, async: true

  alias Ichor.Backtrack.Bindings

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

  describe "new/0 and bind/3" do
    test "new/0 is an empty substitution" do
      assert Bindings.new() == %{}
    end

    test "bind/3 extends the substitution under var_id" do
      bindings = Bindings.new() |> Bindings.bind(:x, 42)
      assert Bindings.resolve(Terms, bindings, {:var, :x}) == 42
    end
  end

  describe "resolve/3" do
    test "an unbound variable resolves to itself" do
      assert Bindings.resolve(Terms, Bindings.new(), {:var, :x}) == {:var, :x}
    end

    test "a non-variable term resolves to itself, unexamined" do
      assert Bindings.resolve(Terms, Bindings.new(), {:compound, :f, [1, 2]}) ==
               {:compound, :f, [1, 2]}

      assert Bindings.resolve(Terms, Bindings.new(), :atom) == :atom
    end

    test "follows a chain of bindings to the end" do
      bindings =
        Bindings.new()
        |> Bindings.bind(:x, {:var, :y})
        |> Bindings.bind(:y, {:var, :z})
        |> Bindings.bind(:z, 99)

      assert Bindings.resolve(Terms, bindings, {:var, :x}) == 99
    end

    test "never recurses into a compound's own arguments (shallow only)" do
      bindings = Bindings.bind(Bindings.new(), :x, 1)
      term = {:compound, :f, [{:var, :x}]}
      assert Bindings.resolve(Terms, bindings, term) == term
    end
  end

  describe "unify/4: variables" do
    test "the same variable unifies with itself, bindings unchanged" do
      assert Bindings.unify(Terms, Bindings.new(), {:var, :x}, {:var, :x}) ==
               {:ok, Bindings.new()}
    end

    test "two distinct unbound variables unify by binding one to the other" do
      assert {:ok, bindings} = Bindings.unify(Terms, Bindings.new(), {:var, :x}, {:var, :y})
      # whichever direction the implementation binds, they must resolve together
      assert Bindings.resolve(Terms, bindings, {:var, :x}) ==
               Bindings.resolve(Terms, bindings, {:var, :y})
    end

    test "an unbound variable unifies with a non-variable by binding the variable" do
      assert {:ok, bindings} = Bindings.unify(Terms, Bindings.new(), {:var, :x}, 42)
      assert Bindings.resolve(Terms, bindings, {:var, :x}) == 42
    end

    test "unification is symmetric regardless of which side is the variable" do
      assert {:ok, bindings} = Bindings.unify(Terms, Bindings.new(), 42, {:var, :x})
      assert Bindings.resolve(Terms, bindings, {:var, :x}) == 42
    end

    test "an already-bound variable unifies through its own resolved value" do
      bindings = Bindings.bind(Bindings.new(), :x, 42)
      assert Bindings.unify(Terms, bindings, {:var, :x}, 42) == {:ok, bindings}
      assert Bindings.unify(Terms, bindings, {:var, :x}, 43) == :fail
    end
  end

  describe "unify/4: atomic terms" do
    test "equal atomic terms unify with no new bindings" do
      assert Bindings.unify(Terms, Bindings.new(), :tom, :tom) == {:ok, Bindings.new()}
      assert Bindings.unify(Terms, Bindings.new(), 1, 1) == {:ok, Bindings.new()}
    end

    test "unequal atomic terms fail" do
      assert Bindings.unify(Terms, Bindings.new(), :tom, :bob) == :fail
      assert Bindings.unify(Terms, Bindings.new(), 1, 2) == :fail
    end
  end

  describe "unify/4: compound terms" do
    test "same functor/arity unifies by pairwise-unifying arguments" do
      a = {:compound, :father, [:tom, {:var, :x}]}
      b = {:compound, :father, [:tom, :bob]}

      assert {:ok, bindings} = Bindings.unify(Terms, Bindings.new(), a, b)
      assert Bindings.resolve(Terms, bindings, {:var, :x}) == :bob
    end

    test "different functor fails" do
      a = {:compound, :father, [:tom]}
      b = {:compound, :mother, [:tom]}
      assert Bindings.unify(Terms, Bindings.new(), a, b) == :fail
    end

    test "different arity fails" do
      a = {:compound, :f, [1]}
      b = {:compound, :f, [1, 2]}
      assert Bindings.unify(Terms, Bindings.new(), a, b) == :fail
    end

    test "a failure partway through argument unification fails the whole compound" do
      a = {:compound, :f, [1, 2]}
      b = {:compound, :f, [1, 3]}
      assert Bindings.unify(Terms, Bindings.new(), a, b) == :fail
    end

    test "recursively unifies nested compounds" do
      a = {:compound, :f, [{:compound, :g, [{:var, :x}]}]}
      b = {:compound, :f, [{:compound, :g, [42]}]}

      assert {:ok, bindings} = Bindings.unify(Terms, Bindings.new(), a, b)
      assert Bindings.resolve(Terms, bindings, {:var, :x}) == 42
    end
  end

  describe "unify/4 has no occurs-check: builds a cyclic term instead of failing" do
    test "X = f(X) succeeds, matching ISO Prolog's own unify/2 default" do
      assert {:ok, bindings} =
               Bindings.unify(Terms, Bindings.new(), {:var, :x}, {:compound, :f, [{:var, :x}]})

      assert Bindings.resolve(Terms, bindings, {:var, :x}) == {:compound, :f, [{:var, :x}]}
    end
  end

  describe "unify_occurs_check/4" do
    test "rejects a variable binding directly to a compound containing itself" do
      assert Bindings.unify_occurs_check(
               Terms,
               Bindings.new(),
               {:var, :x},
               {:compound, :f, [{:var, :x}]}
             ) == :fail
    end

    test "rejects the occurs check indirectly, through an existing binding" do
      # y is already bound to x; unifying x with f(y) should be rejected
      # the same as unifying x with f(x) directly would be.
      bindings = Bindings.bind(Bindings.new(), :y, {:var, :x})

      assert Bindings.unify_occurs_check(
               Terms,
               bindings,
               {:var, :x},
               {:compound, :f, [{:var, :y}]}
             ) == :fail
    end

    test "accepts an occurs-free unification, identically to unify/4" do
      assert Bindings.unify_occurs_check(Terms, Bindings.new(), {:var, :x}, {:compound, :f, [1]}) ==
               Bindings.unify(Terms, Bindings.new(), {:var, :x}, {:compound, :f, [1]})
    end

    test "still catches the occurs violation nested inside a larger compound" do
      a = {:compound, :pair, [1, {:var, :x}]}
      b = {:compound, :pair, [1, {:compound, :f, [{:var, :x}]}]}
      assert Bindings.unify_occurs_check(Terms, Bindings.new(), a, b) == :fail
    end
  end
end
