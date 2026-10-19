defmodule Ichor.Syntax.Node do
  @moduledoc """
  One grammar rule's match in a lossless tree (`Ichor.Syntax`): every
  token and every rule it covers, in source order.

  `offset` and `size` are in bytes, so the input this node covers is
  `binary_part(input, node.offset, node.size)`. `line` and `column` are
  where it starts, counted as the tokenizer counts them (1-based,
  columns in codepoints). A rule that matched nothing is a node with no
  children and a `size` of 0, at the place it sits in the tree.
  """

  @type t :: %__MODULE__{
          rule: atom(),
          children: [t() | Ichor.Syntax.Token.t()],
          offset: non_neg_integer(),
          size: non_neg_integer(),
          line: pos_integer(),
          column: pos_integer()
        }

  defstruct [:rule, :offset, :size, :line, :column, children: []]
end
