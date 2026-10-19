defmodule Grammar.LR.Lossless do
  @moduledoc """
  The LR shift-reduce loop for a lossless parse: the same moves as
  `Grammar.LR`'s and `Grammar.Native.LR`'s, building captures with
  `Ichor.Syntax.Record.reduced/3`, so the rules' records travel with them.

  **Table-driven on purpose, for both backends.** The generated LR parser
  compiles every state into its own function, which calls the ordinary
  `Grammar.LR.Stack.reduce/4` inline. A lossless variant of those would
  be a second copy of every state function. Instead, a parser generated
  with `lossless: true` embeds its table as data and hands it to this
  loop through `action_fn`/`goto_fn` -- the shape `Grammar.GLR.Runtime`
  already takes -- so the fast path's functions stay exactly as they
  are, and the lossless path pays for lookups rather than for code.
  """

  alias Grammar.LRTable
  alias Grammar.LRTable.Production
  alias Ichor.{Capture, Error}
  alias Ichor.Syntax.Record

  @doc """
  Runs the loop over `stream` from `start_state`. `action_fn` answers a
  state and a lookahead with the table's list of actions -- one, since an
  LR table has no conflicts -- and `goto_fn` a state and a nonterminal
  with the state to go to.
  """
  @spec run(
          (LRTable.state_id(), atom() -> [LRTable.action()]),
          (LRTable.state_id(), atom() -> LRTable.state_id() | nil),
          %{non_neg_integer() => Production.t()},
          LRTable.state_id(),
          atom(),
          tuple()
        ) :: {:ok, non_neg_integer(), Capture.raw_captures()} | {:error, Error.t()}
  def run(action_fn, goto_fn, productions, start_state, end_symbol, stream) do
    tables = {action_fn, goto_fn, productions, end_symbol}
    step(tables, stream, 0, [{start_state, 0, 0, nil}])
  end

  defp step({action_fn, goto_fn, productions, end_symbol} = tables, stream, pos, stack) do
    [{state, _, _, _} | _] = stack

    case action_fn.(state, LRTable.current_terminal(stream, pos, end_symbol)) do
      [:accept] ->
        [{_state, _start, _end, captures} | _] = stack
        {:ok, pos, captures}

      [{:shift, target}] ->
        step(tables, stream, pos + 1, [{target, pos, pos + 1, elem(stream, pos)} | stack])

      [{:reduce, prod_id}] ->
        production = Map.fetch!(productions, prod_id)
        {exposed, rest, from, to, captures} = reduce(stack, production, stream, pos)

        step(tables, stream, pos, [{goto_fn.(exposed, production.lhs), from, to, captures} | rest])

      _none ->
        {:error, LRTable.unexpected_error(stream, pos)}
    end
  end

  # `Grammar.LR.Stack.reduce/4`, building with `Record.reduced/3`.
  defp reduce(stack, %Production{rhs: rhs} = production, stream, pos) do
    {popped_rev, rest} = Enum.split(stack, length(rhs))
    popped = Enum.reverse(popped_rev)

    {from, to} =
      case popped do
        [] -> {pos, pos}
        _ -> {elem(List.first(popped), 1), elem(List.last(popped), 2)}
      end

    entries = Enum.map(popped, fn {_state, s, e, value} -> {value, s, e} end)
    [{exposed, _, _, _} | _] = rest

    {exposed, rest, from, to, Record.reduced(production, entries, stream)}
  end
end
