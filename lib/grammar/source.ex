defmodule Grammar.Source do
  @moduledoc """
  The very first, Reader-adjacent stage in front of the Tokenizer:
  confirms `input` is valid UTF-8 before any char-level matcher --
  built on Elixir binary pattern matching against `::utf8` codepoints --
  ever touches it. Malformed input left unchecked doesn't fail cleanly:
  it crashes a compiled matcher with a `MatchError` partway through
  tokenizing, deep inside either backend, instead of surfacing as an
  ordinary `Ichor.Error`.

  Shared by both backends (`Grammar.VM.parse/3`/`run_sequence/4` call
  this directly; `Grammar.Native`'s generated `tokenize/2` calls it too)
  since, like `Grammar.Lexer`, this is pure data validation with nothing
  grammar-specific to compile.
  """

  alias Ichor.Error

  @doc "Returns `input` unchanged if it's valid UTF-8, or an `Ichor.Error` (`stage: :lexer`) otherwise."
  @spec validate(String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def validate(input) when is_binary(input) do
    if String.valid?(input) do
      {:ok, input}
    else
      {:error, Error.new(message: "input is not valid UTF-8", stage: :lexer)}
    end
  end

  @doc """
  `tokens` without the `skip` tokens before the first other token and
  after the last.

  **Trivia around the input is not part of it.** Skip-splicing puts a
  `skip*` in front of every sequence element but the first, so
  nothing inside a grammar ever expects a skip token at the very start
  of the input or after its very end. Every engine and both backends
  trim the stream here before matching the root, so a document's
  leading newline or trailing space means the same to all of them.
  The skip tokens between two others are left alone: those are the
  grammar's.

  `skip` is the grammar's `@skip` token, or `nil` for `@noskip`, which
  changes nothing.
  """
  @spec trimmed([Grammar.VM.Token.t()], atom() | nil) :: [Grammar.VM.Token.t()]
  def trimmed(tokens, nil), do: tokens

  def trimmed(tokens, skip) do
    tokens
    |> Enum.drop_while(&(&1.name == skip))
    |> Enum.reverse()
    |> Enum.drop_while(&(&1.name == skip))
    |> Enum.reverse()
  end

  @doc """
  `tokens` without any `skip` token: the stream an LR or GLR parse runs
  on. Their rules never mention the skip token -- `@skip` makes it
  optional between any two elements, which a table with one token of
  lookahead cannot decide -- so it is dropped before parsing instead.
  `nil`, for `@noskip`, changes nothing.

  The text of the skip tokens dropped before a token is kept on it
  (`trivia_before`), so a capture over several tokens still holds the
  input between its first and last, skip tokens included.
  """
  @spec significant([Grammar.VM.Token.t()], atom() | nil) :: [Grammar.VM.Token.t()]
  def significant(tokens, nil), do: tokens

  def significant(tokens, skip) do
    {kept, _trivia} =
      Enum.reduce(tokens, {[], ""}, fn
        %{name: ^skip, text: text}, {kept, trivia} -> {kept, trivia <> text}
        token, {kept, trivia} -> {[%{token | trivia_before: trivia} | kept], ""}
      end)

    Enum.reverse(kept)
  end

  @doc """
  Where position `pos` of `stream` is, as `{line, column}`: where its
  token starts, or, past the last token, the end of `input`.

  **An error always says where.** "Unexpected end of input" and a root
  that matched nothing are errors about a place too -- the end, or the
  first token -- and a user handed one with no line and column has
  nowhere to look. No input at all is `{1, 1}`. Columns count
  codepoints, as the tokenizer does.
  """
  @spec position(tuple(), non_neg_integer(), String.t()) :: {pos_integer(), pos_integer()}
  def position(stream, pos, _input) when pos < tuple_size(stream) do
    %{line: line, column: column} = elem(stream, pos)
    {line, column}
  end

  def position(_stream, _pos, input),
    do: Grammar.Native.Runtime.Tokenizer.advance_line_col(input, 1, 1)

  @doc """
  `error` -- or each of a list of them -- placed at the end of `input`
  when it says nowhere, and shown: given the line of `input` it is on,
  and a caret, when it has a position but no snippet.

  For a caller that gets its error from somewhere that never saw the
  input: `Grammar.GLR.Runtime` builds "unexpected end of input" from
  the token stream alone, and its callers, which have the input, place
  it here.
  """
  @spec placed(Error.t() | [Error.t()], String.t()) :: Error.t() | [Error.t()]
  def placed(errors, input) when is_list(errors), do: Enum.map(errors, &placed(&1, input))

  def placed(%Error{line: nil} = error, input) do
    {line, column} = position({}, 0, input)
    shown(%{error | line: line, column: column}, input)
  end

  def placed(%Error{} = error, input), do: shown(error, input)

  # **Every error shows where, too**: one with a position and no snippet
  # gets the line it is on and a caret, as one built with its source
  # always had. The shift-reduce runtimes build theirs from the token
  # stream alone, so an LR or GLR error used to say where and show
  # nothing -- less than a PEG error, for the same mistake.
  #
  # Only the snippet is filled in, by updating the error rather than
  # rebuilding it field by field: a rebuild has to name every field, and
  # one it forgets -- `data`, before 0.4.0 -- is silently lost.
  defp shown(%Error{context_lines: nil, line: line} = error, input) when not is_nil(line) do
    snippet = Error.new(message: "", line: line, column: error.column, source: input)
    %{error | context_lines: snippet.context_lines}
  end

  defp shown(error, _input), do: error
end
