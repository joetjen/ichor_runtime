defmodule Grammar.LR.LosslessTest do
  use ExUnit.Case, async: true

  alias Grammar.GLR
  alias Grammar.LR.Lossless
  alias Grammar.LRTable.Production
  alias Grammar.VM.Token
  alias Ichor.Syntax.Record

  @end_symbol :"$end"

  # s := a X*, a := X -- with the `X*` desugared into a helper, `$star_1
  # := $star_1 X | ε`, as Grammar.LRTable.Desugar does.
  setup do
    productions = %{
      0 => %Production{
        id: 0,
        lhs: :s,
        rhs: [{:nonterminal, :a}, {:nonterminal, :"$star_1"}],
        captures: [{0, :a, :rule}, {1, nil, :splice}]
      },
      1 => %Production{id: 1, lhs: :a, rhs: [{:terminal, :X}], captures: [{0, :x, :token}]},
      2 => %Production{
        id: 2,
        lhs: :"$star_1",
        rhs: [{:nonterminal, :"$star_1"}, {:terminal, :X}],
        captures: [{0, nil, :splice}, {1, :x, :token}]
      },
      3 => %Production{id: 3, lhs: :"$star_1", rhs: [], captures: []}
    }

    action_fn = fn
      0, :X -> [{:shift, 1}]
      1, _ -> [{:reduce, 1}]
      2, _ -> [{:reduce, 3}]
      3, :X -> [{:shift, 4}]
      3, @end_symbol -> [{:reduce, 0}]
      4, _ -> [{:reduce, 2}]
      5, @end_symbol -> [:accept]
      _, _ -> []
    end

    goto_fn = fn
      0, :s -> 5
      0, :a -> 2
      2, :"$star_1" -> 3
      _, _ -> nil
    end

    stream = List.to_tuple(for i <- 1..3, do: %Token{name: :X, text: "x", line: 1, column: i})

    %{productions: productions, action_fn: action_fn, goto_fn: goto_fn, stream: stream}
  end

  test "builds the same captures as the ordinary run, with the rules' records beside them", ctx do
    assert {:ok, 3, captures} =
             Lossless.run(ctx.action_fn, ctx.goto_fn, ctx.productions, 0, @end_symbol, ctx.stream)

    {records, captures} = Record.take(captures)
    assert records == [{:a, 0, 1, []}]

    assert Ichor.Capture.plain(captures) ==
             [a: {:rule, :a, [x: {:token, :X, "x"}]}, x: [{:token, :X, "x"}, {:token, :X, "x"}]]
  end

  test "records the grammar's rules and splices the helpers desugaring made up", ctx do
    {:ok, pos, captures} =
      Lossless.run(ctx.action_fn, ctx.goto_fn, ctx.productions, 0, @end_symbol, ctx.stream)

    assert Record.root(:s, pos, captures) |> elem(1) == {:s, 0, 3, [{:a, 0, 1, []}]}
  end

  test "fails as the ordinary run fails", ctx do
    stream = {%Token{name: :Y, text: "y", line: 3, column: 5}}

    assert {:error, error} =
             Lossless.run(ctx.action_fn, ctx.goto_fn, ctx.productions, 0, @end_symbol, stream)

    assert {error.line, error.column, error.stage} == {3, 5, :parser}
  end

  test "GLR records the same, given the recording build", ctx do
    lossless =
      GLR.Runtime.run(
        ctx.action_fn,
        ctx.goto_fn,
        ctx.productions,
        0,
        @end_symbol,
        ctx.stream,
        &Record.reduced/3
      )

    assert lossless ==
             Lossless.run(ctx.action_fn, ctx.goto_fn, ctx.productions, 0, @end_symbol, ctx.stream)
  end
end
