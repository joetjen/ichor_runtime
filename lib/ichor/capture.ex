defmodule Ichor.Capture do
  @moduledoc """
  Every capture an action receives bundles the raw parsed structure with
  a callable to evaluate it: `node` is always available, unevaluated --
  what `quote` returns directly. `eval` is what an action calls when it
  actually wants a child's value, with an explicit context it controls.
  Never evaluated automatically -- that's the whole point: a special
  form like `if` or `quote` decides *whether* and *when* to call `eval`
  at all, which is exactly what lets an untaken `if` branch, or `quote`'s
  own argument, go unevaluated (and unbound-symbol/nonterminating errors
  inside them stay latent) instead of always eagerly running.

  `position` is this capture's index among its siblings in the
  enclosing rule's own `raw_captures/0` list (its first-occurrence RHS
  position, for a name captured more than once) -- `Ichor.Actions.eval_all/2`
  sorts by it instead of trusting a plain map's own iteration order,
  which Elixir/Erlang make no cross-version guarantee about. Defaults to
  `0`, which is only meaningful (and only ever ties) for a `%Capture{}`
  built by hand rather than by `Ichor.Actions.dispatch_rule/5`'s own
  pipeline -- ties fall back to whatever order the underlying map
  happens to enumerate in, same as before this field existed.

  `span` is where the capture matched, as `{line, column, length}`
  (`Ichor.Node.source_span/0`), or `nil` when the parse recorded no
  positions -- a node an action built itself and handed to
  `Ichor.Actions.evaluate_node/3`, or a parser generated before spans
  existed. An action can place its own errors with it; one that
  returns an error with no position has it placed there for it
  (`Ichor.Actions`).

  ## Recorded positions

  A parser records where each capture matched by wrapping its value
  with `at/3` -- the token range `[from, to)`, nothing more, since most
  spans are never asked for. The wrapper is the runtime's own: it
  travels inside the raw captures, so it survives exactly what they
  survive (a failed alternative's captures are dropped, a repeated
  name's are merged in order), and `Ichor.Actions` takes it off before
  an action sees anything. `node` never holds one, however deep.
  """

  @typedoc """
  One named RHS position's raw (unevaluated) value, or a list of them
  for a name captured more than once -- what `Grammar.LRTable.Captures.build/3`
  (LR/GLR) and `Grammar.Native.Runtime.Parser.merge_captures/2` (PEG)
  each build one production/rule at a time. A list, not a map: list
  order is the one thing Elixir actually guarantees, which is exactly
  what lets `position` above (and hand-authored macro-expansion nodes
  passed to `Ichor.Actions.evaluate_node/3`) mean anything at all.
  """
  @type raw_captures :: [{atom(), node_t() | at() | [node_t() | at()]}]

  @typedoc """
  A value a parser recorded the place of: the token range `[from,
  to)` it matched, in the stream the parse ran over (`at/3`).
  """
  @type at :: {:"$at", node_t(), non_neg_integer(), non_neg_integer()}

  @type node_t ::
          {:token, atom(), String.t()} | {:rule, atom(), raw_captures()} | {:text, String.t()}

  @type eval_fun :: (term() -> {:ok, term(), term()} | {:error, Ichor.Error.t()})

  @type t :: %__MODULE__{
          node: node_t(),
          eval: eval_fun(),
          position: non_neg_integer(),
          span: Ichor.Node.source_span() | nil
        }

  defstruct [:node, :eval, position: 0, span: nil]

  @doc """
  `node`, recorded as having matched the tokens `[from, to)`.

  ## Examples

      iex> Ichor.Capture.at({:token, :NUMBER, "1"}, 3, 4)
      {:"$at", {:token, :NUMBER, "1"}, 3, 4}

  """
  @spec at(node_t(), non_neg_integer(), non_neg_integer()) :: at()
  def at(node, from, to), do: {:"$at", node, from, to}

  @doc """
  `value` -- a node, raw captures, or a list of either -- with every
  recorded position (`at/3`) taken off, however deep.

  For a parser handing a match to code that is promised plain nodes: a
  `c:Ichor.CustomRule.match/4` or `c:Ichor.CustomLexeme.scan/3`
  callback's `rule_matchers`. Those nodes have no positions of their
  own; the place the callback's result matched is recorded around it.

  ## Examples

      iex> Ichor.Capture.plain(
      ...>   Ichor.Capture.at({:rule, :pair, [key: Ichor.Capture.at({:token, :WORD, "a"}, 0, 1)]}, 0, 3)
      ...> )
      {:rule, :pair, [key: {:token, :WORD, "a"}]}

  """
  @spec plain(term()) :: term()
  def plain({:"$at", node, _from, _to}), do: plain(node)
  def plain({:rule, name, captures}), do: {:rule, name, plain(captures)}
  def plain({name, value}) when is_atom(name), do: {name, plain(value)}
  def plain(values) when is_list(values), do: Enum.map(values, &plain/1)
  def plain(other), do: other
end
