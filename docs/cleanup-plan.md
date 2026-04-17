# Recollect Cleanup — Implementation Plan

> **Status: Completed** (2026-04-17)
>
> Post-refactor cleanup following the v0.5.0 consolidation of duplicate learners,
> shared utilities, and orphan module integration.
>
> All 22 items across 4 phases have been executed. Final gate: `mix check` passes.

## Scope

~20 items across 4 priority tiers. Every item includes: the change, files
affected, documentation impact, and verification step. The final gate is
`mix check` (a new alias we will create that runs format + test + docs + credo).

---

## Phase 1: Quick Wins (no semantic changes)

### 1.1 Remove no-op pipeline code

**File:** `lib/recollect/learning/pipeline.ex:161`

```elixir
|> then(fn {l, s} -> {l, s} end)
```

Identity function that does nothing. Remove the pipe.

**Docs:** None — internal cleanup.

### 1.2 Remove empty `invalidation/` directory

**Path:** `lib/recollect/invalidation/`

Leftover from a previous refactor. The invalidation module is a single file at
`lib/recollect/invalidation.ex`.

**Docs:** None.

### 1.3 Remove unused `data_paths/0` delegation in 4 providers

**Files:**
- `lib/recollect/learning/coding_agent/claude_code.ex:51`
- `lib/recollect/learning/coding_agent/codex.ex:29`
- `lib/recollect/learning/coding_agent/gemini.ex:27`
- `lib/recollect/learning/coding_agent/opencode.ex:28`

Each has `def data_paths, do: default_data_paths()` — a public function that
just delegates to a private one. Remove the public wrapper; the behaviour
infrastructure already uses `default_data_paths/0`.

**Docs:** Update `usage-rules/extension-points.md` if `data_paths/0` is documented.

### 1.4 Mark unused public functions as `@doc false`

| File | Function | Reason |
|------|----------|--------|
| `lib/recollect/outcome_tracker.ex:35` | `clear/1` | Never called |
| `lib/recollect/retrieval_counter.ex:36` | `count/1` | Debug-only |
| `lib/recollect/classification.ex:143` | `types/0` | Never called |

**Docs:** None — these were never documented as public API.

### 1.5 Use `Recollect.Util.row_to_map` in `export.ex`

**File:** `lib/recollect/export.ex:169-177`

Replace inline `columns |> Enum.zip(row) |> Map.new()` with
`Recollect.Util.row_to_map(columns, row)`.

**Docs:** None — internal refactor.

### 1.6 Remove `resolve_paths` delegation in 4 providers

**Files:** claude_code.ex, codex.ex, gemini.ex, opencode.ex (coding_agent/)

Each has `defp resolve_paths(config), do: Util.resolve_paths(config)`. Replace
with `import Recollect.Learner.CodingAgent.Util, only: [resolve_paths: 1]` at
the top of each file.

**Docs:** None.

### 1.7 Fix `text_overlap` to delegate to `jaccard`

**File:** `lib/recollect/util.ex`

```elixir
def text_overlap(a, b) do
  set_a = tokenize(a)
  set_b = tokenize(b)

  if MapSet.size(set_a) == 0 and MapSet.size(set_b) == 0 do
    1.0
  else
    jaccard(set_a, set_b)
  end
end
```

Currently duplicates Jaccard logic inline. Delegate to `jaccard/2` with the
empty-set guard.

**Docs:** None.

### 1.8 Fix `Outcome` confidence_state for negative outcomes

**File:** `lib/recollect/outcome.ex:67`

Currently `do_update/3` sets `confidence_state = 'verified'` for both `:good`
and `:bad` outcomes. Negative outcomes should set `confidence_state = 'active'`
(or leave unchanged) since a bad outcome means the memory is NOT verified.

**Docs:** Update `usage-rules/maintenance.md` Outcome Feedback section.

---

## Phase 2: Code Deduplication

### 2.1 Extract `embedding_to_str/1` to `Recollect.Util`

**Pattern** (appears 6 times):
```elixir
"[#{Enum.map_join(embedding, ",", &Float.to_string/1)}]"
```

**Locations:**
- `lib/recollect/search/vector.ex:46, 87, 103, 117`
- `lib/recollect/mipmap/generator.ex:87`

