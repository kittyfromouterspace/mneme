defmodule Mneme.Pipeline.Extractor do
  @moduledoc """
  Extracts entities and relationships from text chunks using LLM structured output.
  Deduplicates and persists results with mention counting.
  """

  import Ecto.Query
  alias Mneme.Config
  alias Mneme.Schema.{Entity, Relation}

  require Logger

  @entity_types Entity.entity_types()
  @relation_types Relation.relation_types()

  @doc """
  Extract entities and relations from a chunk's content using the configured provider.
  """
  def extract_from_chunk(chunk_content, opts \\ []) do
    start_time = System.monotonic_time()
    provider = Config.extraction_provider()
    provider_opts = Keyword.merge(Config.extraction_opts(), opts)
    result = provider.extract(chunk_content, provider_opts)
    duration = System.monotonic_time() - start_time

    case result do
      {:ok, %{entities: entities, relations: relations}} ->
        Mneme.Telemetry.event([:mneme, :extract, :stop], %{
          duration: duration,
          entities_count: length(entities),
          relations_count: length(relations)
        })

      _ ->
        Mneme.Telemetry.event([:mneme, :extract, :stop], %{
          duration: duration,
          entities_count: 0,
          relations_count: 0
        })
    end

    result
  end

  @doc """
  Persist extracted entities into the database, deduplicating by name+type
  within the same collection. Returns `{:ok, [entity]}`.
  """
  def persist_entities(entities, opts) do
    collection_id = Keyword.fetch!(opts, :collection_id)
    owner_id = Keyword.fetch!(opts, :owner_id)
    scope_id = Keyword.get(opts, :scope_id)
    repo = Config.repo()

    Enum.reduce_while(entities, {:ok, []}, fn entity_data, {:ok, acc} ->
      case upsert_entity(entity_data, collection_id, owner_id, scope_id, repo) do
        {:ok, entity} -> {:cont, {:ok, acc ++ [entity]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Persist extracted relations. Requires a map of entity_name -> entity_id.
  """
  def persist_relations(relations, entity_map, opts) do
    owner_id = Keyword.fetch!(opts, :owner_id)
    scope_id = Keyword.get(opts, :scope_id)
    source_chunk_id = Keyword.get(opts, :source_chunk_id)
    repo = Config.repo()

    Enum.reduce_while(relations, {:ok, []}, fn rel_data, {:ok, acc} ->
      from_key = normalize_name(rel_data["from"] || rel_data[:from])
      to_key = normalize_name(rel_data["to"] || rel_data[:to])
      from_id = Map.get(entity_map, from_key)
      to_id = Map.get(entity_map, to_key)

      if from_id && to_id && from_id != to_id do
        case upsert_relation(from_id, to_id, rel_data, owner_id, scope_id, source_chunk_id, repo) do
          {:ok, relation} -> {:cont, {:ok, acc ++ [relation]}}
          {:error, _reason} -> {:cont, {:ok, acc}}
        end
      else
        {:cont, {:ok, acc}}
      end
    end)
  end

  defp upsert_entity(entity_data, collection_id, owner_id, scope_id, repo) do
    name = normalize_name(entity_data["name"] || entity_data[:name])
    entity_type = to_string(entity_data["type"] || entity_data[:entity_type])

    unless entity_type in @entity_types do
      {:error, "Invalid entity type: #{entity_type}"}
    else
      existing =
        from(e in Entity,
          where:
            e.collection_id == ^collection_id and
              e.name == ^name and
              e.entity_type == ^entity_type
        )
        |> repo.one()

      case existing do
        nil ->
          %Entity{}
          |> Entity.changeset(%{
            collection_id: collection_id,
            name: name,
            entity_type: entity_type,
            description: entity_data["description"] || entity_data[:description],
            mention_count: 1,
            first_seen_at: DateTime.utc_now(),
            last_seen_at: DateTime.utc_now(),
            owner_id: owner_id,
            scope_id: scope_id
          })
          |> repo.insert()

        entity ->
          entity
          |> Entity.increment_mentions_changeset()
          |> repo.update()
      end
    end
  end

  defp upsert_relation(from_id, to_id, rel_data, owner_id, scope_id, source_chunk_id, repo) do
    relation_type = to_string(rel_data["type"] || rel_data[:relation_type])
    weight = parse_weight(rel_data["weight"] || rel_data[:weight])

    unless relation_type in @relation_types do
      {:error, "Invalid relation type: #{relation_type}"}
    else
      existing =
        from(r in Relation,
          where:
            r.from_entity_id == ^from_id and
              r.to_entity_id == ^to_id and
              r.relation_type == ^relation_type
        )
        |> repo.one()

      case existing do
        nil ->
          %Relation{}
          |> Relation.changeset(%{
            from_entity_id: from_id,
            to_entity_id: to_id,
            relation_type: relation_type,
            weight: weight,
            source_chunk_id: source_chunk_id,
            owner_id: owner_id,
            scope_id: scope_id
          })
          |> repo.insert()

        relation ->
          new_weight = (relation.weight + weight) / 2.0

          relation
          |> Relation.changeset(%{weight: new_weight})
          |> repo.update()
      end
    end
  end

  defp normalize_name(name) when is_binary(name), do: name |> String.downcase() |> String.trim()
  defp normalize_name(_), do: ""

  defp parse_weight(w) when is_float(w), do: min(max(w, 0.0), 1.0)
  defp parse_weight(w) when is_integer(w), do: min(max(w / 1.0, 0.0), 1.0)
  defp parse_weight(_), do: 0.5
end
