defmodule Ichor.Syntax.Record do
  @moduledoc """
  How a lossless parser records which rules matched where, for
  `Ichor.Syntax.tree/3` to weave the tokens into.

  The records travel **inside the ordinary raw captures**, under one
  reserved name (`key/0`), rather than beside them. That is what makes
  them correct for free: every backend already discards a failed
  alternative's captures and merges a name captured more than once into
  one ordered list, so a record of a rule that was tried and abandoned
  never survives, and the ones that do stay in source order. The key
  can never collide with a grammar's own capture name, since `$` is not
  a name character in any grammar notation Ichor reads.

  A rule's own captures hold its callees' records; the call site takes
  them out before the captures go anywhere else (`called/4`), so
  `Ichor.Actions` never sees one, and records the call as one record in
  its place.
  """

  alias Grammar.LRTable.{Captures, Production}
  alias Ichor.{Capture, Syntax}

  @key :"$syntax"

  @doc "The reserved capture name records travel under."
  @spec key() :: atom()
  def key, do: @key

  @doc """
  The records `captures` hold, in order, and `captures` without them.

      iex> Ichor.Syntax.Record.take([{:n, {:text, "1"}}])
      {[], [{:n, {:text, "1"}}]}

  """
  @spec take(Capture.raw_captures()) :: {[Syntax.record()], Capture.raw_captures()}
  def take(captures) do
    case List.keytake(captures, @key, 0) do
      nil -> {[], captures}
      {{@key, records}, rest} -> {List.wrap(records), rest}
    end
  end

  @doc """
  A call of `rule` that matched the tokens `[from, to)`, whose own
  captures were `captures`: the captures without the records, for the
  ordinary `{:rule, rule, captures}`, and the call's own record, holding
  those records as its children.
  """
  @spec called(atom(), non_neg_integer(), non_neg_integer(), Capture.raw_captures()) ::
          {Capture.raw_captures(), Syntax.record()}
  def called(rule, from, to, captures) do
    {children, captures} = take(captures)
    {captures, {rule, from, to, children}}
  end

  @doc """
  `Grammar.LRTable.Captures.build/3`, recording: the captures for
  `production`, holding the records of the rules on its right-hand
  side. It takes what `build/3` takes, so a runtime can be handed
  either.

  A grammar rule on the right-hand side is recorded as one record over
  the span it covers. A helper nonterminal LR desugaring made up
  (`$star_1`, `$grp_2`, ... -- every name starting with `$`) is not a
  rule the grammar's author wrote, so its records are spliced into this
  production's own. A helper's span is taken whatever kind of capture
  the production makes of it: a `:text` capture drops the helper's
  captures but keeps its records, as the PEG backends do.
  """
  @spec reduced(Production.t(), [Captures.entry()], tuple()) :: Capture.raw_captures()
  def reduced(%Production{rhs: rhs} = production, entries, stream) do
    {entries, records} =
      rhs
      |> Enum.zip(entries)
      |> Enum.map_reduce([], fn
        {{:nonterminal, name}, {captures, from, to}}, records ->
          {children, captures} = take(captures)
          {{captures, from, to}, records ++ recorded(name, from, to, children)}

        {_terminal, entry}, records ->
          {entry, records}
      end)

    captures = Captures.build(production, entries, stream)
    if records == [], do: captures, else: captures ++ [{@key, records}]
  end

  defp recorded(name, from, to, children) do
    if helper?(name), do: children, else: [{name, from, to, children}]
  end

  @doc """
  The root's record of a parse that matched `[0, to)` with `captures`,
  and the captures without the records -- for `Ichor.Actions`.
  """
  @spec root(atom(), non_neg_integer(), Capture.raw_captures()) ::
          {Capture.raw_captures(), Syntax.record()}
  def root(rule, to, captures), do: called(rule, 0, to, captures)

  defp helper?(name), do: String.starts_with?(Atom.to_string(name), "$")
end
