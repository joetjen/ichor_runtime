defmodule Grammar.SourceTest do
  use ExUnit.Case, async: true

  alias Grammar.Source

  test "valid UTF-8 passes through unchanged" do
    assert Source.validate("hello, ééé") == {:ok, "hello, ééé"}
  end

  test "an empty string is valid" do
    assert Source.validate("") == {:ok, ""}
  end

  test "invalid UTF-8 is rejected with a lexer-stage error" do
    invalid = <<"abc"::binary, 0xFF, "def"::binary>>
    assert {:error, %Ichor.Error{stage: :lexer, message: message}} = Source.validate(invalid)
    assert message =~ "not valid UTF-8"
  end

  defp token(name, text, line, column),
    do: %Grammar.VM.Token{name: name, text: text, line: line, column: column}

  describe "trimmed/2" do
    test "drops the skip tokens before the first token and after the last" do
      tokens = [
        token(:SPACE, " ", 1, 1),
        token(:NUMBER, "1", 1, 2),
        token(:SPACE, " ", 1, 3),
        token(:NUMBER, "2", 1, 4),
        token(:SPACE, "\n", 1, 5)
      ]

      assert Source.trimmed(tokens, :SPACE) == Enum.slice(tokens, 1, 3)
    end

    test "keeps the skip tokens between two others" do
      tokens = [token(:NUMBER, "1", 1, 1), token(:SPACE, " ", 1, 2), token(:NUMBER, "2", 1, 3)]
      assert Source.trimmed(tokens, :SPACE) == tokens
    end

    test "leaves nothing of a stream that is only skip tokens" do
      assert Source.trimmed([token(:SPACE, "  ", 1, 1)], :SPACE) == []
    end

    test "changes nothing for a grammar with no skip token" do
      tokens = [token(:SPACE, " ", 1, 1)]
      assert Source.trimmed(tokens, nil) == tokens
    end
  end

  describe "significant/2" do
    test "drops every skip token, between two others too" do
      tokens = [
        token(:SPACE, " ", 1, 1),
        token(:NUMBER, "1", 1, 2),
        token(:SPACE, " ", 1, 3),
        token(:NUMBER, "2", 1, 4),
        token(:SPACE, "\n", 1, 5)
      ]

      assert Source.significant(tokens, :SPACE) == [Enum.at(tokens, 1), Enum.at(tokens, 3)]
    end

    test "changes nothing for a grammar with no skip token" do
      tokens = [token(:SPACE, " ", 1, 1)]
      assert Source.significant(tokens, nil) == tokens
    end
  end

  describe "position/3" do
    test "is where the token at pos starts" do
      stream = {token(:NUMBER, "1", 1, 1), token(:PLUS, "+", 2, 3)}
      assert Source.position(stream, 1, "1\n  +") == {2, 3}
    end

    test "past the last token is the end of the input" do
      assert Source.position({token(:NUMBER, "1", 1, 1)}, 1, "1 +\n22") == {2, 3}
    end

    test "of no input at all is the first line and column" do
      assert Source.position({}, 0, "") == {1, 1}
    end

    test "counts a column per codepoint, not per byte" do
      assert Source.position({}, 0, "éé") == {1, 3}
    end
  end

  describe "placed/2" do
    test "puts an error that says nowhere at the end of the input" do
      error = Ichor.Error.new(message: "unexpected end of input", stage: :parser)
      assert {Source.placed(error, "1 +\n").line, Source.placed(error, "1 +\n").column} == {2, 1}
    end

    test "leaves where an error that says where is" do
      error = Ichor.Error.new(message: "x", stage: :parser, line: 1, column: 2)
      placed = Source.placed(error, "abc")
      assert {placed.line, placed.column, placed.message} == {1, 2, "x"}
    end

    test "places each error of a list" do
      error = Ichor.Error.new(message: "x", stage: :parser)
      assert [%{line: 1, column: 1}] = Source.placed([error], "")
    end
  end

  describe "placed/2: every error shows where" do
    test "gives an error with a position but no snippet the line it is on" do
      error = Ichor.Error.new(message: "unexpected \"+\"", stage: :parser, line: 1, column: 3)
      placed = Source.placed(error, "1++2")
      assert placed.context_lines == "1 | 1++2\n  |   ^"
      assert Ichor.Error.format(placed) == "1:3: unexpected \"+\"\n1 | 1++2\n  |   ^"
    end

    test "and one at the end of the input the end of its last line" do
      error = Ichor.Error.new(message: "unexpected end of input", stage: :parser)

      assert Ichor.Error.format(Source.placed(error, "1+")) ==
               "1:3: unexpected end of input\n1 | 1+\n  |   ^"
    end

    test "keeps an error's data when it gives it its line" do
      error = Ichor.Error.new(message: "x", stage: :parser, line: 1, column: 2, data: :mine)

      assert Source.placed(error, "ab").data == :mine
    end

    test "leaves a snippet an error already has as it is" do
      error =
        Ichor.Error.new(message: "x", stage: :parser, line: 1, column: 1, context_lines: "given")

      assert Source.placed(error, "abc").context_lines == "given"
    end
  end
end
