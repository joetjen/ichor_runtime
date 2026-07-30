defmodule Grammar.Native.Runtime.TokenizerTest do
  use ExUnit.Case, async: true

  alias Grammar.Native.Runtime.Tokenizer
  alias Grammar.VM.Token

  # A char_fun matching exactly one occurrence of `char`.
  defp lit(char) do
    fn
      <<^char::binary-size(1), rest::binary>> -> {:ok, char, rest}
      _ -> :fail
    end
  end

  defp always_fail_char, do: fn _input -> :fail end

  describe "in_ranges?/2" do
    test "true when the codepoint falls in any range" do
      assert Tokenizer.in_ranges?(?5, [{?0, ?9}])
      assert Tokenizer.in_ranges?(?a, [{?0, ?9}, {?a, ?z}])
    end

    test "false when it falls in none" do
      refute Tokenizer.in_ranges?(?A, [{?0, ?9}, {?a, ?z}])
    end
  end

  describe "first_char_match/2" do
    test "fails on an empty candidate list" do
      assert Tokenizer.first_char_match([], "x") == :fail
    end

    test "returns the first match, later candidates never tried" do
      poison = fn _input -> raise "should never be called" end
      assert Tokenizer.first_char_match([lit("a"), poison], "abc") == {:ok, "a", "bc"}
    end

    test "falls through to a later candidate when an earlier one fails" do
      assert Tokenizer.first_char_match([lit("a"), lit("b")], "bc") == {:ok, "b", "c"}
    end

    test "fails when every candidate fails" do
      assert Tokenizer.first_char_match([lit("a"), lit("b")], "cd") == :fail
    end
  end

  describe "star_char/3" do
    test "zero matches: succeeds with an empty accumulated string, input untouched" do
      assert Tokenizer.star_char(always_fail_char(), "xyz") == {:ok, "", "xyz"}
    end

    test "greedily consumes every match" do
      assert Tokenizer.star_char(lit("a"), "aaab") == {:ok, "aaa", "b"}
    end

    test "a zero-width match doesn't loop forever -- incorporated once, then stops" do
      zero_width = fn input -> {:ok, "", input} end
      assert Tokenizer.star_char(zero_width, "abc") == {:ok, "", "abc"}
    end
  end

  describe "plus_char/2" do
    test "fails if there's no first match" do
      assert Tokenizer.plus_char(lit("a"), "bbb") == :fail
    end

    test "one mandatory match, then star_char/3 for the rest" do
      assert Tokenizer.plus_char(lit("a"), "aab") == {:ok, "aa", "b"}
    end
  end

  describe "opt_char/2" do
    test "passes a real match through unchanged" do
      assert Tokenizer.opt_char(lit("a"), "abc") == {:ok, "a", "bc"}
    end

    test "on failure: zero-width success, input untouched" do
      assert Tokenizer.opt_char(lit("a"), "xyz") == {:ok, "", "xyz"}
    end
  end

  describe "call_n_times_char/3" do
    test "n = 0 succeeds immediately with an empty string" do
      assert Tokenizer.call_n_times_char(always_fail_char(), 0, "abc") == {:ok, "", "abc"}
    end

    test "chains n matches, concatenating their text in order" do
      assert Tokenizer.call_n_times_char(lit("a"), 3, "aaab") == {:ok, "aaa", "b"}
    end

    test "fails if fewer than n matches are available" do
      assert Tokenizer.call_n_times_char(lit("a"), 3, "aab") == :fail
    end
  end

  describe "rep_char/4 (bounded {min,max})" do
    test "min mandatory, up to max total" do
      assert Tokenizer.rep_char(lit("a"), 1, 2, "aaab") == {:ok, "aa", "ab"}
    end

    test "fails if fewer than min matches are available" do
      assert Tokenizer.rep_char(lit("a"), 2, 3, "ab") == :fail
    end
  end

  describe "rep_char/4 (min, :infinity)" do
    test "min mandatory, then unbounded" do
      assert Tokenizer.rep_char(lit("a"), 1, :infinity, "aaab") == {:ok, "aaa", "b"}
    end

    test "fails if fewer than min matches are available" do
      assert Tokenizer.rep_char(lit("a"), 1, :infinity, "b") == :fail
    end
  end

  describe "and_pred_char/2 and not_pred_char/2" do
    test "and_pred_char succeeds without consuming when the inner match succeeds" do
      assert Tokenizer.and_pred_char(lit("a"), "abc") == {:ok, "", "abc"}
    end

    test "and_pred_char fails when the inner match fails" do
      assert Tokenizer.and_pred_char(lit("a"), "xyz") == :fail
    end

    test "not_pred_char fails when the inner match succeeds" do
      assert Tokenizer.not_pred_char(lit("a"), "abc") == :fail
    end

    test "not_pred_char succeeds without consuming when the inner match fails" do
      assert Tokenizer.not_pred_char(lit("a"), "xyz") == {:ok, "", "xyz"}
    end
  end

  describe "pick_longest/1" do
    test "fails when every candidate fails or is empty" do
      assert Tokenizer.pick_longest([]) == :fail
      assert Tokenizer.pick_longest([{:A, fn -> :fail end}]) == :fail
    end

    test "a zero-width match never wins, even alone" do
      assert Tokenizer.pick_longest([{:A, fn -> {:ok, "", "rest", nil} end}]) == :fail
    end

    test "the strictly-longer candidate wins regardless of declaration order" do
      candidates = [
        {:SHORT, fn -> {:ok, "a", "bc", nil} end},
        {:LONG, fn -> {:ok, "ab", "c", nil} end}
      ]

      assert Tokenizer.pick_longest(candidates) == {:ok, :LONG, "ab", "c", nil}
    end

    test "a tie keeps the earlier-declared candidate" do
      candidates = [
        {:FIRST, fn -> {:ok, "ab", "c", nil} end},
        {:SECOND, fn -> {:ok, "xy", "z", nil} end}
      ]

      assert Tokenizer.pick_longest(candidates) == {:ok, :FIRST, "ab", "c", nil}
    end

    test "carries a CustomLexeme capture override through" do
      candidates = [{:A, fn -> {:ok, "a", "", {:text, "override"}} end}]
      assert Tokenizer.pick_longest(candidates) == {:ok, :A, "a", "", {:text, "override"}}
    end
  end

  describe "tokenize/2" do
    defp candidates_for(input) do
      [
        {:WORD, fn -> Tokenizer.plus_char(lit_alpha(), input) |> as_candidate() end},
        {:SPACE, fn -> Tokenizer.plus_char(lit(" "), input) |> as_candidate() end}
      ]
    end

    defp lit_alpha do
      fn
        <<c::utf8, rest::binary>> when c in ?a..?z -> {:ok, <<c::utf8>>, rest}
        _ -> :fail
      end
    end

    defp as_candidate({:ok, text, rest}), do: {:ok, text, rest, nil}
    defp as_candidate(:fail), do: :fail

    test "tokenizes the whole input, tracking line/column" do
      assert {:ok, [%Token{} = w1, %Token{} = sp, %Token{} = w2]} =
               Tokenizer.tokenize(&candidates_for/1, "ab cd")

      assert {w1.name, w1.text, w1.line, w1.column} == {:WORD, "ab", 1, 1}
      assert {sp.name, sp.text, sp.line, sp.column} == {:SPACE, " ", 1, 3}
      assert {w2.name, w2.text, w2.line, w2.column} == {:WORD, "cd", 1, 4}
    end

    test "an empty input tokenizes to an empty list" do
      assert Tokenizer.tokenize(&candidates_for/1, "") == {:ok, []}
    end

    test "reports the first position nothing matches, with correct line/column" do
      assert {:error, error} = Tokenizer.tokenize(&candidates_for/1, "ab 1cd")
      assert error.stage == :lexer
      assert error.line == 1
      assert error.column == 4
      assert error.message =~ "no token matches"
    end

    test "newlines advance the line counter and reset the column" do
      candidates = fn input ->
        [{:NL, fn -> as_candidate(lit("\n").(input)) end} | candidates_for(input)]
      end

      assert {:ok, [w1, %Token{name: :NL}, w2]} = Tokenizer.tokenize(candidates, "ab\ncd")
      assert {w1.line, w1.column} == {1, 1}
      assert {w2.line, w2.column} == {2, 1}
    end
  end

  describe "tokenize_prefix/2" do
    test "stops successfully (not an error) at the first unmatched position" do
      assert {:ok, [%Token{name: :WORD, text: "ab"}]} =
               Tokenizer.tokenize_prefix(&candidates_for/1, "ab1")
    end

    test "an input with nothing matching at all returns an empty list" do
      assert Tokenizer.tokenize_prefix(&candidates_for/1, "123") == {:ok, []}
    end
  end

  describe "advance_line_col/3" do
    test "ordinary characters advance the column" do
      assert Tokenizer.advance_line_col("abc", 1, 1) == {1, 4}
    end

    test "a newline advances the line and resets the column to 1" do
      assert Tokenizer.advance_line_col("a\nbc", 1, 5) == {2, 3}
    end

    test "multiple newlines advance the line multiple times" do
      assert Tokenizer.advance_line_col("\n\n", 1, 1) == {3, 1}
    end

    test "an empty string leaves line/column unchanged" do
      assert Tokenizer.advance_line_col("", 3, 7) == {3, 7}
    end
  end
end
