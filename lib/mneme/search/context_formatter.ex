defmodule Mneme.Search.ContextFormatter do
  @moduledoc """
  Formats search results as text suitable for LLM system prompt injection.
  """

  @doc "Format a context pack into readable text for LLM consumption."
  def format(%{} = pack) do
    sections =
      []
      |> maybe_add_chunks(pack[:chunks])
      |> maybe_add_entries(pack[:entries])
      |> maybe_add_related(pack[:related_entries])
      |> maybe_add_entities(pack[:entities])
      |> maybe_add_relations(pack[:relations])

    if sections == [] do
      ""
    else
      Enum.join(sections, "\n\n")
    end
  end

  defp maybe_add_chunks(acc, chunks) when is_list(chunks) and chunks != [] do
    text =
      chunks
      |> Enum.with_index(1)
      |> Enum.map(fn {chunk, idx} ->
        score = chunk["score"] || chunk[:score] || 0.0
        content = chunk["content"] || chunk[:content] || ""
        "[Chunk #{idx} (score: #{Float.round(score / 1, 3)})] #{content}"
      end)
      |> Enum.join("\n\n")

    acc ++ ["## Relevant Memory Chunks\n#{text}"]
  end

  defp maybe_add_chunks(acc, _), do: acc

  defp maybe_add_entries(acc, entries) when is_list(entries) and entries != [] do
    text =
      entries
      |> Enum.with_index(1)
      |> Enum.map(fn {entry, idx} ->
        score = entry["score"] || entry[:score] || 0.0
        content = entry["content"] || entry[:content] || ""
        summary = entry["summary"] || entry[:summary]
        type = entry["entry_type"] || entry[:entry_type] || "note"
        display = summary || String.slice(content, 0, 200)
        "[#{idx}] [#{type}] (score: #{Float.round(score / 1, 3)}) #{display}"
      end)
      |> Enum.join("\n")

    acc ++ ["## Relevant Knowledge\n#{text}"]
  end

  defp maybe_add_entries(acc, _), do: acc

  defp maybe_add_related(acc, related) when is_list(related) and related != [] do
    text =
      related
      |> Enum.map(fn entry ->
        content = entry["content"] || entry[:content] || ""
        type = entry["entry_type"] || entry[:entry_type] || "note"
        summary = entry["summary"] || entry[:summary]
        display = summary || String.slice(content, 0, 200)
        "[Related] [#{type}] #{display}"
      end)
      |> Enum.join("\n")

    acc ++ ["## Related Knowledge\n#{text}"]
  end

  defp maybe_add_related(acc, _), do: acc

  defp maybe_add_entities(acc, entities) when is_list(entities) and entities != [] do
    text =
      entities
      |> Enum.uniq_by(fn e -> e["name"] || e[:name] end)
      |> Enum.take(20)
      |> Enum.map(fn e ->
        name = e["name"] || e[:name] || "unknown"
        type = e["entity_type"] || e[:entity_type] || "unknown"
        desc = e["description"] || e[:description] || ""
        "- #{name} (#{type}): #{desc}"
      end)
      |> Enum.join("\n")

    acc ++ ["## Known Entities\n#{text}"]
  end

  defp maybe_add_entities(acc, _), do: acc

  defp maybe_add_relations(acc, relations) when is_list(relations) and relations != [] do
    text =
      relations
      |> Enum.take(20)
      |> Enum.map(fn r ->
        from = r[:from_id] || r["from_id"]
        to = r[:to_id] || r["to_id"]
        type = r[:relation_type] || r["relation_type"]
        "- #{from} --[#{type}]--> #{to}"
      end)
      |> Enum.join("\n")

    acc ++ ["## Known Relationships\n#{text}"]
  end

  defp maybe_add_relations(acc, _), do: acc
end
