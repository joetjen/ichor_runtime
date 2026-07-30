defmodule Grammar.Native.Runtime.ParserTest do
  use ExUnit.Case, async: true

  alias Grammar.Native.Runtime.Parser
  alias Grammar.VM.Token

  defp tok(name, text, opts \\ []) do
    %Token{name: name, text: text, line: 1, column: Keyword.get(opts, :column, 1)}
  end

  # A rule_fun that matches a single token by name at `pos`, capturing it
  # under `cap_name` -- the minimal building block every test below composes.
  defp match(name, cap_name) do
    fn stream, pos, ref_stack, _context ->
      case Parser.token_at(stream, pos) do
        %Token{name: ^name} = t ->
          {:ok, pos + 1, ref_stack, %{cap_name => {:token, name, t.text}}}

        _ ->
          :fail
      end
    end
  end

  defp always_fail, do: fn _stream, _pos, _ref_stack, _context -> :fail end

  describe "merge_captures/2" do
    test "a new key is added as-is" do
      assert Parser.merge_captures(%{}, %{a: 1}) == %{a: 1}
    end

    test "two scalar occurrences of the same key become a list" do
      assert Parser.merge_captures(%{a: 1}, %{a: 2}) == %{a: [1, 2]}
    end

    test "merging a list-valued key against a scalar flattens, not nests" do
      assert Parser.merge_captures(%{a: [1, 2]}, %{a: 3}) == %{a: [1, 2, 3]}
      assert Parser.merge_captures(%{a: 1}, %{a: [2, 3]}) == %{a: [1, 2, 3]}
      assert Parser.merge_captures(%{a: [1, 2]}, %{a: [3, 4]}) == %{a: [1, 2, 3, 4]}
    end

    test "unrelated keys from both maps survive independently" do
      assert Parser.merge_captures(%{a: 1}, %{b: 2}) == %{a: 1, b: 2}
    end
  end

  describe "try_alts/5" do
    test "an empty alternative list fails" do
      assert Parser.try_alts([], {}, 0, [0], nil) == :fail
    end

    test "the first matching alternative wins, later ones never tried" do
      stream = {tok(:A, "a")}
      poison = fn _s, _p, _r, _c -> raise "should never be called" end

      assert {:ok, 1, [0], %{x: {:token, :A, "a"}}} =
               Parser.try_alts([match(:A, :x), poison], stream, 0, [0], nil)
    end

    test "falls through to a later alternative when an earlier one fails" do
      stream = {tok(:B, "b")}

      assert {:ok, 1, [0], %{x: {:token, :B, "b"}}} =
               Parser.try_alts([match(:A, :x), match(:B, :x)], stream, 0, [0], nil)
    end

    test "fails when every alternative fails" do
      stream = {tok(:C, "c")}
      assert Parser.try_alts([match(:A, :x), match(:B, :x)], stream, 0, [0], nil) == :fail
    end
  end

  describe "star/6" do
    test "zero matches: a zero-width success, no captures" do
      stream = {}
      assert Parser.star(always_fail(), stream, 0, [0], nil) == {:ok, 0, [0], %{}}
    end

    test "greedily consumes every match, merging captures into a list" do
      stream = {tok(:A, "1"), tok(:A, "2"), tok(:B, "stop")}

      assert {:ok, 2, [0], %{x: [{:token, :A, "1"}, {:token, :A, "2"}]}} =
               Parser.star(match(:A, :x), stream, 0, [0], nil)
    end

    test "a zero-width match is incorporated once, then the loop stops (no infinite loop)" do
      zero_width = fn stream, pos, ref_stack, _context ->
        case Parser.token_at(stream, pos) do
          %Token{name: :A} -> {:ok, pos, ref_stack, %{seen: true}}
          _ -> :fail
        end
      end

      stream = {tok(:A, "a")}

      assert {:ok, 0, [0], %{seen: true}} = Parser.star(zero_width, stream, 0, [0], nil)
    end
  end

  describe "plus/5" do
    test "fails outright if the first match fails" do
      assert Parser.plus(always_fail(), {}, 0, [0], nil) == :fail
    end

    test "one mandatory match, then star/6 for the rest" do
      stream = {tok(:A, "1"), tok(:A, "2")}

      assert {:ok, 2, [0], %{x: [{:token, :A, "1"}, {:token, :A, "2"}]}} =
               Parser.plus(match(:A, :x), stream, 0, [0], nil)
    end
  end

  describe "opt/5" do
    test "passes through a real match unchanged" do
      stream = {tok(:A, "a")}

      assert {:ok, 1, [0], %{x: {:token, :A, "a"}}} =
               Parser.opt(match(:A, :x), stream, 0, [0], nil)
    end

    test "on failure: zero-width success, no captures" do
      assert Parser.opt(always_fail(), {tok(:B, "b")}, 0, [0], nil) == {:ok, 0, [0], %{}}
    end
  end

  describe "call_n_times/6" do
    test "n = 0 succeeds immediately, no captures, fun never called" do
      assert Parser.call_n_times(always_fail(), 0, {}, 0, [0], nil) == {:ok, 0, [0], %{}}
    end

    test "chains n calls, merging captures in order" do
      stream = {tok(:A, "1"), tok(:A, "2"), tok(:A, "3")}

      assert {:ok, 3, [0], %{x: [{:token, :A, "1"}, {:token, :A, "2"}, {:token, :A, "3"}]}} =
               Parser.call_n_times(match(:A, :x), 3, stream, 0, [0], nil)
    end

    test "fails outward if any of the n calls fails" do
      stream = {tok(:A, "1"), tok(:B, "2")}
      assert Parser.call_n_times(match(:A, :x), 2, stream, 0, [0], nil) == :fail
    end
  end

  describe "rep/7 (bounded {min,max})" do
    test "min mandatory, up to max total" do
      stream = {tok(:A, "1"), tok(:A, "2"), tok(:A, "3"), tok(:B, "stop")}

      assert {:ok, 2, [0], %{x: [{:token, :A, "1"}, {:token, :A, "2"}]}} =
               Parser.rep(match(:A, :x), 1, 2, stream, 0, [0], nil)
    end

    test "fails if fewer than min matches are available" do
      stream = {tok(:A, "1")}
      assert Parser.rep(match(:A, :x), 2, 3, stream, 0, [0], nil) == :fail
    end
  end

  describe "rep/7 (min, :infinity)" do
    test "min mandatory, then unbounded (like plus/5 with a floor)" do
      stream = {tok(:A, "1"), tok(:A, "2"), tok(:A, "3")}

      assert {:ok, 3, [0], %{x: [{:token, :A, "1"}, {:token, :A, "2"}, {:token, :A, "3"}]}} =
               Parser.rep(match(:A, :x), 1, :infinity, stream, 0, [0], nil)
    end

    test "fails if fewer than min matches are available" do
      assert Parser.rep(match(:A, :x), 1, :infinity, {}, 0, [0], nil) == :fail
    end
  end

  describe "match_token/3" do
    test "matches a token by name, advancing by one, returning its text and capture override" do
      stream = {tok(:A, "hi")}
      assert Parser.match_token(stream, 0, :A) == {:ok, 1, "hi", nil}
    end

    test "carries a CustomLexeme-attached capture override through" do
      stream = {%Token{name: :A, text: "hi", line: 1, column: 1, capture: {:text, "override"}}}
      assert Parser.match_token(stream, 0, :A) == {:ok, 1, "hi", {:text, "override"}}
    end

    test "fails on a name mismatch" do
      stream = {tok(:A, "hi")}
      assert Parser.match_token(stream, 0, :B) == :fail
    end

    test "fails past the end of the stream" do
      assert Parser.match_token({}, 0, :A) == :fail
    end
  end

  describe "and_pred/5 and not_pred/5" do
    test "and_pred succeeds without consuming when the inner rule matches" do
      stream = {tok(:A, "a")}
      assert Parser.and_pred(match(:A, :x), stream, 0, [0], nil) == {:ok, 0, [0], %{}}
    end

    test "and_pred fails when the inner rule fails" do
      assert Parser.and_pred(always_fail(), {}, 0, [0], nil) == :fail
    end

    test "not_pred fails when the inner rule matches" do
      stream = {tok(:A, "a")}
      assert Parser.not_pred(match(:A, :x), stream, 0, [0], nil) == :fail
    end

    test "not_pred succeeds without consuming when the inner rule fails" do
      assert Parser.not_pred(always_fail(), {}, 0, [0], nil) == {:ok, 0, [0], %{}}
    end
  end

  describe "indent_enter/5 (@indent)" do
    test "succeeds and pops its own column back off when deeper than the enclosing reference" do
      stream = {tok(:A, "a", column: 5)}
      body = fn s, p, ref_stack, c -> match(:A, :x).(s, p, ref_stack, c) end

      assert {:ok, 1, [0], %{x: {:token, :A, "a"}}} =
               Parser.indent_enter(body, stream, 0, [0], nil)
    end

    test "fails when not deeper than the enclosing reference column" do
      stream = {tok(:A, "a", column: 3)}
      assert Parser.indent_enter(match(:A, :x), stream, 0, [3], nil) == :fail
    end

    test "fails at end of stream (no token to read a column from)" do
      assert Parser.indent_enter(match(:A, :x), {}, 0, [0], nil) == :fail
    end
  end

  describe "samecol_check/5 (@samecol)" do
    test "succeeds when the token's column exactly matches the reference" do
      stream = {tok(:A, "a", column: 3)}

      assert {:ok, 1, [3], %{x: {:token, :A, "a"}}} =
               Parser.samecol_check(match(:A, :x), stream, 0, [3], nil)
    end

    test "fails when the column doesn't match" do
      stream = {tok(:A, "a", column: 4)}
      assert Parser.samecol_check(match(:A, :x), stream, 0, [3], nil) == :fail
    end

    test "fails at end of stream" do
      assert Parser.samecol_check(match(:A, :x), {}, 0, [0], nil) == :fail
    end
  end

  describe "token_at/2" do
    test "returns the token at a valid position" do
      t = tok(:A, "a")
      assert Parser.token_at({t}, 0) == t
    end

    test "returns nil past the end of the stream" do
      assert Parser.token_at({tok(:A, "a")}, 1) == nil
      assert Parser.token_at({}, 0) == nil
    end
  end

  describe "concat_text/3" do
    test "concatenates the raw text of every token in the half-open range" do
      stream = {tok(:A, "foo"), tok(:B, "bar"), tok(:C, "baz")}
      assert Parser.concat_text(stream, 0, 2) == "foobar"
      assert Parser.concat_text(stream, 0, 3) == "foobarbaz"
    end

    test "an empty range concatenates to an empty string" do
      stream = {tok(:A, "foo")}
      assert Parser.concat_text(stream, 0, 0) == ""
    end
  end

  describe "skip_leading_trivia/3" do
    test "nil skip_name (a @noskip grammar) leaves pos unchanged" do
      stream = {tok(:SPACE, " ")}
      assert Parser.skip_leading_trivia(stream, 0, nil) == 0
    end

    test "skips every leading occurrence of skip_name" do
      stream = {tok(:SPACE, " "), tok(:SPACE, " "), tok(:A, "a")}
      assert Parser.skip_leading_trivia(stream, 0, :SPACE) == 2
    end

    test "stops at the first non-matching token" do
      stream = {tok(:A, "a"), tok(:SPACE, " ")}
      assert Parser.skip_leading_trivia(stream, 0, :SPACE) == 0
    end

    test "stops cleanly at end of stream" do
      stream = {tok(:SPACE, " ")}
      assert Parser.skip_leading_trivia(stream, 0, :SPACE) == 1
    end
  end

  describe "unexpected_token_error/3" do
    test "names the offending token, at its own line/column, with source context" do
      stream = {%Token{name: :PLUS, text: "+", line: 2, column: 5}}
      error = Parser.unexpected_token_error(stream, 0, "a\n    +")

      assert error.stage == :parser
      assert error.line == 2
      assert error.column == 5
      assert error.message =~ ~s("+")
    end
  end
end
