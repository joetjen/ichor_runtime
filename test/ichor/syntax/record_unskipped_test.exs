defmodule Ichor.Syntax.RecordUnskippedTest do
  @moduledoc """
  An LR or GLR parse runs on the stream without its skip tokens, so its
  records count positions there; `Ichor.Syntax.tree/3` counts them in
  the trimmed stream, which keeps the skip tokens between two others.
  `unskipped/3` moves a record from the one count to the other.
  """

  use ExUnit.Case, async: true

  alias Ichor.Syntax.Record

  defp token(name, text), do: %Grammar.VM.Token{name: name, text: text, line: 1, column: 1}

  # " 1 2 ": trimmed, `1 _ 2` (0..2); without skip tokens, `1 2` (0..1).
  defp tokens,
    do: [
      token(:SPACE, " "),
      token(:N, "1"),
      token(:SPACE, " "),
      token(:N, "2"),
      token(:SPACE, " ")
    ]

  test "a record's range takes in the skip tokens between its own" do
    assert Record.unskipped({:pair, 0, 2, [{:n, 1, 2, []}]}, tokens(), :SPACE) ==
             {:pair, 0, 3, [{:n, 2, 3, []}]}
  end

  test "an empty record sits before the next significant token, or at the end" do
    assert Record.unskipped({:e, 1, 1, []}, tokens(), :SPACE) == {:e, 2, 2, []}
    assert Record.unskipped({:e, 2, 2, []}, tokens(), :SPACE) == {:e, 3, 3, []}
  end

  test "a grammar with no skip token changes nothing" do
    assert Record.unskipped({:pair, 0, 2, []}, tokens(), nil) == {:pair, 0, 2, []}
  end

  test "woven into a tree, the input comes back byte for byte" do
    record = Record.unskipped({:pair, 0, 2, [{:n, 1, 2, []}]}, tokens(), :SPACE)
    assert Ichor.Syntax.text(Ichor.Syntax.tree(record, tokens(), :SPACE)) == " 1 2 "
  end
end
