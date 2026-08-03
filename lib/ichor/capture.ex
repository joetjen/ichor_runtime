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
  @type raw_captures :: [{atom(), node_t() | [node_t()]}]

  @type node_t ::
          {:token, atom(), String.t()} | {:rule, atom(), raw_captures()} | {:text, String.t()}

  @type eval_fun :: (term() -> {:ok, term(), term()} | {:error, Ichor.Error.t()})

  @type t :: %__MODULE__{node: node_t(), eval: eval_fun(), position: non_neg_integer()}

  defstruct [:node, :eval, position: 0]
end
