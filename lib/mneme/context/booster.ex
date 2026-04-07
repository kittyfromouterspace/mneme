defmodule Mneme.Search.ContextBooster do
  @moduledoc """
  Calculate context boost for search results based on entry hints matching current context.
  """

  @default_boost 0.15
  @max_boost 0.5

  @doc """
  Calculate context boost for an entry given its context hints and current context.

  ## Parameters
  - `entry_hints` - Map of context hints from the entry (e.g., %{repo: "owner/repo", os: "linux"})
  - `current_context` - Map of currently detected context

  ## Returns
  A float between 0.0 and @max_boost representing the boost to add to the score.
  """
  def boost(entry_hints, current_context) do
    cond do
      map_size(entry_hints) == 0 ->
        0.0

      map_size(current_context) == 0 ->
        0.0

      true ->
        matches = Mneme.Context.Detector.context_matches(entry_hints, current_context)

        if matches == 0 do
          0.0
        else
          min(@default_boost * matches, @max_boost)
        end
    end
  end

  @doc "Apply context boost to a list of search results."
  def apply_boost(results, current_context) when is_list(results) do
    Enum.map(results, fn entry ->
      entry_hints = entry[:context_hints] || entry["context_hints"] || %{}

      boost = boost(entry_hints, current_context)

      # Update score - support both atom and string keys
      original_score =
        entry[:score] || entry["score"] || entry[:similarity] || entry["similarity"] || 0.0

      Map.put(entry, :score, original_score + boost)
      |> Map.put("score", original_score + boost)
    end)
    |> Enum.sort_by(&(&1[:score] || &1["score"] || 0), :desc)
  end

  @doc "Calculate boost with custom parameters."
  def boost(entry_hints, current_context, opts) do
    boost_factor = Keyword.get(opts, :boost_factor, @default_boost)
    max_boost = Keyword.get(opts, :max_boost, @max_boost)

    cond do
      map_size(entry_hints) == 0 ->
        0.0

      map_size(current_context) == 0 ->
        0.0

      true ->
        matches = Mneme.Context.Detector.context_matches(entry_hints, current_context)
        min(boost_factor * matches, max_boost)
    end
  end
end
