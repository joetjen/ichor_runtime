# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- `Ichor.Actions.eval_all/2` could evaluate sibling captures in the
  wrong order (and, for an Actions module implementing custom
  special-form logic that assumes a particular evaluation order, thread
  `context` incorrectly) because it relied on a plain Elixir map's own
  iteration order, which Elixir/Erlang make no guarantee about --
  observed to actually differ between Erlang/OTP versions for the exact
  same code and input.

### Changed

- **Breaking:** raw capture data (`Ichor.Capture.node_t/0`'s `:rule`
  variant, `Ichor.Actions.evaluate/5`'s `raw_captures` argument,
  `Grammar.LRTable.Captures.build/3`'s return value, and
  `Grammar.Native.Runtime.Parser.merge_captures/2`'s accumulator) is now
  an ordered list of `{name, value}` pairs (`Ichor.Capture.raw_captures/0`)
  instead of a plain map, preserving true first-occurrence RHS/source
  order end to end -- the fix for the ordering bug above. A grammar's
  generated Actions module, or any hand-written code that pattern-matches
  or constructs `raw_captures`/`node_t()` values directly (e.g. for
  macro-expansion via `Ichor.Actions.evaluate_node/3`), needs updating
  from `%{name: value}` to `[{name, value}]`/`[name: value]`. The already-
  *evaluated* `Ichor.Actions.captures/0` map handed to `handle_rule/3`
  callbacks is unchanged (still a plain map, keyed for ergonomic access).
- `Ichor.Capture` gained a `position` field (defaults to `0`) recording
  a capture's index among its siblings; `eval_all/2` now sorts by it
  before folding, instead of trusting `captures`' own map order.

## [0.1.0] - 2026-07-29

### Added

- First release, extracted from [`ichor`](https://github.com/joetjen/ichor)'s
  own monorepo (`packages/ichor_runtime`, via `git subtree split` -- this
  repository's history starts with the commits that originally added
  that directory) into its own independently-published-and-maintained
  project. ~24 modules: everything a `mix ichor.gen`-generated parser
  (or `use Ichor`-compiled module) actually calls at runtime, plus three
  self-contained toolkit modules useful to an engine built on top of
  one:
  - Capture dispatch: `Ichor.Actions`, `Ichor.Capture`, `Ichor.Node`,
    `Ichor.Error`.
  - The compiled Tokenizer/Parser runtime:
    `Grammar.Native.Runtime.Parser`/`Tokenizer`, `Grammar.VM.Token`,
    `Grammar.Source`, `Grammar.Lexer`.
  - The LR/GLR runtime: `Grammar.LRTable`, `Grammar.LRTable.Production`/
    `.Captures`, `Grammar.LR.Stack`, `Grammar.GLR.GSS`/`.Runtime`.
  - `@native(...)` callback behaviours: `Ichor.CustomLexeme`,
    `Ichor.CustomRule`.
  - Standalone toolkit: `Ichor.Toolkit.Pratt` (precedence-climbing
    expression parsing), `Ichor.Toolkit.TermWalk` (generic `fold`/
    `rewrite` recursion), `Ichor.Backtrack` (+ `.Bindings`/`.Term`/
    `.Tree`, a lazy-search-plus-unification substrate for
    logic-language evaluation models), `Ichor.Toolkit.Result`
    (`reduce_ok`/`map_ok`).

[Unreleased]: https://github.com/joetjen/ichor_runtime/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/joetjen/ichor_runtime/releases/tag/v0.1.0
