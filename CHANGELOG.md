# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
