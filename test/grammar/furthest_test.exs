defmodule Grammar.FurthestTest do
  use ExUnit.Case, async: true

  alias Grammar.Furthest

  doctest Grammar.Furthest

  defp token(name, text, column),
    do: %Grammar.VM.Token{name: name, text: text, line: 1, column: column}

  describe "the record" do
    test "keeps the furthest position a token match failed at, and every token wanted there" do
      previous = Furthest.start()
      Furthest.failed(1, :A)
      Furthest.failed(3, :B)
      Furthest.failed(3, :C)
      Furthest.failed(2, :D)
      assert Furthest.finish(previous) == {3, MapSet.new([:B, :C])}
    end

    test "ignores what fails inside a lookahead" do
      previous = Furthest.start()
      Furthest.failed(1, :A)
      Furthest.enter_predicate()
      Furthest.failed(5, :STR)
      Furthest.exit_predicate()
      Furthest.failed(1, :B)
      assert Furthest.finish(previous) == {1, MapSet.new([:A, :B])}
    end

    test "is empty when nothing failed" do
      previous = Furthest.start()
      assert Furthest.finish(previous) == {-1, MapSet.new()}
    end

    # A custom lexeme re-lexes a suffix of the input inside a parse; its
    # own parse must not disturb the outer one's record.
    test "a parse nested inside another leaves the outer record as it was" do
      outer = Furthest.start()
      Furthest.failed(4, :A)

      inner = Furthest.start()
      Furthest.failed(9, :Z)
      assert Furthest.finish(inner) == {9, MapSet.new([:Z])}

      Furthest.failed(4, :B)
      assert Furthest.finish(outer) == {4, MapSet.new([:A, :B])}
    end

    test "outside a parse, a failure is ignored" do
      assert Furthest.failed(1, :A) == :ok
      assert Process.get({Furthest, :record}) == nil
    end
  end

  describe "error/6" do
    setup do
      %{stream: {token(:NAME, "a", 1), token(:INT, "1", 3)}, input: "a 1"}
    end

    test "is placed at the furthest token, naming what was found and wanted", ctx do
      error =
        Furthest.error(
          {1, MapSet.new([:COLON, :EQ])},
          ctx.stream,
          ctx.input,
          nil,
          nil,
          &Atom.to_string/1
        )

      assert {error.line, error.column} == {1, 3}
      assert error.message == ~s(unexpected "1" -- expected one of: COLON, EQ)
      assert {error.found, error.expected} == {"1", ["COLON", "EQ"]}
    end

    test "past the last token is unexpected end of input", ctx do
      error =
        Furthest.error(
          {2, MapSet.new([:INT])},
          ctx.stream,
          ctx.input,
          nil,
          nil,
          &Atom.to_string/1
        )

      assert {error.message, error.found, error.column} ==
               {"unexpected end of input -- expected INT", :eof, 4}
    end

    test "never names the skip token", ctx do
      error =
        Furthest.error(
          {1, MapSet.new([:WS, :INT])},
          ctx.stream,
          ctx.input,
          nil,
          :WS,
          &Atom.to_string/1
        )

      assert error.expected == ["INT"]
    end

    test "is nil when nothing was wanted, or left-over input is further", ctx do
      assert Furthest.error(
               {-1, MapSet.new()},
               ctx.stream,
               ctx.input,
               nil,
               nil,
               &Atom.to_string/1
             ) == nil

      assert Furthest.error(
               {0, MapSet.new([:A])},
               ctx.stream,
               ctx.input,
               1,
               nil,
               &Atom.to_string/1
             ) == nil
    end
  end
end
