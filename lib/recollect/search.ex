defmodule Recollect.Search do
  @moduledoc """
  Unified search combining vector similarity, graph traversal, and edge following.
  """

  alias Recollect.Search.Graph
  alias Recollect.Search.Vector

  require Logger

  @doc """
  Hybrid search combining vector and graph results.

  Returns `{:ok, context_pack}` with chunks, entries, entities, relations.
  """
  def search(query_text, opts \\ []) do
    metadata = %{
      tier: Keyword.get(opts, :tier, :both),
      scope_id: Keyword.get(opts, :scope_id),
      owner_id: Keyword.get(opts, :owner_id)
    }

    Recollect.Telemetry.span([:recollect, :search], metadata, fn ->
      tier = Keyword.get(opts, :tier, :both)
      hops = Keyword.get(opts, :hops, 1)

      with {:ok, vector_results} <- Vector.search(query_text, opts) do
        # Separate by type
        chunks = Enum.filter(vector_results, &(&1[:result_type] == :chunk))
        entries = Enum.filter(vector_results, &(&1[:result_type] == :entry))

        # Graph expansion for Tier 1 entities
        {entities, graph_relations} =
          if tier in [:full, :both] && Keyword.has_key?(opts, :owner_id) do
            expand_graph(query_text, opts, hops)
          else
            {[], []}
          end

        # Edge following for Tier 2 entries
        related_entries =
          if tier in [:lightweight, :both] do
            entry_ids = entries |> Enum.map(& &1["id"]) |> Enum.reject(&is_nil/1)

            case Graph.follow_edges(entry_ids, hops: hops) do
              {:ok, related} -> related
              _ -> []
            end
          else
            []
          end

        context_pack = %{
          chunks: chunks,
          entries: entries,
          related_entries: related_entries,
          entities: entities,
          relations: graph_relations,
          query: query_text
        }

        {:ok, context_pack}
      end
    end)
  end

  defp expand_graph(query_text, opts, hops) do
    owner_id = Keyword.fetch!(opts, :owner_id)

    case Vector.search_entities_vec(query_text, owner_id, limit: 5) do
      {:ok, entity_results} ->
        # Expand top 3 entities via graph
        {expanded_entities, expanded_relations} =
          entity_results
          |> Enum.take(3)
          |> Enum.reduce({[], []}, fn entity, {ents, rels} ->
            entity_id = entity["id"]

            if entity_id do
              neighbors =
                case Graph.neighborhood(entity_id, owner_id: owner_id, hops: hops) do
                  {:ok, n} -> n
                  _ -> []
                end

              relations =
                case Graph.relations(entity_id, owner_id: owner_id) do
                  {:ok, r} -> r
                  _ -> []
                end

              {ents ++ neighbors, rels ++ relations}
            else
              {ents, rels}
            end
          end)

        all_entities =
          Enum.uniq_by(entity_results ++ expanded_entities, fn e -> e["id"] || e[:id] end)

        all_relations =
          Enum.uniq_by(expanded_relations, fn r -> {r[:from_id], r[:to_id], r[:relation_type]} end)

        {all_entities, all_relations}

      _ ->
        {[], []}
    end
  end
end
