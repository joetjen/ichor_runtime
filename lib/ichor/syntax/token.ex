defmodule Ichor.Syntax.Token do
  @moduledoc """
  One token in a lossless tree (`Ichor.Syntax`): every token of the input
  is one, punctuation, literals and trivia included.

  `name` is the token's name in the grammar -- `ANON_n` for a literal
  the grammar wrote inline. `trivia` is true for the grammar's `@skip`
  token: the comments and whitespace the ordinary parser steps over.
  `offset` is in bytes; `line` and `column` are the tokenizer's own.
  """

  @type t :: %__MODULE__{
          name: atom(),
          text: String.t(),
          trivia: boolean(),
          offset: non_neg_integer(),
          line: pos_integer(),
          column: pos_integer()
        }

  defstruct [:name, :text, :offset, :line, :column, trivia: false]
end
