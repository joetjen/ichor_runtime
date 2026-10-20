defmodule Grammar.GLR.RuntimeTest do
  use ExUnit.Case, async: true

  alias Grammar.GLR.Runtime
  alias Grammar.LRTable.Production
  alias Grammar.VM.Token

  @end_symbol :"$end"

  describe "run/6, a deterministic (conflict-free) grammar: s := X" do
    setup do
      productions = %{
        0 => %Production{id: 0, lhs: :s, rhs: [{:terminal, :X}], captures: [{0, :x, :token}]}
      }

      action_fn = fn
        0, :X -> [{:shift, 1}]
        1, @end_symbol -> [{:reduce, 0}]
        2, @end_symbol -> [:accept]
        _, _ -> []
      end

      goto_fn = fn
        0, :s -> 2
        _, _ -> nil
      end

      %{productions: productions, action_fn: action_fn, goto_fn: goto_fn}
    end

    test "shifts, reduces, and accepts, returning the built captures", ctx do
      stream = {%Token{name: :X, text: "x", line: 1, column: 1}}

      assert Runtime.run(ctx.action_fn, ctx.goto_fn, ctx.productions, 0, @end_symbol, stream) ==
               {:ok, 1, [x: Ichor.Capture.at({:token, :X, "x"}, 0, 1)]}
    end

    test "fails with an unexpected-token error when nothing shifts", ctx do
      stream = {%Token{name: :Y, text: "y", line: 3, column: 5}}

      assert {:error, error} =
               Runtime.run(ctx.action_fn, ctx.goto_fn, ctx.productions, 0, @end_symbol, stream)

      assert error.stage == :parser
      assert error.line == 3
      assert error.column == 5
      assert error.message =~ ~s("y")
    end

    test "fails with an end-of-input error when the stream runs out mid-parse", ctx do
      assert {:error, error} =
               Runtime.run(ctx.action_fn, ctx.goto_fn, ctx.productions, 0, @end_symbol, {})

      assert error.message =~ "end of input"
    end
  end

  describe "run/6, genuine ambiguity: s := a | b, a := X, b := X" do
    # Mirrors test/ambig_tiebreak/ambig_tiebreak.aether (ichor's own
    # integration fixture) hand-compiled into raw action/goto tables --
    # state 1's own action on end-of-input is a real reduce/reduce
    # conflict (both a := X and b := X apply), forked by GSS.add_edge
    # and resolved at the very end by GSS.paths/finish's declared-order
    # (lowest production id / first-declared-alternative) tie-break.
    setup do
      productions = %{
        0 => %Production{id: 0, lhs: :s, rhs: [{:nonterminal, :a}], captures: [{0, :a, :rule}]},
        1 => %Production{id: 1, lhs: :s, rhs: [{:nonterminal, :b}], captures: [{0, :b, :rule}]},
        2 => %Production{id: 2, lhs: :a, rhs: [{:terminal, :X}], captures: [{0, :x, :token}]},
        3 => %Production{id: 3, lhs: :b, rhs: [{:terminal, :X}], captures: [{0, :x, :token}]}
      }

      action_fn = fn
        0, :X -> [{:shift, 1}]
        1, @end_symbol -> [{:reduce, 2}, {:reduce, 3}]
        2, @end_symbol -> [{:reduce, 0}]
        3, @end_symbol -> [{:reduce, 1}]
        4, @end_symbol -> [:accept]
        _, _ -> []
      end

      goto_fn = fn
        0, :a -> 2
        0, :b -> 3
        0, :s -> 4
        _, _ -> nil
      end

      %{productions: productions, action_fn: action_fn, goto_fn: goto_fn}
    end

    test "a declared first in s's own alternatives wins, not b", ctx do
      stream = {%Token{name: :X, text: "x", line: 1, column: 1}}

      assert Runtime.run(ctx.action_fn, ctx.goto_fn, ctx.productions, 0, @end_symbol, stream) ==
               {:ok, 1,
                [
                  a:
                    Ichor.Capture.at(
                      {:rule, :a, [x: Ichor.Capture.at({:token, :X, "x"}, 0, 1)]},
                      0,
                      1
                    )
                ]}
    end
  end
end
