defmodule Grammar.Source.LocatorTest do
  use ExUnit.Case, async: true

  alias Grammar.Source.Locator

  defp token(name, text, line, column),
    do: %Grammar.VM.Token{name: name, text: text, line: line, column: column}

  # `%{a: 1\n 1.5 => 2}` lexed without its skip tokens, as an LR stream is.
  defp map_stream do
    {token(:"%{", "%{", 1, 1), token(:IDENT, "a", 1, 3), token(:":", ":", 1, 4),
     token(:INT, "1", 1, 6), token(:FLOAT, "1.5", 2, 2), token(:"=>", "=>", 2, 6),
     token(:INT, "2", 2, 9), token(:"}", "}", 2, 10)}
  end

  @map_input "%{a: 1\n 1.5 => 2}"

  describe "span/3" do
    test "a single token is where it starts, as long as its text" do
      locator = Locator.new(map_stream(), @map_input)
      assert Locator.span(locator, 4, 5) == {2, 2, 3}
    end

    test "a range runs from its first token's start to its last token's end" do
      locator = Locator.new(map_stream(), @map_input)
      assert Locator.span(locator, 4, 7) == {2, 2, 8}
    end

    test "a range across lines counts the line break and the text skipped between tokens" do
      locator = Locator.new(map_stream(), @map_input)
      assert Locator.span(locator, 0, 8) == {1, 1, String.length(@map_input)}
    end

    test "an empty range is where the next token starts, with length 0" do
      locator = Locator.new(map_stream(), @map_input)
      assert Locator.span(locator, 4, 4) == {2, 2, 0}
    end

    test "an empty range past the last token is the end of the input" do
      locator = Locator.new(map_stream(), @map_input)
      assert Locator.span(locator, 8, 8) == {2, 11, 0}
    end

    test "columns and lengths count codepoints, as the tokenizer does" do
      stream = {token(:WORD, "été", 1, 1), token(:WORD, "ça", 1, 5)}
      locator = Locator.new(stream, "été ça")
      assert Locator.span(locator, 1, 2) == {1, 5, 2}
      assert Locator.span(locator, 0, 2) == {1, 1, 6}
    end

    test "no input at all is 1:1" do
      assert Locator.span(Locator.new({}, ""), 0, 0) == {1, 1, 0}
    end
  end
end
