defmodule Grammar.LRTable.CapturesTest do
  use ExUnit.Case, async: true

  alias Grammar.LRTable.Captures
  alias Grammar.LRTable.Production
  alias Grammar.VM.Token

  # The shape `build/3` gives, without the positions it records --
  # those are "recorded positions"' own subject.
  defp build(production, entries, stream),
    do: Ichor.Capture.plain(Captures.build(production, entries, stream))

  defp tok(name, text, opts \\ []) do
    %Token{name: name, text: text, line: 1, column: 1, capture: Keyword.get(opts, :capture)}
  end

  describe "build/3: recorded positions" do
    test "every value a production captures records the token range it matched" do
      production = %Production{
        id: 0,
        lhs: :r,
        rhs: [{:terminal, :A}, {:nonterminal, :expr}, {:terminal, :B}],
        captures: [{0, :a, :token}, {1, :sub, :rule}, {2, :b, :text}]
      }

      stream = {tok(:A, "a"), tok(:NUM, "1"), tok(:NUM, "2"), tok(:B, "b")}
      entries = [{tok(:A, "a"), 0, 1}, {[n: {:token, :NUM, "1"}], 1, 3}, {tok(:B, "b"), 3, 4}]

      assert Captures.build(production, entries, stream) == [
               a: Ichor.Capture.at({:token, :A, "a"}, 0, 1),
               sub: Ichor.Capture.at({:rule, :expr, [n: {:token, :NUM, "1"}]}, 1, 3),
               b: Ichor.Capture.at({:text, "b"}, 3, 4)
             ]
    end

    test "a helper's spliced captures keep the ranges they were recorded with" do
      production = %Production{
        id: 0,
        lhs: :r,
        rhs: [{:nonterminal, :"$star_1"}],
        captures: [{0, nil, :splice}]
      }

      recorded = Ichor.Capture.at({:token, :NUM, "1"}, 0, 1)
      entries = [{[n: recorded], 0, 1}]

      assert Captures.build(production, entries, {}) == [n: recorded]
    end
  end

  describe "build/3: :token capture" do
    test "an ordinary token becomes {:token, name, text}" do
      production = %Production{
        id: 0,
        lhs: :r,
        rhs: [{:terminal, :A}],
        captures: [{0, :x, :token}]
      }

      entries = [{tok(:A, "a"), 0, 1}]

      assert build(production, entries, {}) == [x: {:token, :A, "a"}]
    end

    test "a CustomLexeme-attached capture override is used verbatim instead" do
      production = %Production{
        id: 0,
        lhs: :r,
        rhs: [{:terminal, :A}],
        captures: [{0, :x, :token}]
      }

      entries = [{tok(:A, "a", capture: {:text, "override"}), 0, 1}]

      assert build(production, entries, {}) == [x: {:text, "override"}]
    end
  end

  describe "build/3: :rule capture" do
    test "becomes {:rule, ref_name, sub_captures} -- ref_name from rhs, not the capture name" do
      production = %Production{
        id: 0,
        lhs: :r,
        rhs: [{:nonterminal, :expr}],
        captures: [{0, :sub, :rule}]
      }

      entries = [{[n: {:token, :NUM, "1"}], 0, 1}]

      assert build(production, entries, {}) ==
               [sub: {:rule, :expr, [n: {:token, :NUM, "1"}]}]
    end
  end

  describe "build/3: :text capture" do
    test "concatenates the raw token text across the whole span" do
      production = %Production{
        id: 0,
        lhs: :r,
        rhs: [{:nonterminal, :whatever}],
        captures: [{0, :span, :text}]
      }

      stream = {tok(:A, "foo"), tok(:B, "bar"), tok(:C, "baz")}
      entries = [{:ignored, 0, 2}]

      assert build(production, entries, stream) == [span: {:text, "foobar"}]
    end

    test "an empty span concatenates to an empty string" do
      production = %Production{
        id: 0,
        lhs: :r,
        rhs: [{:nonterminal, :whatever}],
        captures: [{0, :span, :text}]
      }

      entries = [{:ignored, 0, 0}]
      assert build(production, entries, {}) == [span: {:text, ""}]
    end
  end

  describe "build/3: :splice capture" do
    test "merges every key of the nested captures list directly into the result" do
      production = %Production{
        id: 0,
        lhs: :r,
        rhs: [{:nonterminal, :helper}],
        captures: [{0, nil, :splice}]
      }

      nested = [op: [{:token, :PLUS, "+"}], term: {:token, :NUM, "1"}]
      entries = [{nested, 0, 1}]

      assert build(production, entries, {}) == nested
    end

    test "splices into an already-populated key, promoting to a list like any other merge" do
      production = %Production{
        id: 0,
        lhs: :r,
        rhs: [{:terminal, :NUM}, {:nonterminal, :helper}],
        captures: [{0, :term, :token}, {1, :splice, :splice}]
      }

      entries = [
        {tok(:NUM, "1"), 0, 1},
        {[term: {:token, :NUM, "2"}], 1, 2}
      ]

      assert build(production, entries, {}) == [
               term: [{:token, :NUM, "1"}, {:token, :NUM, "2"}]
             ]
    end

    # `doc := entry+` with three entries: the helper holds `[b, c]`, the
    # production `a` -- the list is one more run of the same name, never
    # a single value nested inside it.
    test "splices a list into an already-populated key as its elements, not as one value" do
      production = %Production{
        id: 0,
        lhs: :r,
        rhs: [{:terminal, :NUM}, {:nonterminal, :helper}],
        captures: [{0, :term, :token}, {1, nil, :splice}]
      }

      entries = [
        {tok(:NUM, "1"), 0, 1},
        {[term: [{:token, :NUM, "2"}, {:token, :NUM, "3"}]], 1, 3}
      ]

      assert build(production, entries, {}) == [
               term: [{:token, :NUM, "1"}, {:token, :NUM, "2"}, {:token, :NUM, "3"}]
             ]
    end
  end

  describe "build/3: the same capture name at multiple RHS positions promotes to a list" do
    test "two occurrences: [first, second]" do
      production = %Production{
        id: 0,
        lhs: :r,
        rhs: [{:terminal, :A}, {:terminal, :B}],
        captures: [{0, :x, :token}, {1, :x, :token}]
      }

      entries = [{tok(:A, "a"), 0, 1}, {tok(:B, "b"), 1, 2}]

      assert build(production, entries, {}) == [
               x: [{:token, :A, "a"}, {:token, :B, "b"}]
             ]
    end

    test "three occurrences: appended, not re-wrapped" do
      production = %Production{
        id: 0,
        lhs: :r,
        rhs: [{:terminal, :A}, {:terminal, :B}, {:terminal, :C}],
        captures: [{0, :x, :token}, {1, :x, :token}, {2, :x, :token}]
      }

      entries = [{tok(:A, "a"), 0, 1}, {tok(:B, "b"), 1, 2}, {tok(:C, "c"), 2, 3}]

      assert build(production, entries, {}) == [
               x: [{:token, :A, "a"}, {:token, :B, "b"}, {:token, :C, "c"}]
             ]
    end
  end

  describe "build/3: distinct names land in first-occurrence RHS order" do
    test "a repeated first name doesn't move a later distinct name" do
      production = %Production{
        id: 0,
        lhs: :r,
        rhs: [{:terminal, :A}, {:terminal, :B}, {:terminal, :C}],
        captures: [{0, :x, :token}, {1, :y, :token}, {2, :x, :token}]
      }

      entries = [{tok(:A, "a"), 0, 1}, {tok(:B, "b"), 1, 2}, {tok(:C, "c"), 2, 3}]

      assert build(production, entries, {}) == [
               x: [{:token, :A, "a"}, {:token, :C, "c"}],
               y: {:token, :B, "b"}
             ]
    end
  end

  describe "build/3: an empty captures list builds an empty list" do
    test "no captures declared, whatever the entries" do
      production = %Production{id: 0, lhs: :r, rhs: [{:terminal, :A}], captures: []}
      assert build(production, [{tok(:A, "a"), 0, 1}], {}) == []
    end
  end

  describe "merge/3" do
    test "a new key is set as-is, appended at the end" do
      assert Captures.merge([], :x, 1) == [x: 1]
      assert Captures.merge([a: 1], :b, 2) == [a: 1, b: 2]
    end

    test "a second occurrence wraps both into a list, in place" do
      assert Captures.merge([x: 1], :x, 2) == [x: [1, 2]]
      assert Captures.merge([a: 1, x: 1, b: 2], :x, 9) == [a: 1, x: [1, 9], b: 2]
    end

    test "a third+ occurrence appends to the existing list" do
      assert Captures.merge([x: [1, 2]], :x, 3) == [x: [1, 2, 3]]
    end

    test "unrelated keys are untouched" do
      assert Captures.merge([a: 1], :b, 2) == [a: 1, b: 2]
    end
  end
end
