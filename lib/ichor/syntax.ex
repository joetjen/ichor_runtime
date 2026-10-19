defmodule Ichor.Syntax do
  @moduledoc """
  The lossless tree: every byte of the input, as tokens under the rules
  that matched them.

  The ordinary parse result keeps what a grammar captures and steps over
  the rest -- trivia, punctuation, the order of differently named
  captures. A tool that edits a document and writes it back (a
  formatter, a config updater keeping its comments) needs all of it.
  A parser generated with `lossless: true` returns this tree beside its
  ordinary value (`design/lossless-mode.md` in `ichor`).

  The tree holds four promises, whatever the grammar:

    1. **Lossless.** `text(root)` is the input, byte for byte.
    2. **Ordered.** The leaves, left to right, are every token of the
       input: named tokens, literals, punctuation and trivia.
    3. **Trivia sits between, never at an edge.** No node but the root
       begins or ends with a trivia token. A trivia token belongs to the
       deepest node with something significant on both sides of it;
       the input's leading and trailing trivia belong to the root.
    4. **Every rule that matched is a node**, the ones the ordinary
       tree passes through included. A rule that matched nothing is an
       empty node.

  Which comment belongs to which value is not decided here: that is a
  policy of the format, and the tree hands a consumer what it needs to
  decide it -- each trivia token's siblings, line and column.
  """

  alias Grammar.VM.Token, as: StreamToken
  alias Ichor.Syntax.{Node, Token}

  @typedoc """
  A rule's match as a parser records it: the rule, the token range
  `[from, to)` of the trimmed stream it matched, and the records of the
  rules it called, in order (`Ichor.Syntax.Record`).
  """
  @type record :: {atom(), non_neg_integer(), non_neg_integer(), [record()]}

  @doc """
  The lossless tree of a parse: `record` is the root rule's match, its
  token ranges counted in the stream with leading and trailing trivia
  trimmed (`Grammar.Source.trimmed/2`); `tokens` is the whole stream,
  untrimmed, exactly as the tokenizer returned it; `skip` is the
  grammar's `@skip` token, or nil.

  ## Examples

      iex> tokens = [
      ...>   %Grammar.VM.Token{name: :N, text: "1", line: 1, column: 1},
      ...>   %Grammar.VM.Token{name: :WS, text: " ", line: 1, column: 2},
      ...>   %Grammar.VM.Token{name: :N, text: "2", line: 1, column: 3}
      ...> ]
      iex> tree = Ichor.Syntax.tree({:pair, 0, 3, [{:n, 2, 3, []}]}, tokens, :WS)
      iex> Enum.map(tree.children, & &1.__struct__)
      [Ichor.Syntax.Token, Ichor.Syntax.Token, Ichor.Syntax.Node]
      iex> Ichor.Syntax.text(tree)
      "1 2"

  """
  @spec tree(record(), [StreamToken.t()], atom() | nil) :: Node.t()
  def tree({rule, _from, _to, children}, tokens, skip) do
    stream = List.to_tuple(tokens)
    lead = leading_trivia(tokens, skip)
    kids = Enum.map(children, &shaped(shifted(&1, lead), stream, skip))

    {node, _at} = placed({:span, rule, 0, tuple_size(stream), kids}, stream, skip, {0, 1, 1})
    node
  end

  @doc """
  The input a node or token covers: for the root, the whole input.

      iex> Ichor.Syntax.text(%Ichor.Syntax.Token{name: :N, text: "42"})
      "42"

  """
  @spec text(Node.t() | Token.t()) :: String.t()
  def text(node_or_token), do: node_or_token |> iodata() |> IO.iodata_to_binary()

  @doc """
  Every token under a node, in source order.

      iex> Ichor.Syntax.tokens(%Ichor.Syntax.Node{rule: :empty, children: []})
      []

  """
  @spec tokens(Node.t()) :: [Token.t()]
  def tokens(%Node{children: children}) do
    Enum.flat_map(children, fn
      %Token{} = token -> [token]
      %Node{} = node -> tokens(node)
    end)
  end

  defp iodata(%Token{text: text}), do: text
  defp iodata(%Node{children: children}), do: Enum.map(children, &iodata/1)

  # ---- weaving ---------------------------------------------------------

  # How many trivia tokens `Grammar.Source.trimmed/2` took off the
  # front: the records count from after them.
  defp leading_trivia(_tokens, nil), do: 0

  defp leading_trivia(tokens, skip),
    do: tokens |> Enum.take_while(&(&1.name == skip)) |> length()

  defp shifted({rule, from, to, children}, lead),
    do: {rule, from + lead, to + lead, Enum.map(children, &shifted(&1, lead))}

  # A record's shape in the tree, before positions: `{:span, rule, lo,
  # hi, kids}` over the significant tokens `[lo, hi)` -- its range with
  # trivia taken off both ends, which is where invariant 3 comes from:
  # the trivia it consumed at an edge falls outside it, to whichever
  # ancestor has it strictly inside. A record with nothing significant
  # in its range is `{:empty, rule, at, kids}`.
  defp shaped({rule, from, to, children}, stream, skip) do
    kids = Enum.map(children, &shaped(&1, stream, skip))

    case significant(stream, skip, from, to) do
      nil -> {:empty, rule, from, kids}
      {lo, hi} -> {:span, rule, lo, hi, kids}
    end
  end

  defp significant(stream, skip, from, to) do
    case Enum.find(from..(to - 1)//1, &(not trivia?(stream, skip, &1))) do
      nil ->
        nil

      lo ->
        hi = Enum.find((to - 1)..lo//-1, &(not trivia?(stream, skip, &1)))
        {lo, hi + 1}
    end
  end

  defp trivia?(_stream, nil, _i), do: false
  defp trivia?(stream, skip, i), do: elem(stream, i).name == skip

  # The children of a span in source order: its own tokens -- those in
  # `[lo, hi)` no kid covers -- interleaved with its kids. An empty kid
  # sits before the token at its position, and never past the span's
  # end.
  defp layout(lo, hi, kids) do
    {items, cursor} =
      Enum.flat_map_reduce(kids, lo, fn
        {:span, _, klo, khi, _} = kid, cursor ->
          {token_items(cursor, klo) ++ [kid], khi}

        {:empty, _, at, _} = kid, cursor ->
          stop = at |> min(hi) |> max(cursor)
          {token_items(cursor, stop) ++ [kid], stop}
      end)

    items ++ token_items(cursor, hi)
  end

  defp token_items(from, to), do: Enum.map(from..(to - 1)//1, &{:token, &1})

  # Turns shapes into structs, counting offset, line and column along
  # the leaves in tree order, so an empty node's position is where it
  # sits in the tree and every node's bytes are contiguous.
  defp placed({:token, i}, stream, skip, {offset, _line, _column}) do
    %StreamToken{name: name, text: text, line: line, column: column} = elem(stream, i)

    token = %Token{
      name: name,
      text: text,
      trivia: trivia?(stream, skip, i),
      offset: offset,
      line: line,
      column: column
    }

    {token, after_text(offset, line, column, text)}
  end

  defp placed({:span, rule, lo, hi, kids}, stream, skip, at),
    do: node(rule, layout(lo, hi, kids), stream, skip, at)

  defp placed({:empty, rule, _at, kids}, stream, skip, at),
    do: node(rule, kids, stream, skip, at)

  defp node(rule, items, stream, skip, {offset, line, column} = at) do
    {children, {end_offset, _, _} = after_node} =
      Enum.map_reduce(items, at, &placed(&1, stream, skip, &2))

    node = %Node{
      rule: rule,
      children: children,
      offset: offset,
      size: end_offset - offset,
      line: line,
      column: column
    }

    {node, after_node}
  end

  defp after_text(offset, line, column, text) do
    offset = offset + byte_size(text)

    case String.split(text, "\n") do
      [one] -> {offset, line, column + String.length(one)}
      lines -> {offset, line + length(lines) - 1, String.length(List.last(lines)) + 1}
    end
  end
end
