defmodule Grammar.Furthest do
  @moduledoc """
  Where a PEG parse went wrong: the furthest token any alternative
  reached, and every token that would have been accepted there.

  **A failed PEG parse says only that the root did not match** -- an
  ordered choice backtracks out of every alternative, and by the time
  the root gives up, where each one failed is gone. The usual answer,
  and this one, is to remember while matching: each token match that
  fails reports its position and the token it wanted (`failed/2`), and
  the furthest position wins. That is where the input went wrong, and
  what was wanted there is what to tell the user.

  **Per process, in the process dictionary.** A generated parser's
  matchers are pure functions of the stream and a position, and
  threading a record through every one of them would change every
  generated file; a parse runs in one process from start to finish. A
  parse brackets itself with `start/0` and `finish/1`, which save and
  restore whatever was there, so a parse nested inside another -- a
  custom lexeme re-lexing a suffix -- leaves the outer record as it was.

  **Not inside a lookahead.** `!X` failing to match `X` is what lets a
  parse go on, and `&X` is a question, not a consumption: a matcher
  brackets a predicate with `enter_predicate/0` and `exit_predicate/0`,
  and failures between them are not expectations.
  """

  alias Grammar.Source
  alias Ichor.Error

  @key {__MODULE__, :record}

  @typedoc "The furthest token index a match failed at (-1 for none yet), and the tokens wanted there."
  @type record :: {integer(), MapSet.t(atom())}

  @doc "Starts a fresh record for a parse, answering whatever was there, for `finish/1`."
  @spec start() :: term()
  def start do
    previous = Process.get(@key)
    Process.put(@key, {-1, MapSet.new(), 0})
    previous
  end

  @doc "The parse's record, and whatever `start/0` found put back."
  @spec finish(term()) :: record()
  def finish(previous) do
    {pos, names, _depth} = Process.get(@key, {-1, MapSet.new(), 0})

    if previous == nil, do: Process.delete(@key), else: Process.put(@key, previous)

    {pos, names}
  end

  @doc """
  A token match that failed: at token index `pos`, wanting `name`.
  Ignored inside a lookahead, behind the furthest position, and outside
  a parse that called `start/0`.
  """
  @spec failed(non_neg_integer(), atom()) :: :ok
  def failed(pos, name) do
    case Process.get(@key) do
      {furthest, names, 0} when pos == furthest ->
        Process.put(@key, {pos, MapSet.put(names, name), 0})

      {furthest, _names, 0} when pos > furthest ->
        Process.put(@key, {pos, MapSet.new([name]), 0})

      _ ->
        :ok
    end

    :ok
  end

  @doc "A lookahead begins: failures until `exit_predicate/0` are not expectations."
  @spec enter_predicate() :: :ok
  def enter_predicate, do: depth(1)

  @doc "A lookahead ends, matched or not."
  @spec exit_predicate() :: :ok
  def exit_predicate, do: depth(-1)

  defp depth(by) do
    case Process.get(@key) do
      {pos, names, depth} -> Process.put(@key, {pos, names, max(depth + by, 0)})
      nil -> :ok
    end

    :ok
  end

  @doc """
  The error a failed parse of `input` over `stream` reports, from its
  `record`, or nil when the record says nothing better than the
  caller's own error.

  `leftover` is the token index a root that matched a prefix stopped
  at, or nil when the root did not match at all: input left over after
  a complete match is reported there unless some alternative reached
  further. `skip` is the grammar's `@skip` token, which skip-splicing
  makes optional everywhere and so is never worth naming. `describe`
  names a wanted token for the user: an anonymous literal by its text,
  quoted, and anything else by its name.

  ## Examples

      iex> stream = {%Grammar.VM.Token{name: :INT, text: "1", line: 1, column: 1}}
      iex> error = Grammar.Furthest.error({0, MapSet.new([:NAME])}, stream, "1", nil, nil, &Atom.to_string/1)
      iex> {error.message, error.line, error.column}
      {~s(unexpected "1" -- expected NAME), 1, 1}

  """
  @spec error(record(), tuple(), String.t(), non_neg_integer() | nil, atom() | nil, (atom() ->
                                                                                       String.t())) ::
          Error.t() | nil
  def error({pos, names}, stream, input, leftover, skip, describe) do
    wanted = names |> MapSet.delete(skip) |> Enum.map(describe) |> Enum.sort()

    if wanted == [] or pos < (leftover || 0) do
      nil
    else
      {line, column} = Source.position(stream, pos, input)
      found = if pos < tuple_size(stream), do: elem(stream, pos).text, else: :eof

      Error.new(
        message: "unexpected #{spelled(found)} -- expected #{listed(wanted)}",
        stage: :parser,
        line: line,
        column: column,
        expected: wanted,
        found: found,
        source: input
      )
    end
  end

  defp spelled(:eof), do: "end of input"
  defp spelled(text), do: inspect(text)

  defp listed([one]), do: one
  defp listed(many), do: "one of: " <> Enum.join(many, ", ")
end
