defmodule Ichor.SyntaxTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Ichor.Syntax
  doctest Ichor.Syntax.Record

  alias Grammar.VM.Token
  alias Ichor.Syntax
  alias Ichor.Syntax.{Node, Record}

  # Tokens laid out from `parts`, `{name, text}` each, with the line and
  # column the tokenizer would have given them.
  defp stream(parts) do
    {tokens, _at} =
      Enum.map_reduce(parts, {1, 1}, fn {name, text}, {line, column} ->
        {%Token{name: name, text: text, line: line, column: column},
         advance({line, column}, text)}
      end)

    tokens
  end

  defp advance({line, column}, text) do
    case String.split(text, "\n") do
      [one] -> {line, column + String.length(one)}
      lines -> {line + length(lines) - 1, String.length(List.last(lines)) + 1}
    end
  end

  defp input(parts), do: Enum.map_join(parts, "", fn {_name, text} -> text end)

  # Children as `rule`/`{name, text}` shapes, for reading a tree at a glance.
  defp shape(%Node{rule: rule, children: children}), do: {rule, Enum.map(children, &shape/1)}
  defp shape(%Syntax.Token{name: name, text: text}), do: {name, text}

  describe "tree/3" do
    test "puts each token under the deepest rule that matched it" do
      parts = [{:A, "a"}, {:WS, " "}, {:B, "b"}]
      record = {:pair, 0, 3, [{:left, 0, 1, []}, {:right, 2, 3, []}]}

      assert shape(Syntax.tree(record, stream(parts), :WS)) ==
               {:pair, [{:left, [{:A, "a"}]}, {:WS, " "}, {:right, [{:B, "b"}]}]}
    end

    test "gives the root the trivia before the first token and after the last" do
      parts = [{:WS, " "}, {:A, "a"}, {:WS, "\n"}]
      record = {:root, 0, 1, [{:item, 0, 1, []}]}

      assert shape(Syntax.tree(record, stream(parts), :WS)) ==
               {:root, [{:WS, " "}, {:item, [{:A, "a"}]}, {:WS, "\n"}]}
    end

    test "lifts trivia a rule consumed at its edge out to where it lies between two things" do
      # `p := A b?`, with `b` absent: the skip before `b?` is consumed
      # anyway, so `p`'s match ends after the trivia. The tree does not.
      parts = [{:A, "a"}, {:WS, " "}, {:C, "c"}]
      record = {:root, 0, 3, [{:p, 0, 2, []}, {:q, 2, 3, []}]}

      assert shape(Syntax.tree(record, stream(parts), :WS)) ==
               {:root, [{:p, [{:A, "a"}]}, {:WS, " "}, {:q, [{:C, "c"}]}]}
    end

    test "lifts trivia through as many levels as it sits at the edge of" do
      parts = [{:A, "a"}, {:WS, " "}, {:C, "c"}]
      record = {:root, 0, 3, [{:outer, 0, 2, [{:inner, 0, 2, []}]}, {:q, 2, 3, []}]}

      assert shape(Syntax.tree(record, stream(parts), :WS)) ==
               {:root, [{:outer, [{:inner, [{:A, "a"}]}]}, {:WS, " "}, {:q, [{:C, "c"}]}]}
    end

    test "keeps trivia inside a rule where it lies between two of the rule's own tokens" do
      parts = [{:A, "a"}, {:WS, " "}, {:PLUS, "+"}, {:WS, " "}, {:A, "b"}]
      record = {:sum, 0, 5, []}

      assert shape(Syntax.tree(record, stream(parts), :WS)) ==
               {:sum, [{:A, "a"}, {:WS, " "}, {:PLUS, "+"}, {:WS, " "}, {:A, "b"}]}
    end

    test "keeps a rule that matched nothing, as an empty node where it matched" do
      parts = [{:A, "a"}, {:WS, " "}, {:C, "c"}]
      record = {:root, 0, 3, [{:x, 0, 1, []}, {:nothing, 2, 2, []}, {:y, 2, 3, []}]}

      tree = Syntax.tree(record, stream(parts), :WS)

      assert shape(tree) ==
               {:root, [{:x, [{:A, "a"}]}, {:WS, " "}, {:nothing, []}, {:y, [{:C, "c"}]}]}

      nothing = Enum.at(tree.children, 2)
      assert {nothing.offset, nothing.size, nothing.line, nothing.column} == {2, 0, 1, 3}
    end

    test "leaves every token in place for a grammar with no skip token" do
      parts = [{:WS, " "}, {:A, "a"}]
      record = {:root, 0, 2, []}

      tree = Syntax.tree(record, stream(parts), nil)

      assert shape(tree) == {:root, [{:WS, " "}, {:A, "a"}]}
      assert Enum.map(Syntax.tokens(tree), & &1.trivia) == [false, false]
    end

    test "of input that is only trivia is the root holding it" do
      parts = [{:WS, "  \n"}]

      assert shape(Syntax.tree({:root, 0, 0, []}, stream(parts), :WS)) ==
               {:root, [{:WS, "  \n"}]}
    end

    test "of no input at all is an empty root at the start" do
      tree = Syntax.tree({:root, 0, 0, []}, [], :WS)

      assert {tree.rule, tree.children, tree.offset, tree.size, tree.line, tree.column} ==
               {:root, [], 0, 0, 1, 1}
    end

    test "counts offsets and sizes in bytes, and lines and columns as the tokenizer does" do
      parts = [{:A, "é"}, {:WS, "\n  "}, {:A, "ü"}]
      record = {:root, 0, 3, [{:x, 0, 1, []}, {:y, 2, 3, []}]}

      tree = Syntax.tree(record, stream(parts), :WS)
      [x, ws, y] = tree.children

      assert {x.offset, x.size} == {0, 2}
      assert {ws.offset, ws.trivia} == {2, true}
      assert {y.offset, y.size, y.line, y.column} == {5, 2, 2, 3}
      assert {tree.offset, tree.size} == {0, 7}
    end
  end

  describe "text/1" do
    test "is the input, byte for byte, for the root" do
      parts = [{:WS, "# c\n"}, {:A, "a"}, {:WS, " "}, {:A, "b"}, {:WS, " "}]
      record = {:root, 0, 3, [{:x, 0, 1, []}, {:x, 2, 3, []}]}

      assert Syntax.text(Syntax.tree(record, stream(parts), :WS)) == input(parts)
    end

    test "of a node is exactly the bytes of the input it covers" do
      parts = [{:A, "a"}, {:WS, " "}, {:B, "b"}]
      tree = Syntax.tree({:root, 0, 3, [{:x, 2, 3, []}]}, stream(parts), :WS)
      x = List.last(tree.children)

      assert Syntax.text(x) == binary_part(input(parts), x.offset, x.size)
    end

    property "the leaves of any tree are the input, and every node covers its own bytes" do
      check all(parts <- parts(), record <- record_over(trimmed_length(parts))) do
        tree = Syntax.tree(record, stream(parts), :WS)
        source = input(parts)

        assert Syntax.text(tree) == source
        assert Enum.map(Syntax.tokens(tree), & &1.text) == Enum.map(parts, &elem(&1, 1))

        for node <- nodes(tree) do
          assert Syntax.text(node) == binary_part(source, node.offset, node.size)
        end

        for node <- nodes(tree), node != tree, (tokens = Syntax.tokens(node)) != [] do
          refute hd(tokens).trivia
          refute List.last(tokens).trivia
        end
      end
    end
  end

  describe "Record" do
    test "takes the records out of a rule's captures, in order, leaving the rest as they were" do
      captures = [{:a, {:token, :A, "a"}}, {Record.key(), [{:x, 0, 1, []}, {:y, 1, 2, []}]}]

      assert Record.take(captures) ==
               {[{:x, 0, 1, []}, {:y, 1, 2, []}], [{:a, {:token, :A, "a"}}]}
    end

    test "takes a record captured once as a list of one" do
      assert Record.take([{Record.key(), {:x, 0, 1, []}}]) == {[{:x, 0, 1, []}], []}
    end

    test "takes nothing from captures that hold no records" do
      assert Record.take([{:a, {:text, "a"}}]) == {[], [{:a, {:text, "a"}}]}
    end

    test "makes a called rule's record from the records its own captures hold" do
      sub = [{:n, {:token, :N, "1"}}, {Record.key(), {:inner, 0, 1, []}}]

      assert Record.called(:outer, 0, 2, sub) ==
               {[{:n, {:token, :N, "1"}}], {:outer, 0, 2, [{:inner, 0, 1, []}]}}
    end
  end

  # ---- generators -------------------------------------------------------

  # A token stream that may start and end with trivia, never two trivia
  # tokens in a row (the tokenizer would have made them one).
  defp parts do
    gen all(
          lead <- StreamData.boolean(),
          words <- StreamData.list_of(StreamData.member_of(["a", "é", "+", "xy"]), max_length: 6),
          gaps <- StreamData.list_of(StreamData.member_of([nil, " ", "\n", "# c\n"]), length: 7)
        ) do
      body =
        words
        |> Enum.zip(gaps)
        |> Enum.flat_map(fn
          {word, nil} -> [{:W, word}]
          {word, gap} -> [{:W, word}, {:WS, gap}]
        end)

      body = if lead, do: [{:WS, " "} | body], else: body
      Enum.chunk_by(body, &elem(&1, 0)) |> Enum.flat_map(&merge_trivia/1)
    end
  end

  defp merge_trivia([{:WS, _} | _] = run), do: [{:WS, Enum.map_join(run, "", &elem(&1, 1))}]
  defp merge_trivia(run), do: run

  defp trimmed_length(parts) do
    tokens = stream(parts)
    length(Grammar.Source.trimmed(tokens, :WS))
  end

  # A rule tree over `[0, n)` of the trimmed stream: the root, and below
  # it nested, ordered, possibly empty sub-ranges.
  defp record_over(n), do: StreamData.map(children_over(0, n, 3), &{:root, 0, n, &1})

  defp children_over(_from, _to, 0), do: StreamData.constant([])

  defp children_over(from, to, depth) do
    gen all(cuts <- StreamData.list_of(StreamData.integer(from..to), max_length: 4)) do
      cuts
      |> Enum.sort()
      |> Enum.chunk_every(2, 2, :discard)
      |> Enum.map(fn [a, b] -> {:r, a, b, []} end)
    end
    |> StreamData.bind(fn records ->
      records
      |> Enum.map(fn {r, a, b, []} ->
        StreamData.map(children_over(a, b, depth - 1), &{r, a, b, &1})
      end)
      |> StreamData.fixed_list()
    end)
  end

  defp nodes(%Node{} = node), do: [node | Enum.flat_map(node.children, &nodes/1)]
  defp nodes(_token), do: []
end
