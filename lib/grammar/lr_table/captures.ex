defmodule Grammar.LRTable.Captures do
  @moduledoc """
  Builds the raw-capture list `Ichor.Actions` expects (`{:token,...}`/
  `{:rule,...}`/`{:text,...}`, see `Ichor.Capture.raw_captures/0`) from
  one reduced production's own RHS entries -- shared by `Grammar.LR` (a
  single linear stack) and `Grammar.GLR` (a graph-structured one): both
  reduce the same kind of production, against the same kind of token
  stream, needing the exact same per-position classification (see
  `Grammar.LRTable.Production`'s own moduledoc for what each capture
  kind means), so this logic has exactly one place to live rather than
  two copies drifting apart.

  Built as a list, in `production.captures`' own RHS-position order,
  rather than a map -- a name's position (first occurrence, for one
  captured more than once) is real information `Ichor.Actions` relies
  on (`Ichor.Capture.position/0`) to evaluate sibling captures in true
  source order, which a plain map's own iteration order can't be
  trusted to reconstruct (it isn't guaranteed to match insertion order,
  and has been observed to differ across Erlang/OTP versions).
  """

  alias Grammar.LRTable.Production
  alias Grammar.VM.Token
  alias Ichor.Capture

  @typedoc """
  One popped RHS position: `value` is the shifted `%Token{}` (a
  terminal position) or the already-built raw-captures list of a
  reduced nonterminal; `start_pos`/`end_pos` are the token-stream span
  it covers, needed for a `:text`-kind capture regardless of which RHS
  position it sits at (not just the whole production's own span).
  """
  @type entry ::
          {value :: Token.t() | Capture.raw_captures(), start_pos :: non_neg_integer(),
           end_pos :: non_neg_integer()}

  @doc "Builds the raw-captures list for `production`, given its popped RHS `entries` in order."
  @spec build(Production.t(), [entry()], tuple()) :: Capture.raw_captures()
  def build(%Production{} = production, entries, stream) do
    Enum.reduce(production.captures, [], fn {idx, name, kind}, acc ->
      entry = Enum.at(entries, idx)
      apply_capture(acc, kind, name, entry, production.rhs, idx, stream)
    end)
  end

  defp apply_capture(acc, :token, name, {%Token{} = token, _s, _e}, _rhs, _idx, _stream) do
    value = if is_nil(token.capture), do: {:token, token.name, token.text}, else: token.capture
    merge(acc, name, value)
  end

  defp apply_capture(acc, :rule, name, {captures, _s, _e}, rhs, idx, _stream) do
    {:nonterminal, ref_name} = Enum.at(rhs, idx)
    merge(acc, name, {:rule, ref_name, captures})
  end

  defp apply_capture(acc, :text, name, {_value, start_pos, end_pos}, _rhs, _idx, stream) do
    merge(acc, name, {:text, concat_text(stream, start_pos, end_pos)})
  end

  defp apply_capture(acc, :splice, _name, {captures, _s, _e}, _rhs, _idx, _stream) do
    Enum.reduce(captures, acc, fn {k, v}, acc2 -> merge(acc2, k, v) end)
  end

  defp concat_text(stream, start_pos, end_pos) do
    Enum.map_join(start_pos..(end_pos - 1)//1, "", fn i -> elem(stream, i).text end)
  end

  @doc """
  The first/second/third+ list-promotion rule every raw-capture builder
  in Ichor uses (`Grammar.Native.Runtime.Parser.merge_captures/2`,
  mirrored here for the LR/GLR side): a name captured more than once
  naturally becomes a list without knowing the eventual count in
  advance. A new name is appended at the end, landing at its
  first-occurrence RHS position relative to whatever's already there
  (`build/3` calls this in RHS order); a repeat name updates its
  existing entry in place, not moving it.
  """
  @spec merge(Capture.raw_captures(), atom(), term()) :: Capture.raw_captures()
  def merge(captures, name, value) do
    case List.keyfind(captures, name, 0) do
      nil ->
        captures ++ [{name, value}]

      {^name, existing} when is_list(existing) ->
        List.keyreplace(captures, name, 0, {name, existing ++ [value]})

      {^name, existing} ->
        List.keyreplace(captures, name, 0, {name, [existing, value]})
    end
  end
end
