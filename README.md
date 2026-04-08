# Mneme

Pluggable memory engine for Elixir applications. Provides document ingestion with markdown-aware chunking, configurable vector embeddings (pgvector), LLM-powered entity/relation extraction, knowledge graph storage, hybrid search, and memory decay.

## Inspiration

Mneme builds on research from [MemPalace](https://github.com/milla-jovovich/mempalace), [HIPPO Memory](https://github.com/kitfunso/hippo-memory) and [Cognee](https://docs.cognee.ai) among others.

## Architecture

Mneme provides two independent tiers that can be used separately or together:

```
┌─────────────────────────────────────────────────────────────────┐
│ Tier 1: Full Pipeline                                           │
│                                                                 │
│ Collection → Document → Chunk → Entity → Relation               │
│                                                                 │
│ Markdown-aware chunking, content-hash dedup, LLM entity         │
│ extraction, pipeline tracking, PostgreSQL graph traversal       │
├─────────────────────────────────────────────────────────────────┤
│ Tier 2: Lightweight Knowledge                                   │
│                                                                 │
│ Entry + Edge                                                    │
│                                                                 │
│ Simple store-embed-search with access tracking, confidence      │
│ scoring, supersession, and decay                                │
├─────────────────────────────────────────────────────────────────┤
│ Shared: Search (Vector + Graph + Hybrid), Context Formatting    │
│ Shared: Configurable Embedding (OpenRouter, OpenAI, Ollama)     │
│ Shared: Maintenance (Decay, Reembed)                            │
└─────────────────────────────────────────────────────────────────┘
```

## Integration Guide

### Step 1: Add Dependency

```elixir
# mix.exs
defp deps do
  [
    {:mneme, github: "kittyfromouterspace/mneme"}
    # or for local development:
    # {:mneme, path: "../mneme"}
  ]
end
```

Run `mix deps.get`.

### Step 2: Generate Migration

```bash
mix mneme.gen.migration --dimensions 768
```

Options:

- `--dimensions` — Embedding vector dimensions (default: 768). Must match your embedding model:
  - `768` for Google text-embedding-004, Ollama nomic-embed-text
  - `1536` for OpenAI text-embedding-3-small
  - `3072` for OpenAI text-embedding-3-large

This creates a migration in `priv/repo/migrations/` with all Mneme tables. Then:

```bash
mix ecto.migrate
```

### Step 3: Configure

Add to your `config/config.exs` (or `runtime.exs` for production):

```elixir
config :mneme,
  repo: MyApp.Repo,
  embedding: [
    provider: Mneme.Embedding.OpenRouter,
    credentials_fn: fn ->
      # Fetch API key from YOUR secret system at runtime
      # Return a map with :api_key + optional :model, :dimensions, :base_url
      # Return :disabled if no credentials available
      %{
        api_key: System.get_env("OPENROUTER_API_KEY"),
        model: "google/text-embedding-004",
        dimensions: 768
      }
    end
  ],
  extraction: [
    provider: Mneme.Extraction.LlmJson,
    llm_fn: fn messages, _opts ->
      # YOUR LLM call function — takes messages list, returns {:ok, text}
      # This is how Mneme calls your LLM for entity extraction
      MyApp.LLM.chat(messages)
    end
  ]
```

#### Credential Resolution

Mneme never stores API keys. Instead, you provide a `:credentials_fn` that fetches
credentials from your app's secret system at runtime. Examples:

```elixir
# Simple: environment variable
credentials_fn: fn ->
  case System.get_env("OPENROUTER_API_KEY") do
    nil -> :disabled
    key -> %{api_key: key, model: "google/text-embedding-004", dimensions: 768}
  end
end

# Phoenix app with encrypted DB secrets
credentials_fn: fn ->
  case MyApp.Secrets.get_api_key("openrouter") do
    {:ok, key} -> %{api_key: key, model: "google/text-embedding-004", dimensions: 768}
    _ -> :disabled
  end
end

# Ash-based credential store
credentials_fn: fn ->
  case MyApp.Admin.LlmCredential.active_for_provider(:openrouter, authorize?: false) do
    {:ok, cred} -> %{api_key: cred.api_key, model: "google/text-embedding-004", dimensions: 768}
    _ -> :disabled
  end
end
```

### Step 4: Use

#### Tier 2 — Lightweight Knowledge (simplest)

Store and search knowledge entries:

```elixir
# Store a fact (auto-embeds in background)
{:ok, entry} = Mneme.remember("Deploy script is at scripts/deploy.sh",
  scope_id: workspace_id,
  owner_id: user_id,
  entry_type: "note"
)

# Search by semantic similarity
{:ok, results} = Mneme.search("how to deploy",
  scope_id: workspace_id,
  tier: :lightweight
)

# Format results for LLM system prompt
context_text = Mneme.build_context(results)

# Connect related entries
Mneme.connect(entry1.id, entry2.id, "supports", weight: 0.8)

# Delete
Mneme.forget(entry.id)
```

Entry types: `outcome`, `event`, `decision`, `observation`, `hypothesis`, `note`, `session_summary`, `conversation_turn`, `preference`, `milestone`, `problem`, `emotional`, `archived`.

```elixir
# Auto-classify content using LLM-free pattern matching (inspired by MemPalace)
{:ok, entry} = Mneme.remember("We decided to use PostgreSQL for its JSON support",
  scope_id: workspace_id,
  owner_id: user_id,
  auto_classify: true  # Detects :decision type automatically
)

# Check for contradictions against existing knowledge
case Mneme.Knowledge.check_contradiction(content, scope_id, owner_id) do
  :ok -> IO.puts("No conflicts")
  {:conflict, conflicts} -> IO.puts("Conflicts detected!")
end
```

#### Tier 1 — Full Pipeline (for documents)

Ingest documents with chunking, embedding, and entity extraction:

```elixir
# Ingest a document (deduplicates by content hash)
{:ok, doc} = Mneme.ingest("Meeting Notes", markdown_content,
  owner_id: user_id,
  scope_id: workspace_id,
  source_type: "artifact",
  source_id: "meeting-2024-01-15"
)

# Run the full pipeline: chunk → embed → extract entities → embed entities
{:ok, run} = Mneme.process(doc)
# run.status => "complete"
# run.step_details => %{chunks_created: 12, entities_extracted: 8, ...}

# Or run async (fire and forget)
Mneme.process_async(doc)

# Re-ingesting unchanged content returns :unchanged (no wasted API calls)
{:ok, :unchanged} = Mneme.ingest("Meeting Notes", markdown_content,
  owner_id: user_id, scope_id: workspace_id,
  source_type: "artifact", source_id: "meeting-2024-01-15"
)
```

#### Hybrid Search (both tiers)

```elixir
# Search across chunks AND entries
{:ok, context_pack} = Mneme.search("project timeline",
  owner_id: user_id,
  scope_id: workspace_id,
  limit: 10,
  hops: 2  # graph expansion depth
)

# context_pack contains:
# %{
#   chunks: [...],         # Tier 1 chunk results with similarity scores
#   entries: [...],        # Tier 2 entry results with similarity scores
#   related_entries: [...], # Entries found via edge traversal
#   entities: [...],       # Extracted entities from knowledge graph
#   relations: [...],      # Graph relations between entities
#   query: "project timeline"
# }

# Format for LLM consumption
context_text = Mneme.build_context(context_pack)

# Search with filters (inspired by MemPalace's wing/room filtering)
{:ok, results} = Mneme.search("deployment",
  scope_id: workspace_id,
  tier: :lightweight,
  filters: %{
    entry_type: :decision,      # Only decision-type entries
    temporal: :recent,          # Last 30 days only
    confidence_min: 0.5         # Minimum confidence
  }
)
# =>
# ## Relevant Memory Chunks
# [Chunk 1 (score: 0.892)] The project timeline was revised...
#
# ## Relevant Knowledge
# [1] [decision] (score: 0.845) Moved deadline to March
#
# ## Known Entities
# - project timeline (concept): Schedule for deliverables
# - march deadline (event): Revised target date
#
# ## Known Relationships
# - project timeline --[depends_on]--> march deadline
```

#### Maintenance

```elixir
# Archive stale entries (entries not accessed in 90 days with < 3 accesses)
{:ok, archived_count} = Mneme.decay()
{:ok, archived_count} = Mneme.decay(max_age_days: 60, min_access_count: 5)

# Re-embed entries/chunks with nil embeddings (after model change)
{:ok, count} = Mneme.reembed()
{:ok, count} = Mneme.reembed(batch_size: 50, concurrency: 4)
```

#### Learning

Mneme can automatically learn from external sources like git history, Claude Code, and OpenCode conversations:

```elixir
# Run all learning sources (git, claude_code, opencode)
{:ok, result} = Mneme.Learning.Pipeline.run(scope_id: workspace_id)
# => %{git: %{fetched: 12, learned: 8, skipped: 4}, claude_code: %{...}, opencode: %{...}}

# Run specific sources only
{:ok, result} = Mneme.Learning.Pipeline.run(scope_id: workspace_id, sources: [:git])

# Dry run - preview what would be learned
{:ok, preview} = Mneme.Learning.Pipeline.run(scope_id: workspace_id, dry_run: true)

# Run individual learners
{:ok, git_result} = Mneme.Learner.Git.run(scope_id: workspace_id)
{:ok, claude_result} = Mneme.Learner.ClaudeCode.run(scope_id: workspace_id)
{:ok, opencode_result} = Mneme.Learner.OpenCode.run(scope_id: workspace_id)
```

##### Available Learners

| Learner | Source | Detects |
|---------|--------|---------|
| `Mneme.Learner.Git` | Git history | Bug fixes, features, migrations, breaking changes |
| `Mneme.Learner.ClaudeCode` | Claude Code projects | Decisions, code implementations, errors |
| `Mneme.Learner.OpenCode` | OpenCode sessions | Decisions, implementations, project context |

##### Custom Learners

Implement the `Mneme.Learner` behaviour to add your own sources:

```elixir
defmodule MyApp.Learner.CI do
  @behaviour Mneme.Learner

  @impl true
  def source, do: :ci

  @impl true
  def fetch_since(since, scope_id) do
    # Fetch CI failures since the given date
  end

  @impl true
  def extract(event) do
    {:ok, %{
      content: "CI Failure: #{event.failure_message}",
      entry_type: :observation,
      emotional_valence: :negative,
      tags: ["ci", "failure"],
      metadata: %{source: :ci, job_id: event.id}
    }}
  end

  @impl true
  def detect_patterns(events), do: []
end
```

Then add to your config:

```elixir
config :mneme,
  learning: [
    sources: [Mneme.Learner.Git, Mneme.Learner.ClaudeCode, MyApp.Learner.CI]
  ]
```

## Configuration Reference

```elixir
config :mneme,
  # Required: your Ecto repo
  repo: MyApp.Repo,

  # Embedding configuration
  embedding: [
    # Provider module (required for embedding to work)
    provider: Mneme.Embedding.OpenRouter,  # or OpenAI, or Ollama

    # Runtime credential resolver (recommended)
    credentials_fn: fn -> %{api_key: "...", model: "...", dimensions: 768} end,

    # OR static config (simpler but less secure)
    api_key: "sk-...",
    model: "google/text-embedding-004",
    dimensions: 768
  ],

  # LLM extraction configuration (required for Tier 1 pipeline)
  extraction: [
    provider: Mneme.Extraction.LlmJson,  # default
    llm_fn: fn messages, opts -> {:ok, "response text"} end
  ],

  # Optional
  task_supervisor: MyApp.TaskSupervisor,  # default: Mneme.TaskSupervisor
  graph_store: Mneme.Graph.PostgresGraph,  # default, swap for custom impl
  table_prefix: "mneme_"                   # default

  # Learning configuration (optional)
  learning: [
    enabled: true,
    sources: [Mneme.Learner.Git, Mneme.Learner.ClaudeCode, Mneme.Learner.OpenCode]
  ]
```

## Embedding Providers

| Provider | Module | Default Model | Dimensions | Notes |
|----------|--------|---------------|------------|-------|
| OpenRouter | `Mneme.Embedding.OpenRouter` | `google/text-embedding-004` | 768 | Best overall, supports Google/OpenAI models |
| OpenAI | `Mneme.Embedding.OpenAI` | `text-embedding-3-large` | 3072 | Direct OpenAI API |
| Ollama | `Mneme.Embedding.Ollama` | `nomic-embed-text` | 768 | Local, no API key needed |

## Schema Overview

### Tier 1: Full Pipeline

| Table | Purpose | Key Fields |
|-------|---------|------------|
| `mneme_collections` | Groups documents | name, collection_type, owner_id, scope_id |
| `mneme_documents` | Source content + dedup hash | title, content, content_hash, status, source_type |
| `mneme_chunks` | Embedded text fragments | content, embedding, sequence, heading context |
| `mneme_entities` | Extracted knowledge nodes | name, entity_type (10 types), mention_count, embedding |
| `mneme_relations` | Graph edges between entities | relation_type (8 types), weight, from/to entity |
| `mneme_pipeline_runs` | Pipeline execution tracking | status lifecycle, step_details, cost, timing |

Entity types: `concept`, `person`, `goal`, `obstacle`, `domain`, `strategy`, `emotion`, `place`, `event`, `tool`.

Relation types: `supports`, `blocks`, `causes`, `relates_to`, `part_of`, `depends_on`, `precedes`, `contradicts`.

### Tier 2: Lightweight Knowledge

| Table | Purpose | Key Fields |
|-------|---------|------------|
| `mneme_entries` | Knowledge entries | content, entry_type, embedding, confidence, access_count |
| `mneme_edges` | Lightweight edges | relation (6 types), weight, source/target entry |

Edge relation types: `leads_to`, `supports`, `contradicts`, `derived_from`, `supersedes`, `related_to`.

### Dual Identifiers

All schemas carry both `owner_id` and `scope_id`:

- **`owner_id`** — The user who owns the data. Used for cross-scope queries ("everything this user knows").
- **`scope_id`** — The workspace/project/collection scope. Used for scoped queries ("everything in this workspace").

Both are UUID columns. Your app decides what they map to.

## Behaviours (Extension Points)

### `Mneme.EmbeddingProvider`

Implement to add a new embedding backend:

```elixir
defmodule MyApp.CustomEmbedding do
  @behaviour Mneme.EmbeddingProvider

  @impl true
  def dimensions(_opts), do: 768

  @impl true
  def generate(texts, opts) do
    # Return {:ok, [[float()]]} or {:error, reason}
  end

  @impl true
  def embed(text, opts) do
    # Optional — defaults to calling generate/2 with a single text
  end
end
```

### `Mneme.ExtractionProvider`

Implement to customize entity/relation extraction:

```elixir
defmodule MyApp.CustomExtraction do
  @behaviour Mneme.ExtractionProvider

  @impl true
  def extract(text, opts) do
    # Return {:ok, %{entities: [...], relations: [...]}} or {:error, reason}
  end
end
```

### `Mneme.GraphStore`

Implement to swap the graph backend (default: PostgreSQL recursive CTEs):

```elixir
defmodule MyApp.Neo4jGraph do
  @behaviour Mneme.GraphStore

  @impl true
  def get_neighbors(owner_id, entity_id, hops) do
    # Return {:ok, [entity]} or {:error, reason}
  end

  @impl true
  def get_relations(owner_id, entity_id) do
    # Return {:ok, [relation]} or {:error, reason}
  end
end
```

## Requirements

- Elixir >= 1.17
- PostgreSQL with pgvector extension
- An embedding API (OpenRouter, OpenAI, or local Ollama)
- An LLM API for entity extraction (only needed for Tier 1)
