# Mneme Enhancements — Hippo-Inspired Memory Mechanics

> Based on analysis of [hippo-memory](https://github.com/hippo-memory), a biologically-inspired memory system for AI agents.

## Overview

Hippo models seven properties of the human hippocampus. Mneme already shares several concepts (decay, confidence, hybrid search, dual-tier architecture). This document proposes enhancements that close the gaps and add unique capabilities — implemented using Elixir's OTP primitives rather than database tables wherever appropriate.

### Enhancement Summary

| # | Enhancement | Priority | Effort | Doc |
|---|------------|----------|--------|-----|
| 1 | Retrieval Strengthening | High | Low | [01-retrieval-strengthening.md](01-retrieval-strengthening.md) |
| 2 | Working Memory Layer | High | Medium | [02-working-memory.md](02-working-memory.md) |
| 3 | Outcome Feedback Loop | High | Low | [03-outcome-feedback.md](03-outcome-feedback.md) |
| 4 | Confidence Lifecycle | Medium | Low | [04-confidence-lifecycle.md](04-confidence-lifecycle.md) |
| 5 | Emotional Valence | Medium | Low | [05-emotional-valence.md](05-emotional-valence.md) |
| 6 | Schema Acceleration | Medium | Medium | [06-schema-acceleration.md](06-schema-acceleration.md) |
| 7 | Conflict Detection | Medium | Medium | [07-conflict-detection.md](07-conflict-detection.md) |
| 8 | Sleep Consolidation | Low | High | [08-sleep-consolidation.md](08-sleep-consolidation.md) |

## What Mneme Already Has

Mneme is not starting from zero. These concepts already exist and form the foundation:

- **Decay mechanism** — archives entries after N days with low access count
- **Confidence field** — float 0.0–1.0 on entries
- **Access tracking** — `access_count` and `last_accessed_at` with async bumping
- **Hybrid search** — vector similarity + graph edge traversal
- **Entry types** — `note`, `outcome`, `event`, `decision`, `observation`, `hypothesis`, `session_summary`, `conversation_turn`, `archived`
- **Edge relations** — `leads_to`, `supports`, `contradicts`, `derived_from`, `supersedes`, `related_to`
- **Dual scoping** — `owner_id` and `scope_id` on all schemas
- **Content dedup** — hash-based deduplication in Tier 1 ingestion
- **Supersession** — `supersedes` edge type for replacing stale knowledge
- **TaskSupervisor** — existing `Mneme.TaskSupervisor` for async operations
- **Telemetry** — `Mneme.Telemetry` for instrumentation

## Elixir OTP Strategy

Rather than adding database tables for every new concept, these enhancements leverage Elixir's strengths:

| Concept | Hippo (TypeScript) | Mneme (Elixir) | Rationale |
|---------|-------------------|----------------|-----------|
| Working memory | SQLite table | **GenServer per scope** | Ephemeral, bounded, session-scoped |
| Retrieval counters | In-memory | **ETS `:counter` + GenServer flush** | High-write, batch-flush to DB |
| Schema index | Recomputed on demand | **ETS table, rebuilt during consolidation** | O(1) lookup vs O(n) query |
| Last-retrieved tracking | Process state | **ETS table** | Cross-process, no GenServer needed |
| Conflict detection | Sequential loop | **`Task.async_stream`** | CPU-bound, embarrassingly parallel |
| Consolidation merge | Sequential | **`Task.async_stream`** | Parallel overlap computation |
| Emotional multipliers | Module constant | **`:persistent_term`** | O(1) read, no config lookup |

## Supervision Tree

```
Mneme.Supervisor (one_for_one)
├── Mneme.TaskSupervisor                          [EXISTING]
│   ├── [async pipeline runs]
│   ├── [async embed_entry tasks]
│   ├── [async bump_access tasks]
│   └── [consolidation parallel workers]
│
├── Mneme.RetrievalCounter (GenServer)            [NEW]
│   └── Owns ETS :mneme_retrieval_counters (:counter)
│   └── Periodic flush to DB every 30s
│
├── Mneme.WorkingMemory.Supervisor (DynamicSupervisor)  [NEW]
│   ├── WorkingMemory.Server (scope: "abc")       [NEW, dynamic]
│   ├── WorkingMemory.Server (scope: "def")       [NEW, dynamic]
│   └── ... (auto-started on push, auto-killed on flush)
│
├── Mneme.MaintenanceScheduler (GenServer)        [NEW, optional]
│   └── Periodic decay + consolidation scheduling

ETS Tables (no process owner):
├── :mneme_last_retrieved — {scope_id, [entry_ids]}
└── :mneme_schema_index — {tag_frequency, map}, {entry_count, int}

:persistent_term:
├── {:mneme, :emotional_multipliers} → %{neutral: 1.0, ...}
└── {:mneme, :retrieval_strengthening} → [half_life_boost_days: 2]
```

## Key Insight: Forgetting Is a Feature

Hippo's core philosophy differs from Mneme's current approach:

| | Mneme (current) | Hippo | Proposed |
|--|-----------------|-------|----------|
| **Decay** | Cleanup mechanism — archive old entries | Active filtering — memories must earn persistence | Active filtering with retrieval strengthening |
| **Persistence** | Entries persist until explicitly decayed | Half-life by default, survival through use | Half-life + retrieval boost + outcome feedback |
| **Philosophy** | "Save everything, clean up later" | "Know what to forget" | "Earn your place through relevance" |

## Architecture After Enhancements

```
┌──────────────────────────────────────────────────────────────────┐
│ Tier 0: Working Memory (NEW — GenServer per scope)               │
│                                                                  │
│ Bounded buffer per scope. Session-scoped. No embeddings.         │
│ Importance-based eviction. Cleared on session end.               │
├──────────────────────────────────────────────────────────────────┤
│ Tier 2: Lightweight Knowledge (ENHANCED)                         │
│                                                                  │
│ Entry + Edge with retrieval strengthening, outcome feedback,     │
│ confidence lifecycle, emotional valence, schema acceleration.    │
├──────────────────────────────────────────────────────────────────┤
│ Tier 1: Full Pipeline (UNCHANGED)                                │
│                                                                  │
│ Collection → Document → Chunk → Entity → Relation                │
│ Markdown-aware chunking, LLM extraction, graph traversal.        │
├──────────────────────────────────────────────────────────────────┤
│ Shared: Search (Vector + Graph + Hybrid), Context Formatting     │
│ Shared: Maintenance (Decay, Reembed, Sleep Consolidation, Conflicts) │
└──────────────────────────────────────────────────────────────────┘
```

## Implementation Order

Recommended implementation sequence (each builds on the previous):

1. **Retrieval Strengthening** — foundational, touches search + entry schema
2. **Outcome Feedback** — builds on retrieval strengthening
3. **Confidence Lifecycle** — enhances existing confidence field
4. **Working Memory** — GenServer, independent of other changes
5. **Emotional Valence** — new field, affects strength calculation
6. **Schema Acceleration** — uses ETS for tag frequency index
7. **Conflict Detection** — uses existing `contradicts` edge type
8. **Sleep Consolidation** — orchestrates all mechanisms together

## Cross-Cutting Concerns

### Migration Strategy

All enhancements are additive. No breaking changes to existing APIs:

- New columns default to safe values (nil, 0, neutral)
- Existing entries work without modification
- New behavior opt-in via configuration
- **One fewer table**: working memory uses GenServer, not a DB table

### Configuration

All new features configurable via `config :mneme`:

```elixir
config :mneme,
  # Existing config...
  repo: MyApp.Repo,

  # New: retrieval strengthening
  retrieval_strengthening: [
    enabled: true,
    half_life_boost_days: 2,
    flush_interval_ms: 30_000
  ],

  # New: outcome feedback
  outcome_feedback: [
    enabled: true,
    positive_half_life_delta: 5,
    negative_half_life_delta: -3
  ],

  # New: working memory
  working_memory: [
    enabled: true,
    max_entries_per_scope: 20
  ],

  # New: emotional valence
  emotional_valence: [
    enabled: true,
    multipliers: %{neutral: 1.0, positive: 1.3, negative: 1.5, critical: 2.0}
  ],

  # New: confidence lifecycle
  confidence_lifecycle: [
    enabled: true,
    stale_threshold_days: 30
  ],

  # New: sleep consolidation
  sleep_consolidation: [
    enabled: true,
    decay_threshold: 0.05,
    merge_overlap_threshold: 0.35,
    merge_min_cluster: 3
  ]
```

### Testing Strategy

Each enhancement includes:
- Unit tests for formulas and calculations
- Integration tests for API changes
- Property-based tests for strength/decay formulas
- Migration tests for schema changes
- **OTP tests**: GenServer state transitions, ETS counter flush behavior, DynamicSupervisor lifecycle
