defmodule Ichor.ActionsMoreTest.CountingActions do
  @moduledoc "Each item embeds the context it saw, so evaluation order is directly observable."
  @behaviour Ichor.Actions

  @impl true
  def handle_rule(:item, %{WORD: cap}, ctx) do
    {:ok, text, ctx} = cap.eval.(ctx)
    {:ok, {text, ctx}, ctx + 1}
  end

  def handle_rule(:list, captures, ctx), do: Ichor.Actions.eval_all(captures, ctx)
end

defmodule Ichor.ActionsMoreTest.RejectingActions do
  @behaviour Ichor.Actions

  @impl true
  def handle_token(:DIGITS, text, _ctx) do
    {:error, Ichor.Error.new(message: "digits are not allowed: #{text}", stage: :action)}
  end
end

defmodule Ichor.ActionsMoreTest.FinalizingActions do
  @behaviour Ichor.Actions

  @impl true
  def finalize(_ctx),
    do: {:error, [Ichor.Error.new(message: "finalize always rejects", stage: :action)]}
end

defmodule Ichor.ActionsMoreTest.PassthroughFallbackActions do
  # Implements handle_rule/3, but only for :implemented -- :other_rule
  # has no matching clause and must fall back to the default, not crash.
  @behaviour Ichor.Actions

  @impl true
  def handle_rule(:implemented, %{WORD: cap}, ctx), do: cap.eval.(ctx)
end

defmodule Ichor.ActionsMoreTest.InternalCrashActions do
  # handle_rule/3 itself matches (right module/function/arity), but its
  # *body* calls a differently-shaped local function, raising a
  # FunctionClauseError for a completely unrelated function -- must
  # propagate, not be swallowed as "no matching clause, fall back."
  @behaviour Ichor.Actions

  @impl true
  def handle_rule(:boom, _captures, ctx), do: only_takes_atoms(ctx)

  defp only_takes_atoms(x) when is_atom(x), do: {:ok, x, x}
end

