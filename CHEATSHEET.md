# Cheatsheet

Quick reference for everything in `ichor_runtime`, worked examples for
the standalone pieces (`Pratt`, `TermWalk`, `Backtrack`, `Result`). See
the [README](README.md) for the big picture, or
[Ichor's own docs](https://hexdocs.pm/ichor) for grammar authoring
(`.aether` syntax, `mix ichor.gen`, `use Ichor`).

## What an `Ichor.Actions` module receives

You never call `Ichor.Actions.evaluate/5` yourself -- a generated
`run/1,2` calls it, dispatching into your own `Ichor.Actions`
implementation. This is the shape your callbacks see:

```elixir
defmodule MyLang.Actions do
  @behaviour Ichor.Actions

  @impl true
  def handle_token(:NUMBER, text, _ctx), do: {:ok, String.to_integer(text)}

  @impl true
  def handle_rule(:add, %{left: l, right: r}, ctx) do
    {:ok, lv, ctx} = l.eval.(ctx)
    {:ok, rv, ctx} = r.eval.(ctx)
    {:ok, lv + rv, ctx}
  end

  # optional: runs once, after everything else
  @impl true
  def finalize(ctx), do: :ok
end
```

- Implement only the rules/tokens that need custom behavior -- anything
  else falls back automatically: a rule with exactly one meaningful
  capture passes its value straight through; more than one builds an
  `%Ichor.Node{rule: ..., captures: %{...}}`; an unhandled token's raw
  text passes through unchanged.
- A capture under `*`/`+`/`{n,m}` always arrives as a **list**, even if
  it matched zero or one times -- never a bare value, never a missing
  key.
- Each capture is an `%Ichor.Capture{}`: `.node` is the raw, unevaluated
  parse (`Ichor.Capture.node_t()` -- `{:token, name, text}` /
  `{:rule, name, sub_captures}` / `{:text, text}`); `.eval.(ctx)`
  evaluates it and returns `{:ok, value, new_ctx}`. Call `.eval` only
  when you actually want the value -- this is what lets an `if`/`quote`-
  style special form skip evaluating a branch entirely.
- `Ichor.Actions.evaluate_node/3` re-enters this same dispatch for a
  capture node that didn't come from the original parse -- a macro's own
  expansion, most notably (LISP's `defmacro`): `Ichor.Actions.evaluate_node({:rule, :form, captures}, MyLang.Actions, ctx)`.
- Errors are `%Ichor.Error{}` (`Ichor.Error.new/1`, `Ichor.Error.format/1`)
  -- the same struct every stage (lexer, parser, your own actions) uses,
  so error output looks consistent regardless of where it came from.

## `@native(...)` callbacks

The behaviours a grammar's own `@native("Module", "function", ...)`
escape hatch dispatches to -- you implement these, nothing here calls
them for you:

```elixir
defmodule MyRuleCallback do
  @behaviour Ichor.CustomRule

  @impl true
  def match(stream, pos, context, rule_matchers) do
    # stream/pos: the token stream and current position, same contract
    # as any compiled rule matcher. context: read-only, whatever the
    # previous top-level form evaluated to. rule_matchers: a map
    # restricted to this node's own declared dependencies, each
    # (stream, pos, context -> {:ok, new_pos, ref_stack, raw_captures} | :fail).
    :fail
  end
end

defmodule MyLexemeCallback do
  @behaviour Ichor.CustomLexeme

  @impl true
  def scan(input, context, rule_matchers) do
    # input: the *remaining suffix* of the source text. Returns
    # {:ok, text, rest, capture} where text <> rest == input, and
    # capture is nil (ordinary {:token, name, text} capture) or an
    # explicit Ichor.Capture.node_t() override.
    :fail
  end
end
```

## `Ichor.Toolkit.Pratt`: operator-precedence expression parsing

A runtime-mutable table (prefix/infix/postfix operators, any precedence)
plus a driver that climbs it. Complete worked example -- arithmetic with
prefix `-`, infix `+ - * /`, postfix `!` (factorial), and `%` registered
as *both* infix (modulo) and postfix (percent) -- the one genuinely
ambiguous case `can_start_operand?` exists to resolve:

```elixir
alias Ichor.Toolkit.Pratt

table =
  Pratt.new()
  |> Pratt.prefix("-", 100)
  |> Pratt.infix("+", 10)
  |> Pratt.infix("-", 10)
  |> Pratt.infix("*", 20)
  |> Pratt.infix("/", 20)
  |> Pratt.infix("%", 20)
  |> Pratt.postfix("!", 30)
  |> Pratt.postfix("%", 30)

tokens = {{:num, 5}, {:op, "!"}, {:op, "+"}, {:num, 2}} # "5! + 2"

# peek_op must return nil, not crash, once pos runs off the end --
# elem/2 doesn't bounds-check, so every callback goes through this.
at = fn pos -> if pos < tuple_size(tokens), do: elem(tokens, pos), else: nil end

callbacks = %{
  peek_op: fn pos ->
    case at.(pos) do
      {:op, name} -> {name, pos + 1}
      _ -> nil
    end
  end,
  parse_primary: fn pos ->
    case at.(pos) do
      {:num, n} -> {:ok, pos + 1, n}
      _ -> :fail
    end
  end,
  # only needed because "%" is registered both infix and postfix --
  # resolves the ambiguity by checking whether a valid operand follows
  can_start_operand?: fn pos -> match?({:num, _}, at.(pos)) end,
  build: fn
    :prefix, "-", [a] -> -a
    :infix, "+", [a, b] -> a + b
    :infix, "-", [a, b] -> a - b
    :infix, "*", [a, b] -> a * b
    :infix, "/", [a, b] -> a / b
    :infix, "%", [a, b] -> rem(a, b)
    :postfix, "!", [a] -> Enum.reduce(1..a, 1, &*/2)
    :postfix, "%", [a] -> a / 100
  end
}

Pratt.parse(table, 0, callbacks)
#=> {:ok, 4, 122}  -- pos 4 (consumed everything), value 5! + 2 = 122
```

`min_prec` (the optional 4th argument to `parse/4`, default `0`) is what
recursion uses internally to only accept an operator binding at least
that tightly -- pass a higher value yourself if you're embedding a
sub-expression that itself must bind tighter than some enclosing
context.

## `Ichor.Backtrack`: logic-language evaluation (Prolog-style SLD-resolution)

A substitution (`Bindings`) plus a lazy, depth-first search
(`Tree`) over any term representation you supply (`Term`):

```elixir
defmodule MyTerms do
  @behaviour Ichor.Backtrack.Term

  def variable?({:var, _id}), do: true
  def variable?(_), do: false
  def var_id({:var, id}), do: id
  def compound?({:compound, _f, _args}), do: true
  def compound?(_), do: false
  def deconstruct({:compound, f, args}), do: {f, args}
  # optional -- only needed if you ever rebuild a term (substitution):
  def reconstruct(f, args), do: {:compound, f, args}
end

alias Ichor.Backtrack.{Tree, Bindings}

x = {:var, make_ref()}
t1 = {:compound, :father, [:tom, x]}
t2 = {:compound, :father, [:tom, :bob]}

Bindings.unify(MyTerms, Bindings.new(), t1, t2)
#=> {:ok, bindings}  -- x now bound to :bob

Bindings.resolve(MyTerms, bindings, x)
#=> :bob

Bindings.unify_occurs_check(MyTerms, Bindings.new(), x, {:compound, :f, [x]})
#=> :fail  -- unify/4 would instead silently build an infinite term,
#            matching ISO Prolog's own default (unify_with_occurs_check/2
#            is opt-in there too); a type checker generally wants this
```

A goal is a function `bindings -> lazy solution sequence`
(`Tree.unit/0`/`Tree.fail/0` are the two trivial ones; `Tree.disjunction/2`/
`Tree.conjunction/2`/`Tree.once/1` combine goals into bigger ones). A
goal that unifies a query against one fact, tried against a small
"database" via `disjunction/2`:

```elixir
unify_goal = fn fact, query ->
  fn bindings ->
    case Bindings.unify(MyTerms, bindings, query, fact) do
      {:ok, new_bindings} -> Tree.of_one(new_bindings)
      :fail -> Tree.empty()
    end
  end
end

facts = [
  {:compound, :father, [:tom, :bob]},
  {:compound, :father, [:bob, :ann]}
]

query = {:compound, :father, [:tom, {:var, :who}]}

goal =
  facts
  |> Enum.map(&unify_goal.(&1, query))
  |> Enum.reduce(Tree.fail(), &Tree.disjunction/2)

goal.(Bindings.new())
|> Tree.to_list()
|> Enum.map(&Bindings.resolve(MyTerms, &1, {:var, :who}))
#=> [:bob]  -- every solution's own binding for `who`, eagerly collected
#            (Tree.to_list/1 is for tests/finite searches only -- pull
#            one at a time via Tree.next/1 for a search that might not
#            terminate)
```

## `Ichor.Toolkit.TermWalk`: generic recursion over a `Term`

`fold/4` (visit every node, accumulate) and `rewrite/3` (transform every
node, top-down, rebuilding compounds) over any `Ichor.Backtrack.Term`:

```elixir
alias Ichor.Toolkit.TermWalk

term = {:compound, :add, [{:var, :x}, {:compound, :mul, [{:var, :y}, 2]}]}

TermWalk.fold(MyTerms, term, MapSet.new(), fn
  {:var, id}, acc -> MapSet.put(acc, id)
  _other, acc -> acc
end)
#=> MapSet.new([:x, :y])  -- every variable id referenced anywhere in term

TermWalk.rewrite(MyTerms, term, fn
  {:var, :x} -> 10
  other -> other
end)
#=> {:compound, :add, [10, {:compound, :mul, [{:var, :y}, 2]}]}
```

## `Ichor.Toolkit.Result`: fallible-step traversal

```elixir
alias Ichor.Toolkit.Result

Result.reduce_ok([1, 2, 3], 0, fn x, acc -> {:ok, acc + x} end)
#=> {:ok, 6}

Result.reduce_ok([1, -1, 2], 0, fn
  x, _acc when x < 0 -> {:error, "negative: #{x}"}
  x, acc -> {:ok, acc + x}
end)
#=> {:error, "negative: -1"}  -- stops at the first failure

Result.map_ok([1, 2, 3], :state, fn x, state -> {:ok, x * 2, state} end)
#=> {:ok, [2, 4, 6], :state}
```

`reduce_ok/3` passes any non-`{:ok, _}` step result straight through
unexamined -- works equally for a bare `:fail` atom or `{:error, reason}`,
whatever your own step function returns as failure. `map_ok/3` is built
on `reduce_ok/3`.
