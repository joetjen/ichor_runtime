defmodule Ichor.Actions do
  @moduledoc """
  How a parsed Aether AST turns into an actual result -- a sandboxed
  program's final value, a config's map/struct, a query's result set, or
  transpiled output. One mechanism, used differently per grammar: a
  grammar's Actions module only implements the rules/tokens it needs
  custom behavior for (`@optional_callbacks`); everything else falls back
  to the defaults below.

  `handle_rule`/`handle_token` are never invoked directly by user code --
  `Grammar.VM` builds the raw capture tree during matching (an
  `Ichor.Capture.raw_captures/0` list, in true source order at every
  level -- never a plain map, which Elixir/Erlang make no cross-version
  iteration-order guarantee about), and this module's `evaluate/5` walks
  it, calling into the actions module (or the default fallback) as it
  goes, threading `context` throughout.

  `evaluate_node/3` is the companion entry point for a raw capture node
  that *didn't* come from the original parse -- a grammar with
  macro-like features (LISP's own `defmacro`/expansion is the reference
  case) needs to evaluate the result of its own expansion through this
  same `handle_rule`/`handle_token` dispatch, not skip it. Not
  Lisp-specific in principle: any grammar with macro-like features needs
  this same re-entry point. Genuinely a runtime concern (called from
  generated/hand-written Actions code while actually running a parse),
  unlike `Ichor.generate/3`/`Ichor.__using__/1`, which only ever run at
  compile time -- that split is exactly why this lives here, in
  `ichor_runtime`, rather than alongside those two in `ichor` proper.
  """

  alias Grammar.Source.Locator
  alias Ichor.{Capture, Error, Node}
  alias Ichor.Toolkit.Result

  @type context :: term()
  @type captures :: %{optional(atom()) => Capture.t() | [Capture.t()]}
  @type capture_shapes :: %{optional(atom()) => MapSet.t(atom())}

  @callback handle_rule(rule :: atom(), captures :: captures(), context :: context()) ::
              {:ok, term(), context()} | {:error, Error.t()}

  @callback handle_token(token :: atom(), text :: String.t(), context :: context()) ::
              {:ok, term()} | {:error, Error.t()}

  @callback finalize(context :: context()) :: :ok | {:error, [Error.t()]}

  @optional_callbacks handle_rule: 3, handle_token: 3, finalize: 1

  @doc """
  Eagerly invokes every capture's `eval`, in true source order (each
  `%Capture{}`'s own `position`, not `captures`' incidental map
  iteration order -- see `Ichor.Capture`'s moduledoc for why those two
  can differ), threading `context` through -- the plain bottom-up fold
  that's correct for grammars with no special-form semantics (most
  config/markup/query grammars, as opposed to something like LISP's
  `if`/`quote`, which need to *not* evaluate an untaken branch at all).
  A list-valued capture (the same name captured more than once, e.g.
  inside a `*`) resolves to a list of values in the same order. Halts
  and returns immediately on the first error.

  A `%Capture{}` built by hand rather than via `dispatch_rule/5`
  (directly constructing this map for a test, say) defaults every
  `position` to `0` -- ties between those fall back to whatever order
  `captures` itself happens to enumerate in, same as this function's
  behavior before `position` existed. Give hand-built captures distinct
  `position`s if you need this function's ordering guarantee to hold
  for them too.
  """
  @spec eval_all(captures(), context()) ::
          {:ok, %{optional(atom()) => term()}, context()} | {:error, Error.t()}
  def eval_all(captures, context) do
    ordered = Enum.sort_by(captures, fn {_name, cap_or_list} -> position_of(cap_or_list) end)

    case Result.reduce_ok(ordered, {%{}, context}, fn {name, cap_or_list}, {acc, ctx} ->
           case eval_one(cap_or_list, ctx) do
             {:ok, value, ctx} -> {:ok, {Map.put(acc, name, value), ctx}}
             {:error, _} = err -> err
           end
         end) do
      {:ok, {acc, ctx}} -> {:ok, acc, ctx}
      {:error, _} = err -> err
    end
  end

  defp position_of(%Capture{position: position}), do: position
  defp position_of([%Capture{position: position} | _]), do: position
  defp position_of([]), do: 0

  defp eval_one(caps, ctx) when is_list(caps) do
    Result.map_ok(caps, ctx, fn cap, ctx -> cap.eval.(ctx) end)
  end

  defp eval_one(%Capture{} = cap, ctx), do: cap.eval.(ctx)

  @doc """
  The single entry point tying `Grammar.VM`'s raw capture tree to a
  grammar's Actions module: evaluates the root rule, then runs
  `finalize/1` over whatever context that produced. Returns the final
  context alongside the value -- needed whenever more than one top-level
  match must thread context forward (e.g. loading a multi-form source
  file one top-level form at a time); callers that only need the value
  can just ignore it.

  `capture_shapes` (from `Grammar.VM.RuleCompiler.capture_shapes/1`) says,
  per rule, which capture names sit under a `*`/`+`/`{n,m}` -- needed so
  e.g. an `op:` that matched zero times still shows up as `[]`, not as a
  missing key indistinguishable from "this rule shape never has an
  `:op`" (see that function's docs for why this can't just be inferred
  from the raw tree at dispatch time).

  ## Options

    * `:locator` -- the parse's `Grammar.Source.Locator`. With it, every
      capture the parser recorded the place of (`Ichor.Capture.at/3`)
      gets its `span`, a default `Ichor.Node` gets its own, and an
      action's error with no position is placed (below). Without it,
      every span is `nil` and errors are returned as the actions gave
      them.
    * `:range` -- the token range `{from, to}` the root rule matched;
      the whole stream by default. A sequence of top-level matches
      gives each one its own.

  ## An action's error says where

  An error a `handle_rule/3` or `handle_token/3` returns with no line
  is placed where that rule or token matched, and shown with the line
  it is on and a caret; nothing else about it changes. The action best
  placed to say where is the one that refused, so an error that already
  has a position -- placed by a nested rule's own action, or by the
  action itself -- keeps it. `finalize/1`'s errors belong to no rule
  and are left as they are.
  """
  @spec evaluate(atom(), Capture.raw_captures(), module(), context(), capture_shapes(), keyword()) ::
          {:ok, term(), context()} | {:error, Error.t() | [Error.t()]}
  def evaluate(
        root_rule,
        raw_captures,
        actions_module,
        initial_context,
        capture_shapes \\ %{},
        opts \\ []
      ) do
    # `function_exported?/3` only answers correctly for a module that has
    # actually been loaded into this BEAM instance -- true for every
    # module reached through a normal call chain, but not guaranteed for
    # one only ever referenced dynamically (e.g. passed in as this very
    # argument), so make sure of it before relying on the check anywhere
    # below.
    Code.ensure_loaded(actions_module)

    locator = Keyword.get(opts, :locator)
    span = root_span(locator, Keyword.get(opts, :range))
    kids = prepared_captures(raw_captures, locator)
    run = %{actions: actions_module, shapes: capture_shapes, locator: locator}

    with {:ok, value, context} <- run_rule(run, root_rule, kids, initial_context, span) do
      case run_finalize(actions_module, context) do
        :ok -> {:ok, value, context}
        {:error, _} = err -> err
      end
    end
  end

  defp root_span(nil, _range), do: nil

  defp root_span(%Locator{stream: stream} = locator, nil),
    do: Locator.span(locator, 0, tuple_size(stream))

  defp root_span(%Locator{} = locator, {from, to}), do: Locator.span(locator, from, to)

  defp run_finalize(actions_module, context) do
    if function_exported?(actions_module, :finalize, 1) do
      actions_module.finalize(context)
    else
      :ok
    end
  end

  @doc """
  Evaluates a raw capture node (as found on any `Ichor.Capture.node`, or
  built directly by something like a macro's `unreify`) against
  `actions_module`, starting from `context`. See this module's own
  moduledoc for when you need this instead of an ordinary `.eval` thunk.

  A node carries no positions, so every capture under it has a `nil`
  span, and an error from it is returned as the action gave it.
  """
  @spec evaluate_node(Ichor.Capture.node_t(), module(), context()) ::
          {:ok, term(), context()} | {:error, Error.t()}
  def evaluate_node(node, actions_module, context) do
    run = %{actions: actions_module, shapes: %{}, locator: nil}

    case prepared(node, nil) do
      {:placed, {:token, name, text}, span, nil} ->
        with {:ok, value} <- run_token(run, name, text, context, span) do
          {:ok, value, context}
        end

      {:placed, {:rule, name, _}, span, kids} ->
        run_rule(run, name, kids, context, span)

      {:placed, {:text, text}, _span, nil} ->
        {:ok, text, context}
    end
  end

  # ---- recorded positions --------------------------------------------------

  # The raw tree, ready to dispatch: every value as `{:placed, node,
  # span, kids}` -- `node` the plain raw node an action sees (no
  # `Ichor.Capture.at/3` wrapper left anywhere in it), `span` where it
  # matched or nil, and `kids`, for a rule, its own captures prepared
  # the same way. One pass over the tree, here: taking the wrappers off
  # each capture's node as it is built would walk every subtree once per
  # level above it.
  defp prepared_captures(raw_captures, locator),
    do: Enum.map(raw_captures, fn {name, value} -> {name, prepared(value, locator)} end)

  defp prepared(values, locator) when is_list(values),
    do: Enum.map(values, &prepared(&1, locator))

  defp prepared({:"$at", node, from, to}, locator),
    do: prepared_node(node, locator && Locator.span(locator, from, to), locator)

  defp prepared(node, locator), do: prepared_node(node, nil, locator)

  defp prepared_node({:rule, name, raw_captures}, span, locator) do
    kids = prepared_captures(raw_captures, locator)
    {:placed, {:rule, name, Enum.map(kids, fn {k, v} -> {k, plain(v)} end)}, span, kids}
  end

  defp prepared_node(node, span, _locator), do: {:placed, node, span, nil}

  defp plain(values) when is_list(values), do: Enum.map(values, &plain/1)
  defp plain({:placed, node, _span, _kids}), do: node

  # An action's error with no position, placed where its rule or token
  # matched (`evaluate/6`'s "An action's error says where").
  defp placed_result({:error, errors}, span, locator) when not is_nil(span),
    do: {:error, placed_errors(errors, span, locator)}

  defp placed_result(result, _span, _locator), do: result

  defp placed_errors(errors, span, locator) when is_list(errors),
    do: Enum.map(errors, &placed_errors(&1, span, locator))

  defp placed_errors(%Error{line: nil} = error, {line, column, _length}, locator),
    do: Grammar.Source.placed(%{error | line: line, column: column}, locator.input)

  defp placed_errors(error, _span, _locator), do: error

  # ---- dispatch + default fallback ---------------------------------------

  @doc false
  def dispatch_rule(actions_module, rule_name, raw_captures, context, capture_shapes) do
    run = %{actions: actions_module, shapes: capture_shapes, locator: nil}
    run_rule(run, rule_name, prepared_captures(raw_captures, nil), context, nil)
  end

  @doc false
  def dispatch_token(actions_module, token_name, text, context) do
    run = %{actions: actions_module, shapes: %{}, locator: nil}
    run_token(run, token_name, text, context, nil)
  end

  defp run_rule(run, rule_name, kids, context, span) do
    normalized = normalize_repeatables(kids, Map.get(run.shapes, rule_name, MapSet.new()))
    captures = build_captures(run, normalized)
    actions_module = run.actions

    result =
      if function_exported?(actions_module, :handle_rule, 3) do
        call_with_fallback(
          fn -> actions_module.handle_rule(rule_name, captures, context) end,
          {actions_module, :handle_rule, 3},
          fn -> default_handle_rule(rule_name, captures, context, span) end
        )
      else
        default_handle_rule(rule_name, captures, context, span)
      end

    placed_result(result, span, run.locator)
  end

  defp run_token(run, token_name, text, context, span) do
    actions_module = run.actions

    result =
      if function_exported?(actions_module, :handle_token, 3) do
        call_with_fallback(
          fn -> actions_module.handle_token(token_name, text, context) end,
          {actions_module, :handle_token, 3},
          fn -> {:ok, text} end
        )
      else
        {:ok, text}
      end

    placed_result(result, span, run.locator)
  end

  # "A grammar's Actions module only implements the rules/tokens it needs
  # custom behavior for" means *per rule/token name*, not just per
  # callback -- a calculator's Actions module might implement handle_rule
  # for :expr/:term but not :factor, expecting :factor to fall through to
  # the default. `function_exported?/3` can only tell us the callback
  # exists at all, not whether THIS call has a matching clause, so the
  # fallback has to happen here, at the call site -- checked against the
  # exact module/function/arity so an unrelated `FunctionClauseError`
  # raised from somewhere *inside* a real clause's own logic isn't
  # swallowed.
  defp call_with_fallback(fun, {mod, name, arity}, fallback) do
    fun.()
  rescue
    e in FunctionClauseError ->
      if e.module == mod and e.function == name and e.arity == arity do
        fallback.()
      else
        reraise e, __STACKTRACE__
      end
  end

  # A repeatable name (per `capture_shapes`) that DID occur gets its
  # value wrapped in place, keeping its original position; one that
  # never occurred at all has no position to keep, so it's appended at
  # the end as `[]` (see `evaluate/5`'s own moduledoc for why this has
  # to happen at all: a repeatable capture that matched zero times must
  # still show up as `[]`, not a missing key).
  defp normalize_repeatables(kids, repeatable_names) do
    {normalized, seen} =
      Enum.map_reduce(kids, MapSet.new(), fn {name, value}, seen ->
        if MapSet.member?(repeatable_names, name) do
          {{name, List.wrap(value)}, MapSet.put(seen, name)}
        else
          {{name, value}, seen}
        end
      end)

    missing = MapSet.difference(repeatable_names, seen)
    normalized ++ Enum.map(missing, &{&1, []})
  end

  # Exactly one capture, captured only once (not via repetition): pass its
  # value straight through, unwrapped -- e.g. calculator's
  # `factor := NUMBER | "(" expr ")"` never needs its own %Ichor.Node{},
  # its single capture's value already *is* factor's value.
  defp default_handle_rule(rule_name, captures, context, span) when map_size(captures) == 1 do
    case Map.to_list(captures) do
      [{_name, %Capture{} = cap}] -> cap.eval.(context)
      [{_name, list}] when is_list(list) -> build_node(rule_name, captures, context, span)
    end
  end

  defp default_handle_rule(rule_name, captures, context, span),
    do: build_node(rule_name, captures, context, span)

  defp build_node(rule_name, captures, context, span) do
    with {:ok, resolved, context} <- eval_all(captures, context) do
      {:ok, %Node{rule: rule_name, captures: resolved, span: span}, context}
    end
  end

  defp build_captures(run, kids) do
    kids
    |> Enum.with_index()
    |> Map.new(fn {{name, value}, position} -> {name, build_capture(run, value, position)} end)
  end

  defp build_capture(run, values, position) when is_list(values),
    do: Enum.map(values, &build_capture(run, &1, position))

  defp build_capture(run, {:placed, {:token, name, text} = node, span, nil}, position) do
    %Capture{
      node: node,
      span: span,
      position: position,
      eval: fn ctx ->
        with {:ok, value} <- run_token(run, name, text, ctx, span) do
          {:ok, value, ctx}
        end
      end
    }
  end

  defp build_capture(run, {:placed, {:rule, name, _} = node, span, kids}, position) do
    %Capture{
      node: node,
      span: span,
      position: position,
      eval: fn ctx -> run_rule(run, name, kids, ctx, span) end
    }
  end

  defp build_capture(_run, {:placed, {:text, text} = node, span, nil}, position) do
    %Capture{node: node, span: span, position: position, eval: fn ctx -> {:ok, text, ctx} end}
  end
end
