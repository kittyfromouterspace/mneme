defmodule Mneme.Search.Vector do
  @moduledoc """
  Semantic similarity search over chunks and entries using pgvector.
  """

  alias Mneme.{Config, Pipeline.Embedder, RetrievalCounter, OutcomeTracker, Confidence}

  require Logger

  @doc """
  Search for similar chunks and/or entries.

  ## Options
  - `:owner_id` — UUID to scope chunk search
  - `:scope_id` — UUID to scope entry search
  - `:limit` — Max results (default: 10)
  - `:min_score` — Minimum similarity 0.0-1.0 (default: 0.0)
  - `:tier` — `:full`, `:lightweight`, or `:both` (default: `:both`)
  """
  def search(query_text, opts \\ []) do
    start_time = System.monotonic_time()
    limit = Keyword.get(opts, :limit, 10)
    min_score = Keyword.get(opts, :min_score, 0.0)
    tier = Keyword.get(opts, :tier, :both)

    result =
      case Embedder.embed_query(query_text) do
        {:ok, query_embedding} ->
          embedding_str = "[#{Enum.map_join(query_embedding, ",", &Float.to_string/1)}]"

          results =
            []
            |> maybe_search_chunks(embedding_str, opts, limit, min_score, tier)
            |> maybe_search_entries(embedding_str, opts, limit, min_score, tier)

          {:ok, results}

        {:error, reason} ->
          {:error, reason}
      end

    duration = System.monotonic_time() - start_time

    case result do
      {:ok, results} ->
        Mneme.Telemetry.event([:mneme, :search, :vector, :stop], %{
          duration: duration,
          result_count: length(results),
          tier: tier
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

    case Embedder.embed_query(query_text) do
      {:ok, embedding} ->
        embedding_str = "[#{Enum.map_join(embedding, ",", &Float.to_string/1)}]"
        do_search_entries(embedding_str, scope_id, limit, min_score)

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

  defp maybe_search_chunks(acc, embedding_str, opts, limit, min_score, tier)
       when tier in [:full, :both] do
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

  defp maybe_search_entries(acc, embedding_str, opts, limit, min_score, tier)
       when tier in [:lightweight, :both] do
    case Keyword.get(opts, :scope_id) do
      nil ->
        acc

      scope_id ->
        case do_search_entries(embedding_str, scope_id, limit, min_score) do
          {:ok, results} -> acc ++ Enum.map(results, &Map.put(&1, :result_type, :entry))
          _ -> acc
        end
    end
  end

  defp maybe_search_entries(acc, _, _, _, _, _), do: acc

  defp do_search_chunks(embedding_str, owner_id, limit, min_score) do
    repo = Config.repo()

    sql = """
    SELECT
      mc.id, mc.content, mc.document_id, mc.sequence,
      mc.token_count, mc.metadata,
      (1 - (mc.embedding <=> $1::text::vector)) AS score
    FROM mneme_chunks mc
    WHERE mc.owner_id = $2
      AND mc.embedding IS NOT NULL
      AND (1 - (mc.embedding <=> $1::text::vector)) >= $3
    ORDER BY mc.embedding <=> $1::text::vector
    LIMIT $4
    """

    case repo.query(sql, [embedding_str, uuid_to_bin(owner_id), min_score, limit]) do
      {:ok, %{rows: rows, columns: columns}} ->
        {:ok, Enum.map(rows, fn row -> row_to_map(columns, row) end)}

      {:error, reason} ->
        Logger.error("Mneme vector search (chunks) failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_search_entries(embedding_str, scope_id, limit, min_score) do
    repo = Config.repo()

    sql = """
    SELECT
      me.id, me.content, me.summary, me.entry_type, me.source,
      me.metadata, me.confidence, me.inserted_at,
      me.half_life_days, me.pinned, me.emotional_valence, me.access_count,
      me.last_accessed_at,
      (1 - (me.embedding <=> $1::text::vector)) AS score
    FROM mneme_entries me
    WHERE me.scope_id = $2
      AND me.embedding IS NOT NULL
      AND me.entry_type != 'archived'
      AND (1 - (me.embedding <=> $1::text::vector)) >= $3
    ORDER BY me.embedding <=> $1::text::vector
    LIMIT $4
    """

    case repo.query(sql, [embedding_str, uuid_to_bin(scope_id), min_score, limit]) do
      {:ok, %{rows: rows, columns: columns}} ->
        results = Enum.map(rows, fn row -> row_to_map(columns, row) end)
        bump_retrieval(results)
        track_for_outcome(scope_id, results)
        {:ok, results}

      {:error, reason} ->
        Logger.error("Mneme vector search (entries) failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_search_entities(embedding_str, owner_id, limit) do
    repo = Config.repo()

    sql = """
    SELECT
      me.id, me.name, me.entity_type, me.description,
      me.mention_count,
      (1 - (me.embedding <=> $1::text::vector)) AS score
    FROM mneme_entities me
    WHERE me.owner_id = $2
      AND me.embedding IS NOT NULL
    ORDER BY me.embedding <=> $1::text::vector
    LIMIT $3
    """

    case repo.query(sql, [embedding_str, uuid_to_bin(owner_id), limit]) do
      {:ok, %{rows: rows, columns: columns}} ->
        {:ok, Enum.map(rows, fn row -> row_to_map(columns, row) end)}

      {:error, reason} ->
        Logger.error("Mneme vector search (entities) failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp bump_retrieval(results) do
    ids = results |> Enum.map(& &1["id"]) |> Enum.reject(&is_nil/1)
    RetrievalCounter.bump_many(ids)
    Confidence.wake_up_stale_entries(ids)
  end

  defp track_for_outcome(scope_id, results) do
    ids = results |> Enum.map(& &1["id"]) |> Enum.reject(&is_nil/1)
    if ids != [], do: OutcomeTracker.set(scope_id, ids)
  end

  defp uuid_to_bin(id) when is_binary(id) do
    case Ecto.UUID.dump(id) do
      {:ok, bin} -> bin
      :error -> id
    end
  end

  defp row_to_map(columns, row) do
    Enum.zip(columns, row) |> Map.new()
  end
end
