defmodule IchorRuntime.MixProject do
  use Mix.Project

  @version "0.6.0"

  # `mix precommit` includes `test` as a step; without this, Mix runs
  # the whole alias chain (including `mix test`) in :dev, and `mix test`
  # itself refuses to run outside :test when invoked as a sub-task
  # rather than the top-level command.
  def cli do
    [preferred_envs: [precommit: :test]]
  end

  def project do
    [
      app: :ichor_runtime,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: description(),
      package: package(),
      name: "IchorRuntime",
      docs: docs(),
      aliases: aliases(),
      test_coverage: [tool: ExCoveralls],
      dialyzer: [plt_add_apps: [:mix]]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      # === CODE QUALITY & STATIC ANALYSIS ===
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test], runtime: false},
      # Credo is invoked via `mix credo`
      # Dialyzer is invoked via `mix dialyzer`
      # Sobelow is invoked via `mix sobelow`

      # === TESTING ===
      {:mox, "~> 1.2", only: [:dev, :test]},
      {:faker, "~> 0.19", only: [:test]},
      {:stream_data, "~> 1.4", only: [:test]},

      # === DEVELOPMENT TOOLING ===
      # Mix, and Hex are built-in (no deps needed)
      {:ex_doc, "~> 0.40", only: [:dev], runtime: false}
      # ExDoc is invoked via `mix docs`

      # === RUNTIME ===
    ]
  end

  # Fast/cheap checks first so a broken commit fails quickly; dialyzer
  # (slowest, especially its first PLT build) runs last.
  defp aliases do
    [
      docs: [&readme_for_docs/1, "docs"],
      precommit: [
        "format",
        "compile --warnings-as-errors",
        "credo --strict",
        "sobelow",
        "test",
        "dialyzer"
      ]
    ]
  end

  # The README for ExDoc: GitHub's `> [!WARNING]` alert, which ExDoc does
  # not render, turned into ExDoc's own warning admonition. GitHub shows
  # the README itself; HexDocs shows this copy under the same name. Run
  # through the `docs` alias, which `mix hex.publish` builds through too.
  # The same in every Elixir Ichor, Cooper and Dextrin.
  defp readme_for_docs(_args) do
    File.mkdir_p!("doc_src")

    readme =
      "README.md"
      |> File.read!()
      |> String.replace("> [!WARNING]", "> #### Warning {: .warning}")

    File.write!("doc_src/README.md", readme)
  end

  defp description do
    "Under heavy development: not for production use before 1.0.0. " <>
      "Runtime support for Ichor-generated parsers: capture dispatch, error formatting, " <>
      "tokenizer and parser combinators, the LR/GLR runtime, Pratt precedence parsing, " <>
      "term recursion and unification/backtracking. Ichor itself is dev-only."
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/joetjen/ichor_runtime"},
      files: ~w(lib .formatter.exs mix.exs README.md CHEATSHEET.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: "https://github.com/joetjen/ichor_runtime",
      source_ref: "v#{@version}",
      # docs.yml publishes this same output to GitHub Pages (latest `main`,
      # ahead of releases); point search engines at the released hexdocs
      # copy instead so the two don't compete as duplicate content.
      canonical: "https://hexdocs.pm/ichor_runtime",
      # The README as `readme_for_docs/1` rewrites it, so its warning is a
      # box: same page name, same URL.
      extras: [
        {"doc_src/README.md", filename: "readme", source: "README.md"},
        "CHEATSHEET.md",
        "CHANGELOG.md",
        "LICENSE"
      ],
      groups_for_modules: groups_for_modules()
    ]
  end

  defp groups_for_modules do
    [
      "Capture Dispatch": [
        Ichor.Actions,
        Ichor.Capture,
        Ichor.Node,
        Ichor.CustomLexeme,
        Ichor.CustomRule
      ],
      Errors: [
        Ichor.Error
      ],
      "Lexing/Parsing Support": [
        Grammar.VM.Token,
        Grammar.Source,
        Grammar.Lexer,
        Grammar.Native.Runtime.Parser,
        Grammar.Native.Runtime.Tokenizer
      ],
      "LR/GLR Runtime": [
        Grammar.LRTable,
        Grammar.LRTable.Production,
        Grammar.LRTable.Captures,
        Grammar.LR.Stack,
        Grammar.GLR.GSS,
        Grammar.GLR.Runtime
      ],
      Backtrack: [
        Ichor.Backtrack,
        Ichor.Backtrack.Bindings,
        Ichor.Backtrack.Term,
        Ichor.Backtrack.Tree
      ],
      Toolkit: [
        Ichor.Toolkit.Result,
        Ichor.Toolkit.Pratt,
        Ichor.Toolkit.TermWalk
      ]
    ]
  end
end
