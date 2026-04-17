defmodule Recollect.SchemaFit do
  @moduledoc """
  Schema fit computation for new entries.

  Computes how well new content fits existing knowledge patterns.
  Familiar memories consolidate faster; novel ones decay faster if unused.
  """

  alias Recollect.SchemaIndex

  @doc """
  Compute schema fit score for new content. Returns 0.0..1.0.
  Uses ETS for O(1) tag frequency lookup.
  """
  def compute(content, tags, scope_id) when is_binary(content) do
    tag_freq = SchemaIndex.tag_frequency()
    n = SchemaIndex.entry_count()

    if n == 0 do
      0.5
    else
      tag_score = compute_tag_fit(tags, tag_freq, n)
      content_score = compute_content_fit(content, scope_id)

      0.6 * tag_score + 0.4 * content_score
    end
  end

  def compute(_content, _tags, _scope_id), do: 0.5

  defp compute_tag_fit(tags, tag_freq, n) when is_list(tags) do
    if Enum.empty?(tags) do
      0.5
    else
      weighted_overlap =
        Enum.reduce(tags, 0, fn tag, acc ->
          freq = Map.get(tag_freq, tag, 0)

          if freq > 0 do
            idf = :math.log(n / freq) + 1
            acc + idf
          else
            acc
          end
        end)

      max_idf = :math.log(n + 1) + 1
      total_weight = length(tags) * max_idf

      if total_weight > 0 do
        min(1.0, weighted_overlap / total_weight * 2)
      else
        0.0
      end
    end
  end

  defp compute_tag_fit(_tags, _tag_freq, _n), do: 0.5

  defp compute_content_fit(content, scope_id) do
    new_tokens = Recollect.Util.tokenize(content)

    if Enum.empty?(new_tokens) do
      0.5
    else
      repo = Recollect.Config.repo()

      case repo.query(
             """
               SELECT content FROM recollect_entries
               WHERE scope_id = $1 AND entry_type != 'archived'
               ORDER BY inserted_at DESC
               LIMIT 500
             """,
             [Recollect.Util.uuid_to_bin(scope_id)]
           ) do
        {:ok, %{rows: rows}} ->
          entries = Enum.map(rows, fn [content] -> content end)

          matches =
            Enum.count(entries, fn entry_content ->
              entry_tokens = Recollect.Util.tokenize(entry_content)
              Recollect.Util.jaccard(new_tokens, entry_tokens) > 0.2
            end)

          m = length(entries)
          min(1.0, matches / max(5, m * 0.1))

        _ ->
          0.5
      end
    end
  end
end
