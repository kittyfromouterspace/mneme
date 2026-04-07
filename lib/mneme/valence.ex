defmodule Mneme.Valence do
  @moduledoc """
  Emotional valence inference and handling.

  In human memory, errors and breakthroughs get priority encoding.
  The amygdala modulates hippocampal consolidation based on emotional significance.
  """

  @doc """
  Infer emotional valence from entry options.

  ## Examples

      iex> Mneme.Valence.infer(entry_type: "outcome", metadata: %{success: true})
      :positive

      iex> Mneme.Valence.infer(metadata: %{error: true})
      :negative

      iex> Mneme.Valence.infer(emotional_valence: :critical)
      :critical

      iex> Mneme.Valence.infer([])
      :neutral
  """
  def infer(opts) when is_list(opts) do
    cond do
      opts[:emotional_valence] -> opts[:emotional_valence]
      opts[:entry_type] == "outcome" and opts[:metadata]["success"] == true -> :positive
      opts[:entry_type] == "outcome" and opts[:metadata]["success"] == false -> :negative
      opts[:metadata]["error"] == true -> :negative
      opts[:metadata]["critical"] == true -> :critical
      true -> :neutral
    end
  end

  def infer(_), do: :neutral
end