Note: the database adapters' `format_embedding/1` does this better (using
`format_float` for precision). Search/vector and mipmap should delegate to
`Config.adapter().format_embedding(embedding)` instead, which is already the
canonical way to convert embeddings to SQL strings.

**Approach:** Replace all 6 inline conversions with
`Config.adapter().format_embedding(embedding)`. This also ensures correct
formatting for each adapter (bracket notation for Postgres, JSON for SQLite).

**Docs:** None.

### 2.2 Extract shared SQLite adapter base

**Files:**
- `lib/recollect/database_adapter/sqlite_vec.ex` (159 lines)
- `lib/recollect/database_adapter/libsql.ex` (197 lines)

~90% identical. Shared functions: `format_embedding/1`, `format_float/1`,
`parse_embedding/1`, `format_uuid/1`, `placeholder/1`, `uuid_type/1`,
`create_vector_extension_sql/0`, `vector_ecto_type/0`.

**Approach:** Create `lib/recollect/database_adapter/sqlite_base.ex` with
`use` macro that provides default implementations. Each adapter overrides only
its diverging functions (`vector_type/1`, `vector_index_sql/3`,
`vector_distance_sql/2`, `dialect/0`, etc.).

**Docs:** None — internal refactor.

### 2.3 Consolidate manual duration tracking to `Telemetry.span/3`

**Files with manual duration tracking:**
- `lib/recollect/classification.ex:80-94`
- `lib/recollect/consolidation.ex:55-102`
- `lib/recollect/handoff.ex:42-76, 83-134`
- `lib/recollect/invalidation.ex:43-66, 89-117`

`Telemetry.span/3` already exists at `lib/recollect/telemetry.ex:68` and is used
by `pipeline.ex`, `search.ex`, and `completion.ex`. Convert the manual pattern:

```elixir
# Before (manual):
start_time = System.monotonic_time()
# ... work ...
duration = System.monotonic_time() - start_time
Telemetry.event([:recollect, :foo, :stop], %{duration_ms: ...})

# After (span):
Telemetry.span([:recollect, :foo], %{key: val}, fn ->
  # ... work ...
  %{result: result}
end)
```

**Docs:** None — same telemetry events emitted.

---

## Phase 3: Feature Integration

### 3.1 Integrate Mipmap into the pipeline

**File:** `lib/recollect/mipmap/generator.ex` (193 lines)

Currently orphaned — `persist/1` writes rows without embeddings (bug), and
`retrieve/3` filters on `embedding IS NOT NULL` (always empty result set).

**Changes needed:**

1. **Fix `persist/1`** — After inserting the row, call
   `Recollect.Pipeline.Embedder.embed_query(content)` to get the embedding
   vector, then UPDATE the row to set the embedding column.

2. **Wire into `Knowledge.remember/2`** — After an entry is created and
   embedded, call `Recollect.Mipmap.generate_for/1` and `Recollect.Mipmap.persist/1`
   to create mipmap levels for the entry.

3. **Wire into `Search.Vector`** — In the hybrid search function, after
   getting initial results, if results are sparse (< 3), call
   `Mipmap.retrieve/3` with the appropriate level (determined by query length)
   to get broader matches.

4. **Wire into `Maintenance.Reembed`** — After re-embedding entries, regenerate
   their mipmaps.

**Docs:**
- Update README.md Mipmaps section (currently mentioned in schema but not
  documented as a feature)
- Update `docs/architecture.md` Mipmaps section
- Update `usage-rules/search.md` with mipmap escalation behavior

### 3.2 Sync Mix task with MigrationGenerator

**Files:**
- `lib/mix/tasks/recollect.gen.migration.ex` (225 lines, hardcoded template)
- `lib/recollect/migration_generator.ex` (332 lines, correct template)

The Mix task has a hardcoded SQL template that is missing:
- Columns on `recollect_entries`: `half_life_days`, `pinned`,
  `emotional_valence`, `access_count`, `last_accessed_at`, `context_hints`,
  `outcome_score`, `confidence_state`, `embedding_model_id`
- Tables: `recollect_handoffs`, `recollect_conflicts`,
  `recollect_consolidation_runs`, `recollect_mipmaps`

**Approach:** Replace the Mix task's hardcoded template with a call to
`Recollect.MigrationGenerator.generate_up/2`. The Mix task becomes a thin
wrapper that reads `--dimensions`, writes the migration file, and runs
`ecto.migrate`.

