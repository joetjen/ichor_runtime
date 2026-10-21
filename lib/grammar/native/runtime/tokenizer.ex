defmodule Grammar.Native.Runtime.Tokenizer do
  @moduledoc """
  Char-level helpers shared by every `Grammar.Native.CharCompiler`-generated
  function, plus the maximal-munch driver `Grammar.Native.generate/2`'s own
  `lex_candidates/2` feeds into -- the Tokenizer stage of Aether's
  Reader/Tokenizer/Lexer/Parser split. No captures, no `ref_stack` --
  tokens can never contain a `Capture` or `Indent`, so a token body is
  just text in, `{matched text, rest}` out.
  """

  alias Grammar.VM.Token

  import Bitwise

  @type char_result :: {:ok, String.t(), String.t()} | :fail
  @type char_fun :: (String.t() -> char_result())

  @typedoc """
  A character class prepared by `char_class/1`: its ASCII members as a
  128-bit bitmap, and the rest as sorted, disjoint `{lo, hi}` ranges in
  a tuple.
  """
  @type class :: {non_neg_integer(), tuple()}

  @doc """
  Whether `cp` lies in any of `ranges`, scanning them in turn.

  For a parser generated before `char_class/1` existed. A class with
  hundreds of ranges, such as a Unicode identifier class, makes every
  character outside it scan them all: a generated parser now prepares
  the class once with `char_class/1` and asks `in_class?/2`.
  """
  @spec in_ranges?(non_neg_integer(), [{non_neg_integer(), non_neg_integer()}]) :: boolean()
  def in_ranges?(_cp, []), do: false
  def in_ranges?(cp, [{lo, hi} | _]) when cp >= lo and cp <= hi, do: true
  def in_ranges?(cp, [_ | rest]), do: in_ranges?(cp, rest)

  @doc """
  `ranges`, in any order, overlapping or not, prepared for `in_class?/2`:
  an ASCII character is one bit test, and any other a binary search.

      iex> class = Grammar.Native.Runtime.Tokenizer.char_class([{?a, ?z}, {0x4E00, 0x9FFF}])
      iex> {Grammar.Native.Runtime.Tokenizer.in_class?(?q, class),
      ...>  Grammar.Native.Runtime.Tokenizer.in_class?(0x4E2D, class),
      ...>  Grammar.Native.Runtime.Tokenizer.in_class?(?Q, class)}
      {true, true, false}

  """
  @spec char_class([{non_neg_integer(), non_neg_integer()}]) :: class()
  def char_class(ranges) do
    ascii =
      for {lo, hi} <- ranges, lo <= 127, cp <- lo..min(hi, 127)//1, reduce: 0 do
        bits -> bor(bits, bsl(1, cp))
      end

    rest =
      for({lo, hi} <- ranges, hi >= 128, do: {max(lo, 128), hi})
      |> Enum.sort()
      |> merged()
      |> List.to_tuple()

    {ascii, rest}
  end

  @doc "Whether `cp` is in `class`, a class prepared by `char_class/1`."
  @spec in_class?(non_neg_integer(), class()) :: boolean()
  def in_class?(cp, {ascii, _rest}) when cp < 128, do: band(bsr(ascii, cp), 1) == 1
  def in_class?(cp, {_ascii, rest}), do: searched?(cp, rest, 0, tuple_size(rest) - 1)

  # Binary search over sorted, disjoint ranges, between indices low and high.
  defp searched?(_cp, _ranges, low, high) when low > high, do: false

  defp searched?(cp, ranges, low, high) do
    middle = div(low + high, 2)
    {lo, hi} = elem(ranges, middle)

    cond do
      cp < lo -> searched?(cp, ranges, low, middle - 1)
      cp > hi -> searched?(cp, ranges, middle + 1, high)
      true -> true
    end
  end

  # Sorted ranges with every overlapping or adjacent pair joined into one.
  defp merged([{lo1, hi1}, {lo2, hi2} | rest]) when lo2 <= hi1 + 1,
    do: merged([{lo1, max(hi1, hi2)} | rest])

  defp merged([range | rest]), do: [range | merged(rest)]
  defp merged([]), do: []

  @doc "Ordered choice: tries each of `funs` against `input` in order, short-circuiting on the first success (never evaluating later alternatives, same as PEG's own ordered choice)."
  @spec first_char_match([char_fun()], String.t()) :: char_result()
  def first_char_match([], _input), do: :fail

  def first_char_match([fun | rest], input) do
    case fun.(input) do
      {:ok, _, _} = ok -> ok
      :fail -> first_char_match(rest, input)
    end
  end

  @spec star_char(char_fun(), String.t(), String.t()) :: char_result()
  def star_char(fun, input, acc \\ "") do
    case fun.(input) do
      :fail ->
        {:ok, acc, input}

      {:ok, text, rest} ->
        if rest == input do
          {:ok, acc <> text, rest}
        else
          star_char(fun, rest, acc <> text)
        end
    end
  end

  @spec plus_char(char_fun(), String.t()) :: char_result()
  def plus_char(fun, input) do
    case fun.(input) do
      :fail -> :fail
      {:ok, text, rest} -> star_char(fun, rest, text)
    end
  end

  @spec opt_char(char_fun(), String.t()) :: char_result()
  def opt_char(fun, input) do
    case fun.(input) do
      {:ok, _, _} = ok -> ok
      :fail -> {:ok, "", input}
    end
  end

  @spec call_n_times_char(char_fun(), non_neg_integer(), String.t()) :: char_result()
  def call_n_times_char(_fun, 0, input), do: {:ok, "", input}

  def call_n_times_char(fun, n, input) do
    with {:ok, text1, rest1} <- fun.(input),
         {:ok, textN, restN} <- call_n_times_char(fun, n - 1, rest1) do
      {:ok, text1 <> textN, restN}
    else
      :fail -> :fail
    end
  end

  @spec rep_char(char_fun(), non_neg_integer(), non_neg_integer() | :infinity, String.t()) ::
          char_result()
  def rep_char(fun, min, :infinity, input) do
    with {:ok, mandatory, rest1} <- call_n_times_char(fun, min, input),
         {:ok, extra, restN} <- star_char(fun, rest1) do
      {:ok, mandatory <> extra, restN}
    else
      :fail -> :fail
    end
  end

  def rep_char(fun, min, max, input) do
    with {:ok, mandatory, rest1} <- call_n_times_char(fun, min, input),
         {:ok, extra, restN} <- call_n_times_char(&opt_char(fun, &1), max - min, rest1) do
      {:ok, mandatory <> extra, restN}
    else
      :fail -> :fail
    end
  end

  @spec and_pred_char(char_fun(), String.t()) :: char_result()
  def and_pred_char(fun, input) do
    case fun.(input) do
      {:ok, _, _} -> {:ok, "", input}
      :fail -> :fail
    end
  end

  @spec not_pred_char(char_fun(), String.t()) :: char_result()
  def not_pred_char(fun, input) do
    case fun.(input) do
      {:ok, _, _} -> :fail
      :fail -> {:ok, "", input}
    end
  end

  # ---- maximal munch ---------------------------------------------------------

  @doc """
  Picks the longest-matching candidate at the current lexer position,
  ties broken by declaration order (candidates tried in that order,
  replaced only on a *strictly* longer match). A zero-width match is
  never accepted as "the next token" -- accepting one would advance
  nothing and loop forever (mirrors `Grammar.VM.Tokenizer`'s own private
  `consider` helper's same guard exactly); such a token can still exist
  and be referenced from inside other tokens, it just can't win maximal
  munch on its own.

  `capture` is `nil` for an ordinary candidate, or a `Grammar.IR.Custom
  Lexeme`-matched one's explicit override -- see `Grammar.VM.Token`.
  """
  @spec pick_longest([{atom(), (-> {:ok, String.t(), String.t(), term()} | :fail)}]) ::
          {:ok, atom(), String.t(), String.t(), term()} | :fail
  def pick_longest(candidates), do: longest(candidates, nil)

  # pick_longest/1's loop, with the best match so far as
  # {name, text, rest, capture, length}: plain recursion, as it runs for
  # every candidate at every position of the input.
  defp longest([], nil), do: :fail
  defp longest([], {name, text, rest, capture, _len}), do: {:ok, name, text, rest, capture}

  defp longest([{name, fun} | more], best) do
    case fun.() do
      {:ok, text, rest, capture} when byte_size(text) > 0 ->
        len = byte_size(text)

        if best == nil or len > elem(best, 4),
          do: longest(more, {name, text, rest, capture, len}),
          else: longest(more, best)

      _no_or_empty_match ->
        longest(more, best)
    end
  end

  @doc "Tokenizes `input` completely via maximal munch, or reports the first position nothing matches -- `get_candidates` rebuilds the per-token match attempts against whatever's left of the input at each position."
  @spec tokenize(
          (String.t() -> [{atom(), (-> {:ok, String.t(), String.t(), term()} | :fail)}]),
          String.t()
        ) ::
          {:ok, [Token.t()]} | {:error, Ichor.Error.t()}
  def tokenize(get_candidates, input),
    do: do_tokenize(get_candidates, input, input, 1, 1, [], :strict)

  @doc """
  Like `tokenize/2`, but tokenizes only as much of a *prefix* of `input`
  as it can -- stopping (successfully) the moment nothing matches,
  instead of failing. For `Ichor.CustomLexeme`'s re-lex-and-match
  primitive: the trailing bytes after wherever a dependency rule
  actually stops (an interpolated string's closing `}`, say) generally
  aren't valid tokens in their own right, and were never supposed to be
  -- they belong to whatever's scanning the *outer* token, not to this
  inner match.
  """
  @spec tokenize_prefix(
          (String.t() -> [{atom(), (-> {:ok, String.t(), String.t(), term()} | :fail)}]),
          String.t()
        ) :: {:ok, [Token.t()]}
  def tokenize_prefix(get_candidates, input),
    do: do_tokenize(get_candidates, input, input, 1, 1, [], :prefix)

  defp do_tokenize(_get_candidates, "", _source, _line, _col, acc, _mode),
    do: {:ok, Enum.reverse(acc)}

  defp do_tokenize(get_candidates, input, source, line, col, acc, mode) do
    case pick_longest(get_candidates.(input)) do
      {:ok, name, text, rest, capture} ->
        token = %Token{name: name, text: text, line: line, column: col, capture: capture}
        {new_line, new_col} = advance_line_col(text, line, col)
        do_tokenize(get_candidates, rest, source, new_line, new_col, [token | acc], mode)

      :fail when mode == :prefix ->
        {:ok, Enum.reverse(acc)}

      :fail ->
        {:error,
         Ichor.Error.new(
           message: "no token matches here",
           stage: :lexer,
           line: line,
           column: col,
           source: source
         )}
    end
  end

  @spec advance_line_col(String.t(), pos_integer(), pos_integer()) ::
          {pos_integer(), pos_integer()}
  def advance_line_col(<<?\n, rest::binary>>, line, _col), do: advance_line_col(rest, line + 1, 1)

  def advance_line_col(<<_::utf8, rest::binary>>, line, col),
    do: advance_line_col(rest, line, col + 1)

  def advance_line_col(<<_byte, rest::binary>>, line, col),
    do: advance_line_col(rest, line, col + 1)

  def advance_line_col(<<>>, line, col), do: {line, col}
end
