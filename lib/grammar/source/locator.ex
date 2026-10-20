defmodule Grammar.Source.Locator do
  @moduledoc """
  Where a range of a parse's token stream is in its input, as an
  `Ichor.Node.source_span/0`: `{line, column, length}`.

  A parser records each capture's place as the token range `[from, to)`
  it matched (`Ichor.Capture.at/3`) -- two integers, nothing to compute
  while matching, and most of them never asked for. `Ichor.Actions`
  turns a range into a span only when it builds the capture, through
  this.

  **Built once per parse.** `new/2` reads the input once for where each
  line starts, so a span is a few lookups whatever its size. A span is
  measured from the input's line starts rather than by adding up token
  texts, because a stream need not hold every token in between: the
  shift-reduce engines drop the skip tokens.

  Lines and columns are 1-based, and columns and lengths count
  codepoints, as `Grammar.Native.Runtime.Tokenizer` does.
  """

  alias Grammar.Native.Runtime.Tokenizer

  @enforce_keys [:input, :stream, :line_starts, :end_at]
  defstruct [:input, :stream, :line_starts, :end_at]

  @typedoc """
  `input` is the text parsed, kept to show a placed error's line;
  `stream` is the token stream the parse ran over; `line_starts` the
  codepoint offset each line of the input begins at; `end_at` the
  `{line, column}` just past the input's last character.
  """
  @type t :: %__MODULE__{
          input: String.t(),
          stream: tuple(),
          line_starts: tuple(),
          end_at: {pos_integer(), pos_integer()}
        }

  @doc """
  The locator for a parse of `input` over `stream` (a tuple of
  `Grammar.VM.Token`s, as every engine matches against).
  """
  @spec new(tuple(), String.t()) :: t()
  def new(stream, input) when is_tuple(stream) and is_binary(input) do
    lines = String.split(input, "\n")

    {starts, _} =
      Enum.map_reduce(lines, 0, fn line, offset ->
        {offset, offset + codepoints(line) + 1}
      end)

    end_at = {length(lines), codepoints(List.last(lines)) + 1}

    %__MODULE__{
      input: input,
      stream: stream,
      line_starts: List.to_tuple(starts),
      end_at: end_at
    }
  end

  @doc """
  The span of the tokens `[from, to)`: where the first one starts, and
  how many codepoints there are from there to the end of the last one.

  An empty range (`from == to`) is a place, not a stretch: where the
  token at `from` starts -- or the end of the input, past the last
  token -- with length `0`.
  """
  @spec span(t(), non_neg_integer(), non_neg_integer()) :: Ichor.Node.source_span()
  def span(%__MODULE__{} = locator, from, to) when to <= from do
    {line, column} = start_of(locator, from)
    {line, column, 0}
  end

  def span(%__MODULE__{stream: stream} = locator, from, to) do
    {line, column} = start_of(locator, from)
    %{text: text, line: last_line, column: last_column} = elem(stream, to - 1)
    {end_line, end_column} = Tokenizer.advance_line_col(text, last_line, last_column)
    {line, column, offset(locator, end_line, end_column) - offset(locator, line, column)}
  end

  defp start_of(%__MODULE__{stream: stream}, pos) when pos < tuple_size(stream) do
    %{line: line, column: column} = elem(stream, pos)
    {line, column}
  end

  defp start_of(%__MODULE__{end_at: end_at}, _pos), do: end_at

  defp offset(%__MODULE__{line_starts: starts}, line, column),
    do: elem(starts, line - 1) + column - 1

  # Codepoints, not graphemes: `String.length/1` would count `e` and a
  # combining accent as one, where the tokenizer's columns count two.
  defp codepoints(text), do: text |> String.to_charlist() |> length()
end