**Docs:**
- Update `docs/git-learning.md` if migration generator is referenced
- No README change needed (the mix task interface is unchanged)

### 3.3 Remove WorkingMemory emoji prefixes

**File:** `lib/recollect/working_memory.ex:70-77`

Replace emoji prefixes (`"📋 "`, `"→ "`, `"📎 "`) with plain text prefixes
(`"Handoff: "`, `"Next: "`, `"Artifact: "`). Emojis in content that gets embedded
confuse vector similarity search.

**Docs:** Update README.md Working Memory example if the output format
changes noticeably.

---

## Phase 4: Housekeeping

### 4.1 Move test-only modules to `test/support/`

**Files:**
- `lib/recollect/embedding/mock.ex` → `test/support/embedding_mock.ex`
- `lib/recollect/test_repo.ex` → `test/support/test_repo.ex` (already exists there?)

These are compiled in production despite being test-only. The `mix.exs`
already has `elixirc_paths(:test)` for `test/support/` but these files live in
`lib/`.

**Docs:** None — internal build change.

### 4.2 Delete old `mneme` migration reference

**File:** `priv/repo/migrations/20240101000000_create_mneme_tables.exs`

The module is correctly named `CreateRecollectTables` but the file was created
during the "mneme" era. The hardcoded `vector(768)` and missing columns make it
stale. This migration is needed for existing installations that already ran it,
so **do not delete it** — but add a comment noting it's superseded by the
MigrationGenerator for fresh installs.

**Docs:** None.

### 4.3 Add `mix check` alias

**File:** `mix.exs`

Add a `mix check` alias that runs all quality gates:

```elixir
aliases: [
  test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
  check: ["format --check-formatted", "test", "docs"]
]
```

Update AGENTS.md Dev Commands section to document `mix check`.

**Docs:** Update AGENTS.md.

### 4.4 Update documentation to match all changes

**Files affected:**
- `README.md` — Mipmap section (if exposed as feature), Working Memory
  example (emoji removal), any API changes
- `usage-rules.md` — top-level rules, remove any references to removed
  functions
- `usage-rules/search.md` — mipmap escalation, embedding_to_str changes
- `usage-rules/maintenance.md` — Outcome confidence_state fix
- `usage-rules/extension-points.md` — SQLite base adapter pattern
- `docs/architecture.md` — Mipmap integration (if exposed), SQLite base
- `AGENTS.md` — Add `mix check` to Dev Commands, update Release SOP to
  use `mix check` as the quality gate

---

## Execution Order

| Step | Phase | Item | Risk | Depends on |
|------|-------|------|------|------------|
| 1 | 1 | Remove no-op pipeline code | None | — |
| 2 | 1 | Remove empty directory | None | — |
| 3 | 1 | Remove data_paths wrappers | None | — |
| 4 | 1 | Mark dead functions @doc false | None | — |
| 5 | 1 | export.ex row_to_map | None | — |
| 6 | 1 | Remove resolve_paths delegation | None | — |
| 7 | 1 | Fix text_overlap delegation | None | — |
| 8 | 1 | Fix Outcome confidence_state | Low | — |
| 9 | 1 | `mix test` | — | Steps 1-8 |
| 10 | 2 | Embedding-to-str via adapter | Medium | Step 9 |
| 11 | 2 | SQLite adapter base | Medium | Step 9 |
| 12 | 2 | Telemetry.span conversion | Medium | Step 9 |
| 13 | 2 | `mix test` | — | Steps 10-12 |
| 14 | 3 | Integrate Mipmap | High | Step 13 |
| 15 | 3 | Sync Mix task with MigrationGenerator | Medium | Step 13 |
| 16 | 3 | Remove WorkingMemory emojis | Low | Step 13 |
| 17 | 3 | `mix test` | — | Steps 14-16 |
| 18 | 4 | Move test modules | Low | Step 17 |
| 19 | 4 | Annotate old migration | None | Step 17 |
| 20 | 4 | Add `mix check` alias | None | Step 17 |
| 21 | 4 | Update all documentation | None | Step 20 |
| 22 | 4 | **Final gate: `mix check`** | — | Step 21 |

## Verification

After every phase, run `mix test` to catch regressions. After all changes, run
`mix check` (the new alias) as the final quality gate.

Items that require `mix test` to pass between phases are noted in the
execution order table above.
