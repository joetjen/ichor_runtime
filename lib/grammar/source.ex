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
  when it says nowhere, and otherwise as it is.

  For a caller that gets its error from somewhere that never saw the
  input: `Grammar.GLR.Runtime` builds "unexpected end of input" from
  the token stream alone, and its callers, which have the input, place
  it here.
  """
  @spec placed(Error.t() | [Error.t()], String.t()) :: Error.t() | [Error.t()]
  def placed(errors, input) when is_list(errors), do: Enum.map(errors, &placed(&1, input))

  def placed(%Error{line: nil} = error, input) do
    {line, column} = position({}, 0, input)
    %{error | line: line, column: column}
  end

  def placed(%Error{} = error, _input), do: error
end
