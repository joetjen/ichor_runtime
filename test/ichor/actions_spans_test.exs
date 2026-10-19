defmodule Ichor.ActionsSpansTest do
  use ExUnit.Case, async: true

  doctest Ichor.Capture

  alias Grammar.Source.Locator
  alias Ichor.{Capture, Error}

  defmodule RefusingActions do
    @moduledoc "Refuses a float key and a `BAD` token, and refuses the key `placed` with a position of its own; answers the spans of a `:spans` rule's captures."
    @behaviour Ichor.Actions

    alias Ichor.Error

    @impl true
    def handle_rule(:entry, %{key: %{node: {:token, :FLOAT, _}}}, _ctx),
      do: {:error, Error.new(message: "a float can't be a key", stage: :action, data: :float_key)}

    def handle_rule(:entry, %{key: %{node: {:token, :IDENT, "placed"}}}, _ctx),
      do: {:error, Error.new(message: "placed by the action", stage: :action, line: 9, column: 9)}

    def handle_rule(:spans, captures, ctx),
      do: {:ok, Map.new(captures, fn {name, cap} -> {name, spans_of(cap)} end), ctx}

    @impl true
    def handle_token(:BAD, _text, _ctx),
      do: {:error, Error.new(message: "bad token", stage: :action)}

    defp spans_of(caps) when is_list(caps), do: Enum.map(caps, & &1.span)
    defp spans_of(cap), do: cap.span
  end

  defmodule NodeActions do
    @moduledoc "Answers the root's raw nodes."
    @behaviour Ichor.Actions
    @impl true
    def handle_rule(:map, %{entries: caps}, ctx), do: {:ok, Enum.map(caps, & &1.node), ctx}
  end

  defp token(name, text, line, column),
    do: %Grammar.VM.Token{name: name, text: text, line: line, column: column}

  @input "%{a: 1\n 1.5 => 2}"

  # `%{a: 1\n 1.5 => 2}`, as an LR stream has it: no skip tokens.
  defp stream do
    {token(:"%{", "%{", 1, 1), token(:IDENT, "a", 1, 3), token(:":", ":", 1, 4),
     token(:INT, "1", 1, 6), token(:FLOAT, "1.5", 2, 2), token(:"=>", "=>", 2, 6),
     token(:INT, "2", 2, 9), token(:"}", "}", 2, 10)}
  end

  defp entry(key, key_at, value, value_at, from, to) do
    Capture.at(
      {:rule, :entry,
       [
         key: Capture.at(key, key_at, key_at + 1),
         value: Capture.at(value, value_at, value_at + 1)
       ]},
      from,
      to
    )
  end

  defp map_captures(second_key) do
    [
      entries: [
        entry({:token, :IDENT, "a"}, 1, {:token, :INT, "1"}, 3, 1, 4),
        entry(second_key, 4, {:token, :INT, "2"}, 6, 4, 7)
      ]
    ]
  end

  defp evaluate(captures, actions \\ RefusingActions) do
    Ichor.Actions.evaluate(:map, captures, actions, nil, %{},
      locator: Locator.new(stream(), @input)
    )
  end

  describe "an action's error with no position" do
    test "is placed where the rule that refused matched" do
      assert {:error, %Error{} = error} = evaluate(map_captures({:token, :FLOAT, "1.5"}))
      assert {error.line, error.column} == {2, 2}
    end

    test "is shown with the line it is on and a caret" do
      assert {:error, %Error{context_lines: context}} =
               evaluate(map_captures({:token, :FLOAT, "1.5"}))

      assert context == "2 |  1.5 => 2}\n  |  ^"
    end

    test "keeps everything else the action gave it" do
      assert {:error, %Error{message: "a float can't be a key", stage: :action, data: :float_key}} =
               evaluate(map_captures({:token, :FLOAT, "1.5"}))
    end

    test "from a token's action is placed where the token matched" do
      assert {:error, %Error{message: "bad token"} = error} =
               evaluate(map_captures({:token, :BAD, "1.5"}))

      assert {error.line, error.column} == {2, 2}
    end

    test "from a nested rule keeps the innermost place, not its parents'" do
      captures = [
        outer:
          Capture.at(
            {:rule, :wrapper,
             [inner: entry({:token, :FLOAT, "1.5"}, 4, {:token, :INT, "2"}, 6, 4, 7)]},
            0,
            8
          )
      ]

      assert {:error, %Error{line: 2, column: 2}} = evaluate(captures)
    end

    test "at the root rule is placed at the root's range" do
      captures = [entries: [entry({:token, :FLOAT, "1.5"}, 4, {:token, :INT, "2"}, 6, 4, 7)]]

      assert {:error, %Error{line: 1, column: 1}} =
               Ichor.Actions.evaluate(
                 :entry,
                 [key: Capture.at({:token, :FLOAT, "1.5"}, 4, 5)],
                 RefusingActions,
                 nil,
                 %{},
                 locator: Locator.new(stream(), @input)
               )

      assert {:error, %Error{line: 2, column: 2}} = evaluate(captures)
    end

    test "is left without one when the parse recorded no positions" do
      plain = [
        entries: [{:rule, :entry, [key: {:token, :FLOAT, "1.5"}, value: {:token, :INT, "2"}]}]
      ]

      assert {:error, %Error{line: nil, column: nil, context_lines: nil}} =
               Ichor.Actions.evaluate(:map, plain, RefusingActions, nil)
    end
  end

  test "an action's error with a position of its own keeps it" do
    assert {:error, %Error{line: 9, column: 9}} =
             evaluate(map_captures({:token, :IDENT, "placed"}))
  end

  describe "a capture's span" do
    test "says where the capture matched, as {line, column, length}" do
      captures = [
        key: Capture.at({:token, :FLOAT, "1.5"}, 4, 5),
        rest: Capture.at({:text, "=> 2"}, 5, 7),
        many: [Capture.at({:token, :INT, "1"}, 3, 4), Capture.at({:token, :INT, "2"}, 6, 7)]
      ]

      assert {:ok, spans, nil} =
               Ichor.Actions.evaluate(:spans, captures, RefusingActions, nil, %{},
                 locator: Locator.new(stream(), @input)
               )

      assert spans == %{key: {2, 2, 3}, rest: {2, 6, 4}, many: [{1, 6, 1}, {2, 9, 1}]}
    end

    test "is nil when the parse recorded no positions" do
      assert {:ok, %{key: nil}, nil} =
               Ichor.Actions.evaluate(
                 :spans,
                 [key: {:token, :FLOAT, "1.5"}],
                 RefusingActions,
                 nil
               )
    end
  end

  test "a capture's node never shows the recorded positions, however deep" do
    captures = [entries: [entry({:token, :IDENT, "a"}, 1, {:token, :INT, "1"}, 3, 1, 4)]]

    assert {:ok, [node], nil} = evaluate(captures, NodeActions)
    assert node == {:rule, :entry, [key: {:token, :IDENT, "a"}, value: {:token, :INT, "1"}]}
  end

  test "the default node's span says where its rule matched" do
    captures = [entries: [entry({:token, :IDENT, "a"}, 1, {:token, :INT, "1"}, 3, 1, 4)]]

    assert {:ok, %Ichor.Node{rule: :map, span: {1, 1, 17}, captures: %{entries: [entry]}}, nil} =
             evaluate(captures, Support.NoActions)

    assert entry.span == {1, 3, 4}
  end
end
