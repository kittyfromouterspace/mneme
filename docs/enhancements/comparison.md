# Mneme vs Hippo: Concept Comparison

## Architecture Comparison

| Aspect | Mneme | Hippo |
|--------|-------|-------|
| **Language** | Elixir (OTP) | TypeScript (Node.js) |
| **Storage** | PostgreSQL (pgvector) | SQLite + markdown mirrors |
| **Tiers** | 3 (Tier 0: GenServer WM, Tier 1: pipeline, Tier 2: lightweight) | 3 (Buffer, Episodic, Semantic) |
| **Embeddings** | pgvector, multiple providers | Optional transformers.js |
| **Search** | Vector + graph hybrid | BM25 + embedding hybrid |
| **Graph** | Recursive CTEs, Neo4j-swappable | None (flat entries) |
| **Multi-tenancy** | owner_id + scope_id on all schemas | Local (.hippo/) + global (~/.hippo/) |
| **Concurrency** | OTP processes, ETS, Task.async_stream | Single-threaded Node.js |

## Feature Matrix

| Feature | Mneme | Hippo | Enhancement |
|---------|-------|-------|-------------|
| **Decay** | Basic (archive after N days, low access) | Half-life formula with exponential decay | [01](01-retrieval-strengthening.md) |
| **Retrieval strengthening** | No | Half-life +2 days per retrieval | [01](01-retrieval-strengthening.md) |
| **Working memory** | No | SQLite table (max 20) | [02](02-working-memory.md) — GenServer + DynamicSupervisor |
| **Outcome feedback** | No | Good/bad adjusts half-life (+5/-3 days) | [03](03-outcome-feedback.md) |
| **Confidence lifecycle** | Static float (0.0-1.0) | verified/observed/inferred/stale with auto-transitions | [04](04-confidence-lifecycle.md) |
| **Emotional valence** | No | neutral/positive/negative/critical multipliers | [05](05-emotional-valence.md) |
| **Schema acceleration** | No | IDF-weighted tag overlap + content similarity | [06](06-schema-acceleration.md) — ETS-backed |
| **Conflict detection** | No (has `contradicts` edge type) | Pattern-based (enabled/disabled, always/never, etc.) | [07](07-conflict-detection.md) — Task.async_stream |
| **Sleep consolidation** | No | Episodic → Semantic merge with decay | [08](08-sleep-consolidation.md) — Task.async_stream |
| **Session handoffs** | `session_summary` entry type | Dedicated handoff + event trail system | Future |
| **Cross-scope sharing** | owner_id/scope_id dual identity | Local/global stores with transfer scoring | Future |
| **Content dedup** | Hash-based (Tier 1) | Content-based duplicate detection | Existing |
| **Hybrid search** | Vector + graph | BM25 + embeddings | Existing (different approaches) |
| **Explainable recall** | No | `--why` flag with match breakdown | Future |
| **Git auto-learn** | No | Scans commit history for lessons | Future |
| **Framework hooks** | No | Auto-installs into CLAUDE.md, AGENTS.md, etc. | Future |

## Elixir OTP Optimizations

Where Hippo uses database tables or sequential processing, Mneme leverages OTP primitives:

| Concept | Hippo Implementation | Mneme Implementation | Why |
|---------|---------------------|---------------------|-----|
| Working memory | SQLite table | **GenServer per scope** + DynamicSupervisor | Ephemeral, bounded, session-scoped — no persistence needed |
| Retrieval counters | In-memory variable | **ETS `:counter`** + GenServer periodic flush | Lock-free increments, batch DB writes |
| Schema index | Recomputed on demand | **ETS table**, rebuilt during consolidation | O(1) lookup vs O(n) DB query |
| Last-retrieved tracking | Module state | **Public ETS table** | Cross-process, no GenServer overhead |
| Conflict detection | Sequential O(n²) loop | **`Task.async_stream`** parallel comparison | CPU-bound, uses all cores |
| Consolidation merge | Sequential overlap computation | **`Task.async_stream`** parallel comparison | CPU-bound, uses all cores |
| Emotional multipliers | Module constant | **`:persistent_term`** | O(1) read, no config lookup |

## What Mneme Does Better

1. **Knowledge graph** — Mneme has full entity/relation extraction and graph traversal. Hippo has flat entries with no graph structure.

2. **Document pipeline** — Mneme ingests documents, chunks them, embeds chunks, and extracts entities. Hippo only stores single-entry memories.

3. **Pluggable backends** — Mneme's behaviours (`EmbeddingProvider`, `ExtractionProvider`, `GraphStore`) allow swapping implementations. Hippo is tightly coupled to SQLite.

4. **Multi-tenancy** — Mneme's `owner_id` + `scope_id` model is more flexible than Hippo's local/global file structure for multi-user applications.

5. **Embedding quality** — Mneme uses production embedding APIs (OpenRouter, OpenAI, Ollama). Hippo's optional local model is lower quality.

6. **Graph search** — Mneme can traverse edges to find related knowledge. Hippo has no graph traversal.

7. **Concurrency** — Mneme uses OTP processes, ETS, and `Task.async_stream` for parallel operations. Hippo is single-threaded Node.js.

## What Hippo Does Better

1. **Biological fidelity** — Hippo implements all 7 hippocampal mechanisms. Mneme implements 2 (decay, basic confidence).

2. **Forgetting as feature** — Hippo's decay is active filtering. Mneme's decay is cleanup.

3. **Closed learning loop** — Hippo's outcome feedback teaches the system what's useful. Mneme has no feedback mechanism.

4. **Session awareness** — Hippo has working memory, session events, handoffs. Mneme has minimal session concepts.

5. **Conflict awareness** — Hippo detects and flags contradictions. Mneme can represent contradictions but doesn't detect them.

6. **Human-readable storage** — Hippo's markdown mirrors are git-trackable and human-readable. Mneme's data lives only in Postgres.

## Complementary Strengths

The two systems are complementary rather than competitive:

- **Mneme** excels at structured knowledge management with graphs and document pipelines — ideal for applications that need to understand relationships between concepts.

- **Hippo** excels at adaptive memory with biological mechanisms — ideal for agents that need to learn what to remember and what to forget.

The enhancements in this directory bring Hippo's biological mechanisms into Mneme's structured knowledge framework, implemented with Elixir's OTP strengths rather than database tables.
