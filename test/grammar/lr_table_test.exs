defmodule Grammar.LRTableTest do
  use ExUnit.Case, async: true

  alias Grammar.LRTable
  alias Grammar.VM.Token

  # Grammar.LRTable.Builder (in ichor proper) owns build/1 and
  # conflicts/1, exercised there against real grammars -- these two
  # functions are the only part of the module that ships here, so
  # that's the only part tested here, standalone against a hand-built
  # token stream.

  describe "current_terminal/3" do
    test "the current token's own name" do
      stream = {%Token{name: :PLUS, text: "+", line: 1, column: 1}}
      assert LRTable.current_terminal(stream, 0, :"$end") == :PLUS
    end

    test "end_symbol once input is exhausted" do
      stream = {%Token{name: :PLUS, text: "+", line: 1, column: 1}}
      assert LRTable.current_terminal(stream, 1, :"$end") == :"$end"
    end
  end

  describe "unexpected_error/2" do
    test "names the offending token" do
      stream = {%Token{name: :PLUS, text: "+", line: 1, column: 1}}
      error = LRTable.unexpected_error(stream, 0)
      assert error.stage == :parser
      assert error.message =~ ~s("+")
    end

    test "reports end of input once the stream is exhausted" do
      stream = {%Token{name: :PLUS, text: "+", line: 1, column: 1}}
      error = LRTable.unexpected_error(stream, 1)
      assert error.message =~ "end of input"
    end
  end

  describe "unexpected_error/3" do
    test "places end of input at the end of the input" do
      stream = {%Token{name: :PLUS, text: "+", line: 1, column: 1}}
      error = LRTable.unexpected_error(stream, 1, "+ \n ")
      assert {error.message, error.line, error.column} == {"unexpected end of input", 2, 2}
    end

    test "places no input at all at the first line and column" do
      error = LRTable.unexpected_error({}, 0, "")
      assert {error.line, error.column} == {1, 1}
    end

    test "names and places the offending token as unexpected_error/2 does" do
      stream = {%Token{name: :PLUS, text: "+", line: 3, column: 4}}
      error = LRTable.unexpected_error(stream, 0, "...")
      assert {error.line, error.column} == {3, 4}
      assert error.message =~ ~s("+")
    end
  end
end
