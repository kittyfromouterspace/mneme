defmodule Mneme.Extraction.LlmJson do
  @moduledoc """
  Default extraction provider using LLM with JSON structured output.

  Requires an `:llm_fn` option — a function `(messages, opts) -> {:ok, text} | {:error, reason}`.
  The host app provides this function to route through their LLM service.
  """
  @behaviour Mneme.ExtractionProvider

  alias Mneme.Schema.Entity
  alias Mneme.Schema.Relation

  require Logger

  @entity_types Enum.join(Entity.entity_types(), ", ")
  @relation_types Enum.join(Relation.relation_types(), ", ")

  @extraction_prompt """
  You are an expert knowledge graph builder.

  Given the following text, extract:
  1. **Entities**: Important concepts, people, goals, obstacles, strategies, emotions, domains, places, events, or tools mentioned.
  2. **Relations**: How the entities relate to each other.

  Rules:
  - Entity names should be concise (1-4 words), normalized to lowercase
  - Each entity needs a type from: #{@entity_types}
  - Each entity needs a brief description (1 sentence)
  - Relations need a type from: #{@relation_types}
  - Relations have a weight from 0.0 to 1.0 indicating confidence/strength
  - Extract at most 10 entities and 15 relations per chunk
  - Focus on the most meaningful and actionable entities

  Respond with valid JSON only, no other text:
  {
    "entities": [
      {"name": "string", "type": "string", "description": "string"}
    ],
    "relations": [
      {"from": "entity_name", "to": "entity_name", "type": "string", "weight": 0.8}
    ]
  }

  Text to analyze:
  """

  @impl true
  def extract(text, opts) do
    llm_fn = Keyword.fetch!(opts, :llm_fn)

    messages = [
      %{role: "system", content: @extraction_prompt},
      %{role: "user", content: text}
    ]

    case llm_fn.(messages, opts) do
      {:ok, content} when is_binary(content) ->
        parse_result(content)

      {:error, reason} ->
        Logger.error("Mneme.Extraction.LlmJson: LLM call failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp parse_result(content) do
    json_content =
      content
      |> String.replace(~r/```json\n?/, "")
      |> String.replace(~r/```\n?/, "")
      |> String.trim()

    case Jason.decode(json_content) do
      {:ok, %{"entities" => entities, "relations" => relations}} ->
        validated_entities = validate_entities(entities)
        validated_relations = validate_relations(relations)
        {:ok, %{entities: validated_entities, relations: validated_relations}}

      {:ok, _} ->
        {:error, "Invalid extraction format: missing entities or relations key"}

      {:error, reason} ->
        Logger.warning("Mneme.Extraction.LlmJson: JSON parse failed: #{inspect(reason)}")
        {:ok, %{entities: [], relations: []}}
    end
  end

  defp validate_entities(entities) when is_list(entities) do
    valid_types = Entity.entity_types()

    Enum.filter(entities, fn entity ->
      is_map(entity) &&
        is_binary(entity["name"]) &&
        String.length(entity["name"]) > 0 &&
        entity["type"] in valid_types
    end)
  end

  defp validate_entities(_), do: []

  defp validate_relations(relations) when is_list(relations) do
    valid_types = Relation.relation_types()

    Enum.filter(relations, fn rel ->
      is_map(rel) &&
        is_binary(rel["from"]) &&
        is_binary(rel["to"]) &&
        rel["type"] in valid_types
    end)
  end

  defp validate_relations(_), do: []
end
