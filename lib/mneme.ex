defmodule Mneme do
  @moduledoc """
  Pluggable memory engine for Elixir applications.

  Provides document ingestion with markdown-aware chunking, configurable vector
  embeddings (pgvector), LLM-powered entity/relation extraction, knowledge graph
  storage, hybrid search, pipeline tracking, and memory decay.

  ## Two Tiers

  **Tier 1 — Full Pipeline:** Collections → Documents → Chunks → Entities → Relations.
  For structured ingestion of documents with chunking, embedding, entity extraction,
  and graph queries.

  **Tier 2 — Lightweight Knowledge:** Entries + Edges.
  For simple knowledge storage with embeddings, access tracking, and edge traversal.

  ## Quick Start

      # Configure in your app
      config :mneme,
        repo: MyApp.Repo,
        embedding: [provider: Mneme.Embedding.OpenRouter, model: "google/text-embedding-004"],
        extraction: [llm_fn: &MyApp.LLM.chat/2]

      # Lightweight API (Tier 2)
      {:ok, entry} = Mneme.remember("The deploy script lives at scripts/deploy.sh",
        scope_id: workspace_id, owner_id: user_id, entry_type: "note")

      {:ok, results} = Mneme.search("deploy script", scope_id: workspace_id)

      # Full Pipeline API (Tier 1)
      {:ok, doc} = Mneme.ingest("Meeting Notes", long_markdown, owner_id: user_id)
      {:ok, _run} = Mneme.process(doc)
      {:ok, context} = Mneme.search("project timeline", owner_id: user_id)
  """

  alias Mneme.{Pipeline, Search}
  alias Mneme.Search.Completion

  # ── Full Pipeline API (Tier 1) ───────────────────────────────────────

  @doc """
  Ingest content as a document with deduplication.

  Returns `{:ok, document}` or `{:ok, :unchanged}` if content hash matches.

  ## Options
  - `:owner_id` (required) — UUID of the owning user/workspace
  - `:collection_name` — Collection name (default: "default")
  - `:source_type` — "artifact", "conversation", "manual" (default: "manual")
  - `:source_id` — External ID for dedup tracking
  """
  def ingest(title, content, opts \\ []) do
    Pipeline.Ingester.ingest(title, content, opts)
  end

  @doc """
  Run the full pipeline on a document: chunk → embed → extract → sync.

  Returns `{:ok, pipeline_run}` with tracking info.
  """
  def process(document, opts \\ []) do
    Pipeline.process(document, opts)
  end

  @doc "Same as `process/2` but runs asynchronously via TaskSupervisor."
  def process_async(document, opts \\ []) do
    Pipeline.process_async(document, opts)
  end

  # ── Lightweight API (Tier 2) ─────────────────────────────────────────

  @doc """
  Store a knowledge entry with auto-embedding.

  ## Options
  - `:scope_id` — UUID scope (workspace, user, etc.)
  - `:owner_id` — UUID of the owner
  - `:entry_type` — String type (default: "note")
  - `:summary` — Brief summary
  - `:source` — "agent", "system", "user" (default: "system")
  - `:metadata` — Map of extra data
  - `:confidence` — Float 0.0-1.0 (default: 1.0)
  """
  def remember(content, opts \\ []) do
    Mneme.Knowledge.remember(content, opts)
  end

  @doc "Delete a knowledge entry."
  def forget(entry_id) do
    Mneme.Knowledge.forget(entry_id)
  end

  @doc """
  Create an edge between two entries.

  ## Options
  - `:weight` — Float 0.0-1.0 (default: 1.0)
  - `:metadata` — Map of extra data
  """
  def connect(source_id, target_id, relation, opts \\ []) do
    Mneme.Knowledge.connect(source_id, target_id, relation, opts)
  end

  # ── Search ───────────────────────────────────────────────────────────

  @doc """
  Hybrid search combining vector similarity and graph traversal.

  Searches both chunks (Tier 1) and entries (Tier 2) if available.

  ## Options
  - `:scope_id` — Scope UUID (searches entries)
  - `:owner_id` — Owner UUID (searches chunks + entities)
  - `:limit` — Max results (default: 10)
  - `:min_score` — Minimum similarity score (default: 0.0)
  - `:hops` — Graph expansion depth (default: 1)
  - `:tier` — `:full`, `:lightweight`, or `:both` (default: `:both`)
  """
  def search(query, opts \\ []) do
    Search.search(query, opts)
  end

  @doc "Vector-only search across entries and/or chunks."
  def search_vectors(query, opts \\ []) do
    Search.Vector.search(query, opts)
  end

  @doc "Graph neighborhood expansion from an entity or entry."
  def search_graph(entity_id, opts \\ []) do
    Search.Graph.neighborhood(entity_id, opts)
  end

  # ── Completion ──────────────────────────────────────────────────────

  @doc """
  Answer a question using memory search as LLM context.

  Requires an `:llm_fn` callback that accepts a list of message maps
  and returns `{:ok, answer_string}` or `{:error, reason}`.

  ## Options
  - `:llm_fn` (required) — `fn messages -> {:ok, string} | {:error, reason} end`
  - `:system_prompt` — Override the default system prompt
  - `:owner_id`, `:scope_id` — Scope the search
  - `:limit` — Max chunks (default: 10)
  - `:hops` — Graph depth (default: 2)
  """
  def complete(question, opts \\ []) do
    Completion.complete(question, opts)
  end

  # ── Context Formatting ──────────────────────────────────────────────

  @doc "Format search results as text suitable for LLM system prompts."
  def build_context(search_results) do
    Search.ContextFormatter.format(search_results)
  end

  # ── Maintenance ─────────────────────────────────────────────────────

  @doc """
  Archive stale entries based on access patterns.

  Default: entries not accessed in 90 days with < 3 accesses.

  ## Options
  - `:max_age_days` — Days since last access (default: 90)
  - `:min_access_count` — Minimum accesses to survive (default: 3)
  """
  def decay(opts \\ []) do
    Mneme.Maintenance.Decay.run(opts)
  end

  @doc "Re-embed all entries/chunks with nil embeddings."
  def reembed(opts \\ []) do
    Mneme.Maintenance.Reembed.run(opts)
  end
end
