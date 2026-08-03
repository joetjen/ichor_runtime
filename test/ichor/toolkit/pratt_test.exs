defmodule Ichor.Toolkit.PrattTest do
  use ExUnit.Case, async: true

  alias Ichor.Toolkit.Pratt

  # A minimal token-tuple parser: {:num, n} primaries, {:op, name}
  # operators, `build` reifying each reduction as a plain tagged tuple
  # instead of actually evaluating -- makes the *shape* of what got
  # parsed (association, precedence) directly assertable.
  defp run(tokens, table, min_prec \\ 0) do
    tokens = List.to_tuple(tokens)
    at = fn pos -> if pos < tuple_size(tokens), do: elem(tokens, pos), else: nil end

    callbacks = %{
      peek_op: fn pos ->
        case at.(pos) do
          {:op, name} -> {name, pos + 1}
          _ -> nil
        end
      end,
      parse_primary: fn pos ->
        case at.(pos) do
          {:num, n} -> {:ok, pos + 1, n}
          _ -> :fail
        end
      end,
      build: fn
        :prefix, op, [a] -> {:prefix, op, a}
        :infix, op, [a, b] -> {:infix, op, a, b}
        :postfix, op, [a] -> {:postfix, op, a}
      end
    }

    Pratt.parse(table, 0, callbacks, min_prec)
  end

  defp num(n), do: {:num, n}
  defp op(name), do: {:op, name}

  describe "new/0, prefix/3, infix/3,4, postfix/3" do
    test "builds a table entry per registered fixity" do
      table =
        Pratt.new()
        |> Pratt.prefix("-", 100)
        |> Pratt.infix("+", 10)
        |> Pratt.postfix("!", 30)

      assert table["-"] == %{prefix: 100}
      assert table["+"] == %{infix: {10, :left}}
      assert table["!"] == %{postfix: 30}
    end

    test "infix/4 defaults to :left associativity, infix/4 can override it" do
      table = Pratt.new() |> Pratt.infix("+", 10) |> Pratt.infix("^", 20, :right)
      assert table["+"] == %{infix: {10, :left}}
      assert table["^"] == %{infix: {20, :right}}
    end

    test "registering multiple fixities for the same operator merges into one entry" do
      table = Pratt.new() |> Pratt.infix("%", 20) |> Pratt.postfix("%", 30)
      assert table["%"] == %{infix: {20, :left}, postfix: 30}
    end
  end

  describe "parse/4: a bare primary, no operators at all" do
    test "returns the primary's own value, position advanced past it" do
      assert run([num(42)], Pratt.new()) == {:ok, 1, 42}
    end

    test "stops after the primary even if trailing tokens remain unconsumed" do
      table = Pratt.new()
      assert run([num(1), num(2)], table) == {:ok, 1, 1}
    end
  end

  describe "parse/4: precedence" do
    test "a higher-precedence operator binds tighter: 2 + 3 * 4 is 2 + (3 * 4)" do
      table = Pratt.new() |> Pratt.infix("+", 10) |> Pratt.infix("*", 20)

      assert run([num(2), op("+"), num(3), op("*"), num(4)], table) ==
               {:ok, 5, {:infix, "+", 2, {:infix, "*", 3, 4}}}
    end
  end

  describe "parse/4: associativity" do
    test "left-associative: 10 - 3 - 2 groups as (10 - 3) - 2" do
      table = Pratt.new() |> Pratt.infix("-", 10, :left)

      assert run([num(10), op("-"), num(3), op("-"), num(2)], table) ==
               {:ok, 5, {:infix, "-", {:infix, "-", 10, 3}, 2}}
    end

    test "right-associative: 2 ^ 3 ^ 2 groups as 2 ^ (3 ^ 2)" do
      table = Pratt.new() |> Pratt.infix("^", 10, :right)

      assert run([num(2), op("^"), num(3), op("^"), num(2)], table) ==
               {:ok, 5, {:infix, "^", 2, {:infix, "^", 3, 2}}}
    end
  end

  describe "parse/4: prefix and postfix" do
    test "a registered prefix operator applies to the operand that follows it" do
      table = Pratt.new() |> Pratt.prefix("-", 100)
      assert run([op("-"), num(5)], table) == {:ok, 2, {:prefix, "-", 5}}
    end

    test "a registered postfix operator applies to the operand before it" do
      table = Pratt.new() |> Pratt.postfix("!", 30)
      assert run([num(5), op("!")], table) == {:ok, 2, {:postfix, "!", 5}}
    end

    test "an unregistered leading operator token falls through to parse_primary and fails" do
      table = Pratt.new()
      assert run([op("-"), num(5)], table) == :fail
    end
  end

  describe "parse/4: the infix/postfix ambiguity" do
    test "without can_start_operand?, an operator registered as both raises ArgumentError" do
      table = Pratt.new() |> Pratt.infix("%", 20) |> Pratt.postfix("%", 30)

      assert_raise ArgumentError, ~r/registered as both :infix and :postfix/, fn ->
        run([num(5), op("%"), num(2)], table)
      end
    end

    test "with can_start_operand?, resolves to infix when a valid operand follows" do
      tokens = {num(5), op("%"), num(2)}
      at = fn pos -> if pos < tuple_size(tokens), do: elem(tokens, pos), else: nil end
      table = Pratt.new() |> Pratt.infix("%", 20) |> Pratt.postfix("%", 30)

      callbacks = %{
        peek_op: fn pos ->
          case at.(pos) do
            {:op, name} -> {name, pos + 1}
            _ -> nil
          end
        end,
        parse_primary: fn pos ->
          case at.(pos) do
            {:num, n} -> {:ok, pos + 1, n}
            _ -> :fail
          end
        end,
        can_start_operand?: fn pos -> match?({:num, _}, at.(pos)) end,
        build: fn
          :infix, op, [a, b] -> {:infix, op, a, b}
          :postfix, op, [a] -> {:postfix, op, a}
        end
      }

      assert Pratt.parse(table, 0, callbacks) == {:ok, 3, {:infix, "%", 5, 2}}
    end

    test "with can_start_operand?, resolves to postfix when no valid operand follows" do
      tokens = {num(5), op("%")}
      at = fn pos -> if pos < tuple_size(tokens), do: elem(tokens, pos), else: nil end
      table = Pratt.new() |> Pratt.infix("%", 20) |> Pratt.postfix("%", 30)

      callbacks = %{
        peek_op: fn pos ->
          case at.(pos) do
            {:op, name} -> {name, pos + 1}
            _ -> nil
          end
        end,
        parse_primary: fn pos ->
          case at.(pos) do
            {:num, n} -> {:ok, pos + 1, n}
            _ -> :fail
          end
        end,
        can_start_operand?: fn pos -> match?({:num, _}, at.(pos)) end,
        build: fn
          :infix, op, [a, b] -> {:infix, op, a, b}
          :postfix, op, [a] -> {:postfix, op, a}
        end
      }

      assert Pratt.parse(table, 0, callbacks) == {:ok, 2, {:postfix, "%", 5}}
    end

    defp dual_callbacks(tokens) do
      at = fn pos -> if pos < tuple_size(tokens), do: elem(tokens, pos), else: nil end

      %{
        peek_op: fn pos ->
          case at.(pos) do
            {:op, name} -> {name, pos + 1}
            _ -> nil
          end
        end,
        parse_primary: fn pos ->
          case at.(pos) do
            {:num, n} -> {:ok, pos + 1, n}
            _ -> :fail
          end
        end,
        build: fn
          :infix, op, [a, b] -> {:infix, op, a, b}
          :postfix, op, [a] -> {:postfix, op, a}
        end
      }
    end

    test "when min_prec rules out postfix but not infix, applies infix without needing can_start_operand?" do
      # Both fixities registered (so parse_led's own resolve_led_conflict
      # branch is reached), but at this call's min_prec only infix
      # clears the bar -- no ambiguity left to resolve, so this must
      # not raise even though no can_start_operand? callback is given.
      table = Pratt.new() |> Pratt.infix("%", 20) |> Pratt.postfix("%", 10)
      callbacks = dual_callbacks({num(5), op("%"), num(2)})

      assert Pratt.parse(table, 0, callbacks, 15) == {:ok, 3, {:infix, "%", 5, 2}}
    end

    test "when min_prec rules out infix but not postfix, applies postfix without needing can_start_operand?" do
      table = Pratt.new() |> Pratt.infix("%", 10) |> Pratt.postfix("%", 20)
      callbacks = dual_callbacks({num(5), op("%")})

      assert Pratt.parse(table, 0, callbacks, 15) == {:ok, 2, {:postfix, "%", 5}}
    end

    test "when min_prec rules out both fixities, the operator is left unconsumed" do
      table = Pratt.new() |> Pratt.infix("%", 20) |> Pratt.postfix("%", 20)
      callbacks = dual_callbacks({num(5), op("%"), num(2)})

      assert Pratt.parse(table, 0, callbacks, 25) == {:ok, 1, 5}
    end
  end

  describe "parse/4: min_prec" do
    test "an operator below min_prec is left unconsumed rather than applied" do
      table = Pratt.new() |> Pratt.infix("+", 10)
      assert run([num(2), op("+"), num(3)], table, 15) == {:ok, 1, 2}
    end

    test "an operator at or above min_prec is still applied" do
      table = Pratt.new() |> Pratt.infix("+", 10)
      assert run([num(2), op("+"), num(3)], table, 10) == {:ok, 3, {:infix, "+", 2, 3}}
    end
  end

  describe "parse/4: a full worked expression" do
    test "prefix, infix (mixed precedence), and postfix together: -2 + 3 * 4!" do
      table =
        Pratt.new()
        |> Pratt.prefix("-", 100)
        |> Pratt.infix("+", 10)
        |> Pratt.infix("*", 20)
        |> Pratt.postfix("!", 30)

      tokens = [op("-"), num(2), op("+"), num(3), op("*"), num(4), op("!")]

      assert run(tokens, table) ==
               {:ok, 7, {:infix, "+", {:prefix, "-", 2}, {:infix, "*", 3, {:postfix, "!", 4}}}}
    end
  end
end
