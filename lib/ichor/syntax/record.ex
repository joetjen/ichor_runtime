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

  @doc """
  `record`, its positions counted in `tokens` without their `skip`
  tokens (`Grammar.Source.significant/2`, what an LR or GLR parse runs
  on), counted instead in the trimmed stream `Ichor.Syntax.tree/3`
  expects: a range takes in the skip tokens between its own, and an
  empty record sits just before the next significant token.

      iex> tokens = for {name, text} <- [N: "1", WS: " ", N: "2"],
      ...>   do: %Grammar.VM.Token{name: name, text: text, line: 1, column: 1}
      iex> Ichor.Syntax.Record.unskipped({:pair, 0, 2, [{:n, 1, 2, []}]}, tokens, :WS)
      {:pair, 0, 3, [{:n, 2, 3, []}]}

  """
  @spec unskipped(Syntax.record(), [Grammar.VM.Token.t()], atom() | nil) :: Syntax.record()
  def unskipped(record, _tokens, nil), do: record

  def unskipped(record, tokens, skip) do
    trimmed = Grammar.Source.trimmed(tokens, skip)

    at =
      for {token, i} <- Enum.with_index(trimmed), token.name != skip do
        i
      end

    moved(record, List.to_tuple(at), length(trimmed))
  end

  # A record moved by `at`, the trimmed position of each significant
  # token; `size` is where the trimmed stream ends.
  defp moved({rule, from, to, children}, at, size) do
    from2 = if from < tuple_size(at), do: elem(at, from), else: size
    to2 = if to > from, do: elem(at, to - 1) + 1, else: from2
    {rule, from2, to2, Enum.map(children, &moved(&1, at, size))}
  end

  defp helper?(name), do: String.starts_with?(Atom.to_string(name), "$")
end