defmodule Ichor.ActionsMoreTest do
  use ExUnit.Case, async: true

  alias Ichor.ActionsMoreTest.{
    CountingActions,
    FinalizingActions,
    InternalCrashActions,
    PassthroughFallbackActions,
    RejectingActions
  }

  defp token(name, text), do: {:token, name, text}
  defp rule(name, captures), do: {:rule, name, captures}

  describe "evaluate/5" do
    test "dispatches the root rule and returns the final context alongside the value" do
      raw = rule(:item, %{WORD: token(:WORD, "hi")})

      assert Ichor.Actions.evaluate(:item, elem(raw, 2), CountingActions, 0) ==
               {:ok, {"hi", 0}, 1}
    end

    test "threads context across sibling captures in order" do
      list =
        rule(:list, %{
          item: [rule(:item, %{WORD: token(:WORD, "a")}), rule(:item, %{WORD: token(:WORD, "b")})]
        })

      assert {:ok, %{item: [{"a", 0}, {"b", 1}]}, 2} =
               Ichor.Actions.evaluate(:list, elem(list, 2), CountingActions, 0)
    end

    test "runs finalize/1 over the final context when the actions module implements it" do
      raw = rule(:whatever, %{})

      assert {:error, [error]} =
               Ichor.Actions.evaluate(:whatever, elem(raw, 2), FinalizingActions, nil)

      assert error.message == "finalize always rejects"
    end

    test "skips finalize entirely when the actions module doesn't implement it" do
      raw = rule(:item, %{WORD: token(:WORD, "hi")})

      assert Ichor.Actions.evaluate(:item, elem(raw, 2), CountingActions, 0) ==
               {:ok, {"hi", 0}, 1}
    end

    test "a rejected token propagates all the way out as the overall result" do
      raw = rule(:whatever, %{n: token(:DIGITS, "123")})

      assert {:error, error} =
               Ichor.Actions.evaluate(:whatever, elem(raw, 2), RejectingActions, nil)

      assert error.message =~ "digits are not allowed"
    end

    test "capture_shapes fills in [] for a repeatable capture that matched zero times" do
      # The raw tree has no :op key at all (it matched zero times under
      # a `*`) -- capture_shapes says :op is repeatable for :expr, so
      # the built captures map must show %{op: []}, not a missing key.
      raw_captures = %{n: token(:NUMBER, "1")}
      shapes = %{expr: MapSet.new([:op])}

      assert {:ok, %Ichor.Node{captures: %{op: [], n: "1"}}, nil} =
               Ichor.Actions.dispatch_rule(Support.NoActions, :expr, raw_captures, nil, shapes)
    end
  end

  describe "dispatch_rule/5 fallback behavior" do
    test "falls back to the default for a rule the actions module doesn't implement a clause for" do
      raw_captures = %{WORD: token(:WORD, "fallback")}

      assert Ichor.Actions.dispatch_rule(
               PassthroughFallbackActions,
               :other_rule,
               raw_captures,
               nil,
               %{}
             ) == {:ok, "fallback", nil}
    end

    test "uses the real clause when one matches" do
      raw_captures = %{WORD: token(:WORD, "handled")}

      assert Ichor.Actions.dispatch_rule(
               PassthroughFallbackActions,
               :implemented,
               raw_captures,
               nil,
               %{}
             ) == {:ok, "handled", nil}
    end

    test "does NOT swallow a FunctionClauseError raised from inside a matched clause's own body" do
      assert_raise FunctionClauseError, fn ->
        Ichor.Actions.dispatch_rule(InternalCrashActions, :boom, %{}, "not an atom", %{})
      end
    end
  end

  describe "dispatch_token/4 fallback behavior" do
    test "the raw text passes through when handle_token/3 isn't implemented at all" do
      assert Ichor.Actions.dispatch_token(Support.NoActions, :WORD, "hi", nil) == {:ok, "hi"}
    end

    test "a real handle_token/3 clause is used when present" do
      assert Ichor.Actions.dispatch_token(RejectingActions, :OTHER, "x", nil) == {:ok, "x"}
    end
  end

  describe "eval_all/2" do
    test "evaluates every capture, threading context in order" do
      captures = %{
        a: %Ichor.Capture{node: {:text, "a"}, eval: fn ctx -> {:ok, "A", ctx + 1} end},
        b: %Ichor.Capture{node: {:text, "b"}, eval: fn ctx -> {:ok, "B", ctx + 1} end}
      }

      assert Ichor.Actions.eval_all(captures, 0) == {:ok, %{a: "A", b: "B"}, 2}
    end

    test "a list-valued capture evaluates to a list of values, in order" do
      captures = %{
        item: [
          %Ichor.Capture{node: {:text, "1"}, eval: fn ctx -> {:ok, 1, ctx} end},
          %Ichor.Capture{node: {:text, "2"}, eval: fn ctx -> {:ok, 2, ctx} end}
        ]
      }

      assert Ichor.Actions.eval_all(captures, nil) == {:ok, %{item: [1, 2]}, nil}
    end

    test "halts and returns immediately on the first error" do
      captures = %{
        a: %Ichor.Capture{node: {:text, "a"}, eval: fn _ctx -> {:error, :boom} end},
        never: %Ichor.Capture{node: {:text, "x"}, eval: fn _ctx -> raise "should never run" end}
      }

      assert Ichor.Actions.eval_all(captures, nil) == {:error, :boom}
    end
  end

  describe "default fallback shape" do
    test "exactly one meaningful capture passes its value straight through, unwrapped" do
      raw_captures = %{n: token(:NUMBER, "42")}

      assert Ichor.Actions.dispatch_rule(Support.NoActions, :factor, raw_captures, nil, %{}) ==
               {:ok, "42", nil}
    end

    test "more than one capture builds an Ichor.Node" do
      raw_captures = %{a: token(:A, "x"), b: token(:B, "y")}

      assert {:ok, %Ichor.Node{rule: :pair, captures: %{a: "x", b: "y"}}, nil} =
               Ichor.Actions.dispatch_rule(Support.NoActions, :pair, raw_captures, nil, %{})
    end

    test "a single capture that's a list (repeated once) still builds a node, not a passthrough" do
      raw_captures = %{item: [token(:A, "x")]}

      assert {:ok, %Ichor.Node{rule: :list, captures: %{item: ["x"]}}, nil} =
               Ichor.Actions.dispatch_rule(Support.NoActions, :list, raw_captures, nil, %{})
    end
  end
end
