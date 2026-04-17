defmodule Recollect.Search.Vector do
  @moduledoc """
  Semantic similarity search over chunks and entries.

  Supports multiple database backends via the `Recollect.DatabaseAdapter` behaviour:
  - PostgreSQL with pgvector
  - SQLite with sqlite-vec
  - libSQL with native vector support
  """

  alias Recollect.Confidence
  alias Recollect.Config
  alias Recollect.Context.Detector
  alias Recollect.OutcomeTracker
  alias Recollect.Pipeline.Embedder
  alias Recollect.RetrievalCounter
  alias Recollect.Search.ContextBooster

  require Logger

  @doc """
  Search for similar chunks and/or entries.

  ## Options
  - `:owner_id` — UUID to scope chunk search
  - `:scope_id` — UUID to scope entry search
  - `:limit` — Max results (default: 10)
  - `:min_score` — Minimum similarity 0.0-1.0 (default: 0.0)
  - `:tier` — `:full`, `:lightweight`, or `:both` (default: `:both`)
  - `:filters` — Map of additional filters:
      - `:entry_type` — Filter by entry type (e.g., :decision, :preference)
      - `:tags` — Filter by tags (list)
      - `:temporal` — `:recent` (last 30 days), `:archived`, or DateTime range
      - `:confidence_min` — Minimum confidence threshold
  """
  def search(query_text, opts \\ []) do
    start_time = System.monotonic_time()
    limit = Keyword.get(opts, :limit, 10)
    min_score = Keyword.get(opts, :min_score, 0.0)
    tier = Keyword.get(opts, :tier, :both)
    filters = Keyword.get(opts, :filters, %{})

    result =
      case Embedder.embed_query(query_text) do
        {:ok, query_embedding} ->
          embedding_str = "[#{Enum.map_join(query_embedding, ",", &Float.to_string/1)}]"

          results =
            []
            |> maybe_search_chunks(embedding_str, opts, limit, min_score, tier)
            |> maybe_search_entries(embedding_str, opts, limit, min_score, tier, filters)

          {:ok, results}

        {:error, reason} ->
          {:error, reason}
      end

    duration = System.monotonic_time() - start_time

    case result do
      {:ok, results} ->
        Recollect.Telemetry.event([:recollect, :search, :vector, :stop], %{
          duration: duration,
          result_count: length(results),
          tier: tier,
          filters_applied: map_size(filters) > 0,
          has_entry_type_filter: filters[:entry_type] != nil,
          has_temporal_filter: filters[:temporal] != nil,
          has_confidence_filter: filters[:confidence_min] != nil
        })

      _ ->
        :ok
    end

    result
  end

  @doc "Search chunks only."
  def search_chunks(query_text, owner_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    min_score = Keyword.get(opts, :min_score, 0.0)

    case Embedder.embed_query(query_text) do
      {:ok, embedding} ->
        embedding_str = "[#{Enum.map_join(embedding, ",", &Float.to_string/1)}]"
        do_search_chunks(embedding_str, owner_id, limit, min_score)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Search entries only."
  def search_entries(query_text, scope_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    min_score = Keyword.get(opts, :min_score, 0.0)
    filters = Keyword.get(opts, :filters, %{})

    case Embedder.embed_query(query_text) do
      {:ok, embedding} ->
        embedding_str = "[#{Enum.map_join(embedding, ",", &Float.to_string/1)}]"
        do_search_entries(embedding_str, scope_id, limit, min_score, filters)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Search entities by vector similarity."
  def search_entities_vec(query_text, owner_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)

    case Embedder.embed_query(query_text) do
      {:ok, embedding} ->
        embedding_str = "[#{Enum.map_join(embedding, ",", &Float.to_string/1)}]"
        do_search_entities(embedding_str, owner_id, limit)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp maybe_search_chunks(acc, embedding_str, opts, limit, min_score, tier) when tier in [:full, :both] do
    case Keyword.get(opts, :owner_id) do
      nil ->
        acc

      owner_id ->
        case do_search_chunks(embedding_str, owner_id, limit, min_score) do
          {:ok, results} -> acc ++ Enum.map(results, &Map.put(&1, :result_type, :chunk))
          _ -> acc
        end
    end
  end

  defp maybe_search_chunks(acc, _, _, _, _, _), do: acc

  defp maybe_search_entries(acc, embedding_str, opts, limit, min_score, tier, filters)
       when tier in [:lightweight, :both] do
    case Keyword.get(opts, :scope_id) do
      nil ->
        acc

      scope_id ->
        case do_search_entries(embedding_str, scope_id, limit, min_score, filters) do
          {:ok, results} -> acc ++ Enum.map(results, &Map.put(&1, :result_type, :entry))
          _ -> acc
        end
    end
  end

  defp do_search_chunks(embedding_str, owner_id, limit, min_score) do
    adapter = Config.adapter()
    repo = Config.repo()

    {sql, params} = chunks_query(adapter.dialect(), adapter, embedding_str, owner_id, limit, min_score)

    case repo.query(sql, params) do
      {:ok, %{rows: rows, columns: columns}} ->
        {:ok, Enum.map(rows, fn row -> row_to_map(columns, row) end)}

      {:error, reason} ->
        Logger.error("Recollect vector search (chunks) failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_search_entries(embedding_str, scope_id, limit, min_score, filters) do
    adapter = Config.adapter()
    repo = Config.repo()

    {sql, params} = entries_query(adapter.dialect(), adapter, embedding_str, scope_id, limit, min_score, filters)

    case repo.query(sql, params) do
      {:ok, %{rows: rows, columns: columns}} ->
        results = Enum.map(rows, fn row -> row_to_map(columns, row) end)
        results = add_context_boost(results)
        bump_retrieval(results)
        track_for_outcome(scope_id, results)
        {:ok, results}

      {:error, reason} ->
        Logger.error("Recollect vector search (entries) failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_search_entities(embedding_str, owner_id, limit) do
    adapter = Config.adapter()
    repo = Config.repo()

    {sql, params} = entities_query(adapter.dialect(), adapter, embedding_str, owner_id, limit)

    case repo.query(sql, params) do
      {:ok, %{rows: rows, columns: columns}} ->
        {:ok, Enum.map(rows, fn row -> row_to_map(columns, row) end)}

      {:error, reason} ->
        Logger.error("Recollect vector search (entities) failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ── Query Builders (PostgreSQL) ─────────────────────────────────────

  defp chunks_query(:postgres, _adapter, embedding_str, owner_id, limit, min_score) do
    sql = """
    SELECT
      mc.id, mc.content, mc.document_id, mc.sequence,
      mc.token_count, mc.metadata,
      (1 - (mc.embedding <=> $1::text::vector)) AS score
    FROM recollect_chunks mc
    WHERE mc.owner_id = $2
      AND mc.embedding IS NOT NULL
      AND (1 - (mc.embedding <=> $1::text::vector)) >= $3
    ORDER BY mc.embedding <=> $1::text::vector
    LIMIT $4
    """

    {sql, [embedding_str, uuid_to_bin(owner_id), min_score, limit]}
  end

  # ── Query Builders (SQLite / sqlite-vec) ────────────────────────────

  defp chunks_query(:sqlite, adapter, embedding_str, owner_id, limit, min_score) do
    similarity = adapter.vector_similarity_sql("mc.embedding", "?")
    distance = adapter.vector_distance_sql("mc.embedding", "?")

    sql = """
    SELECT
      mc.id, mc.content, mc.document_id, mc.sequence,
      mc.token_count, mc.metadata,
      #{similarity} AS score
    FROM recollect_chunks mc
    WHERE mc.owner_id = ?
      AND mc.embedding IS NOT NULL
      AND #{similarity} >= ?
    ORDER BY #{distance}
    LIMIT ?
    """

    # Each ? in the distance/similarity expressions consumes one embedding_str param
    {sql, [embedding_str, owner_id, embedding_str, min_score, embedding_str, limit]}
  end

  # ── Query Builders (libSQL) ─────────────────────────────────────────

  defp chunks_query(:libsql, adapter, embedding_str, owner_id, limit, min_score) do
    # libSQL uses same ? placeholder style as SQLite
    chunks_query(:sqlite, adapter, embedding_str, owner_id, limit, min_score)
  end

  defp entries_query(:postgres, _adapter, embedding_str, scope_id, limit, min_score, filters) do
    {filter_sql, filter_params} = build_entry_filters_pg(filters)

    sql = """
    SELECT
      me.id, me.content, me.summary, me.entry_type, me.source,
      me.metadata, me.confidence, me.inserted_at,
      me.half_life_days, me.pinned, me.emotional_valence, me.access_count,
      me.last_accessed_at, me.context_hints,
      (1 - (me.embedding <=> $1::text::vector)) AS score
    FROM recollect_entries me
    WHERE me.scope_id = $2
      AND me.embedding IS NOT NULL
      AND me.entry_type != 'archived'
      AND (1 - (me.embedding <=> $1::text::vector)) >= $3
      #{filter_sql}
    ORDER BY me.embedding <=> $1::text::vector
    LIMIT $4
    """

    params = [embedding_str, uuid_to_bin(scope_id), min_score, limit | filter_params]
    {sql, params}
  end

  defp entries_query(dialect, adapter, embedding_str, scope_id, limit, min_score, filters)
       when dialect in [:sqlite, :libsql] do
    similarity = adapter.vector_similarity_sql("me.embedding", "?")
    distance = adapter.vector_distance_sql("me.embedding", "?")

    {filter_sql, filter_params} = build_entry_filters_sqlite(filters)

    sql = """
    SELECT
      me.id, me.content, me.summary, me.entry_type, me.source,
      me.metadata, me.confidence, me.inserted_at,
      me.half_life_days, me.pinned, me.emotional_valence, me.access_count,
      me.last_accessed_at, me.context_hints,
      #{similarity} AS score
    FROM recollect_entries me
    WHERE me.scope_id = ?
      AND me.embedding IS NOT NULL
      AND me.entry_type != 'archived'
      AND #{similarity} >= ?
      #{filter_sql}
    ORDER BY #{distance}
    LIMIT ?
    """

    # similarity (SELECT) + scope_id + similarity (WHERE) + min_score + filter_params + distance (ORDER BY) + limit
    params = [embedding_str, scope_id, embedding_str, min_score] ++ filter_params ++ [embedding_str, limit]
    {sql, params}
  end

  defp entities_query(:postgres, _adapter, embedding_str, owner_id, limit) do
    sql = """
    SELECT
      me.id, me.name, me.entity_type, me.description,
      me.mention_count,
      (1 - (me.embedding <=> $1::text::vector)) AS score
    FROM recollect_entities me
    WHERE me.owner_id = $2
      AND me.embedding IS NOT NULL
    ORDER BY me.embedding <=> $1::text::vector
    LIMIT $3
    """

    {sql, [embedding_str, uuid_to_bin(owner_id), limit]}
  end

  defp entities_query(dialect, adapter, embedding_str, owner_id, limit) when dialect in [:sqlite, :libsql] do
    similarity = adapter.vector_similarity_sql("me.embedding", "?")
    distance = adapter.vector_distance_sql("me.embedding", "?")

    sql = """
    SELECT
      me.id, me.name, me.entity_type, me.description,
      me.mention_count,
      #{similarity} AS score
    FROM recollect_entities me
    WHERE me.owner_id = ?
      AND me.embedding IS NOT NULL
    ORDER BY #{distance}
    LIMIT ?
    """

    {sql, [embedding_str, owner_id, embedding_str, limit]}
  end

  # ── Filter Builders ─────────────────────────────────────────────────

  defp build_entry_filters_pg(filters) when filters == %{} or filters == nil do
    {"", []}
  end

  defp build_entry_filters_pg(filters) do
    conditions_and_params =
      []
      |> add_entry_type_filter_pg(filters[:entry_type])
      |> add_confidence_filter_pg(filters[:confidence_min])
      |> add_temporal_filter_pg(filters[:temporal])

    {conditions, params} = Enum.unzip(conditions_and_params)

    filter_sql =
      if conditions == [] do
        ""
      else
        "AND " <> Enum.join(conditions, " AND ")
      end

    {filter_sql, params}
  end

  defp add_entry_type_filter_pg(acc, nil), do: acc

  defp add_entry_type_filter_pg(acc, entry_type) do
    acc ++ [{"me.entry_type = $#{5 + length(acc)}", to_string(entry_type)}]
  end

  defp add_confidence_filter_pg(acc, nil), do: acc

  defp add_confidence_filter_pg(acc, confidence_min) do
    acc ++ [{"me.confidence >= $#{5 + length(acc)}", confidence_min}]
  end

  defp add_temporal_filter_pg(acc, nil), do: acc

  defp add_temporal_filter_pg(acc, :recent) do
    thirty_days_ago = DateTime.add(DateTime.utc_now(), -30 * 24 * 3600, :second)
    acc ++ [{"me.inserted_at >= $#{5 + length(acc)}", thirty_days_ago}]
  end

  defp build_entry_filters_sqlite(filters) when filters == %{} or filters == nil do
    {"", []}
  end

  defp build_entry_filters_sqlite(filters) do
    conditions_and_params =
      []
      |> add_filter_sqlite(filters[:entry_type], "me.entry_type = ?", &to_string/1)
      |> add_filter_sqlite(filters[:confidence_min], "me.confidence >= ?", & &1)
      |> add_temporal_filter_sqlite(filters[:temporal])

    {conditions, params} = Enum.unzip(conditions_and_params)

    filter_sql =
      if conditions == [] do
        ""
      else
        "AND " <> Enum.join(conditions, " AND ")
      end

    {filter_sql, params}
  end

  defp add_filter_sqlite(acc, nil, _sql, _transform), do: acc

  defp add_filter_sqlite(acc, value, sql, transform) do
    acc ++ [{sql, transform.(value)}]
  end

  defp add_temporal_filter_sqlite(acc, nil), do: acc

  defp add_temporal_filter_sqlite(acc, :recent) do
    thirty_days_ago = DateTime.add(DateTime.utc_now(), -30 * 24 * 3600, :second)
    acc ++ [{"me.inserted_at >= ?", DateTime.to_iso8601(thirty_days_ago)}]
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp bump_retrieval(results) do
    ids = results |> Enum.map(& &1["id"]) |> Enum.reject(&is_nil/1)
    RetrievalCounter.bump_many(ids)
    Confidence.wake_up_stale_entries(ids)
  end

  defp track_for_outcome(scope_id, results) do
    ids = results |> Enum.map(& &1["id"]) |> Enum.reject(&is_nil/1)
    if ids != [], do: OutcomeTracker.set(scope_id, ids)
  end

  defp add_context_boost(results) do
    current = Detector.detect()

    if map_size(current) == 0 do
      results
    else
      Enum.map(results, fn entry ->
        [entry] |> ContextBooster.apply_boost(current) |> hd()
      end)
    end
  end

  defp uuid_to_bin(id) when is_binary(id) do
    case Ecto.UUID.dump(id) do
      {:ok, bin} -> bin
      :error -> id
    end
  end

  defp row_to_map(columns, row) do
    columns |> Enum.zip(row) |> Map.new()
  end
end
