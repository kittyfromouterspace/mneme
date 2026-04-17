# Recollect Implementation Plan

> Consolidated from research on Hippo, Cognee, and HN discussions.
> Focuses on Elixir-idiomatic patterns.

## Overview

The 13 enhancements form a coherent memory lifecycle:

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  Context    │────▶│  Learning   │────▶│ Invalidation│
│  Detection  │     │  Pipeline   │     │  Pipeline   │
└─────────────┘     └──────┬──────┘     └──────┬──────┘
                           │                   │
                           ▼                   ▼
                    ┌──────────────────────────────────┐
                    │        Consolidation             │
                    │  (decay + merge + conflicts)      │
                    └──────────────────┬─────────────────┘
                                       │
                    ┌──────────────────┴──────────────────┐
                    │                                    │
                    ▼                                    ▼
           ┌────────────────┐                  ┌────────────────┐
           │   Retrieval    │                  │   Mipmaps      │
           │ (with context) │                  │ (detail levels)│
           └────────────────┘                  └────────────────┘
```

**Key insight**: Context is the thread that weaves all pieces together.

---

## Phase 1: Context Foundation ✅ COMPLETE

**Goal**: Add context hints to entries and detection at retrieval time.

### Step 1.1: Schema Changes ✅

Add `context_hints` to Entry schema:

```elixir
# lib/mneme/schema/entry.ex - add field
field(:context_hints, :map, default: %{})
```

Migration:
```elixir
alter table(:recollect_entries) do
  add :context_hints, :map, default: %{}
end
```

✅ **Done**: Added to `lib/mneme/schema/entry.ex` + migration `priv/repo/migrations/20250410000000_add_context_hints.exs`

### Step 1.2: Context Detector ✅

Create pure functions for detecting environment context:

```elixir
# lib/mneme/context/detector.ex
defmodule Recollect.Context.Detector do
  @detectors [:git, :path, :os]
  
  def detect do
    Enum.flat_map(@detectors, &run_detector/1)
    |> Enum.into(%{})
  end
  ...
end
```

✅ **Done**: Created `lib/mneme/context/detector.ex`

### Step 1.3: Auto-Capture on remember() ✅

Modify `Recollect.Knowledge.remember/2` to capture context:

```elixir
# lib/mneme/knowledge.ex - in remember/2
context_hints = 
  if opts[:context_hints] do
    opts[:context_hints]
  else
    Recollect.Context.Detector.detect()
  end
```

✅ **Done**: Modified `lib/mneme/knowledge.ex` to auto-capture context

### Step 1.4: Context Boost in Retrieval ✅

Add boost calculation in search:

```elixir
# lib/mneme/context/booster.ex
defmodule Recollect.Search.ContextBooster do
  def boost(entry_hints, current_context) do
    matches = Map.size(Map.take(entry_hints, Map.keys(current_context)))
    min(0.5, 0.15 * matches)
  end
end
```

✅ **Done**: Created `lib/mneme/context/booster.ex` and integrated into `lib/mneme/search/vector.ex`

---

## Phase 2: Learning Pipeline ✅ COMPLETE

**Goal**: Automatically extract knowledge from external sources.

### Step 2.1: Learner Behaviour ✅

Define the behaviour:

```elixir
# lib/mneme/learning/behaviour.ex
defmodule Recollect.Learner do
  @callback source() :: atom()
  @callback fetch_since(Date.t(), binary()) :: {:ok, [map()]} | {:error, term()}
  @callback extract(map()) :: {:ok, map()} | {:skip, binary()} | {:error, term()}
  @callback detect_patterns([map()]) :: [map()]
end
```

✅ **Done**: Created `lib/mneme/learning/behaviour.ex`

### Step 2.2: Git Learner (First Implementation) ✅

```elixir
# lib/mneme/learning/git.ex
defmodule Recollect.Learner.Git do
  @behaviour Recollect.Learner
  ...
end
```

✅ **Done**: Created `lib/mneme/learning/git.ex`

### Step 2.3: Learning Pipeline (Flow-based) ✅

```elixir
# lib/mneme/learning/pipeline.ex
defmodule Recollect.Learning.Pipeline do
  alias Recollect.{Config, Knowledge}
  
  def run(scope_id, opts \\ []) do
    # Fetch → Extract → Persist
  end
end
```

✅ **Done**: Created `lib/mneme/learning/pipeline.ex`

### Step 2.4: Learning Configuration ✅

```elixir
config :recollect,
  learning: [
    enabled: true,
    sources: [:git]
  ]
```

✅ **Done**: Added `Recollect.learn/1` API to main module

---

## Phase 3: Active Invalidation ✅ COMPLETE

**Goal**: Detect breaking changes and proactively weaken related memories.

### Step 3.1: Invalidation Detector ✅

```elixir
# lib/mneme/invalidation.ex
defmodule Recollect.Invalidation do
  @migration_patterns [
    ~r/migrate[ds]?\s+(?:from\s+)?(\w+)\s+(?:to|with)\s+(\w+)/i,
    ...
  ]
  
  def detect_migrations(days \\ 7) do
    # Parse git log for migration patterns
  end
end
```

✅ **Done**: Created `lib/mneme/invalidation.ex`

### Step 3.2: Invalidation Actions ✅

```elixir
# Invalidation module
defp weaken_related(scope_id, from_concept, to_concept) do
  # Update half-life for matching entries
end
```

✅ **Done**: Added `weaken_related/3` and `invalidate/3` to `lib/mneme/invalidation.ex`

### Step 3.3: Integrate with Learning ✅

✅ **Done**: Added `Recollect.invalidate/1` API to main module

---

## Phase 4: Handoffs ✅ COMPLETE

**Goal**: Explicit session handoffs for continuing work across sessions.

### Step 4.1: Handoff Schema ✅

```elixir
# priv/repo/migrations/..._add_handoffs_table.exs
create table(:recollect_handoffs, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :scope_id, :binary_id
  add :session_id, :binary_id
  add :what, :text
  add :next, {:array, :string}
  add :artifacts, {:array, :string}
  add :blockers, {:array, :string}
  add :created_at, :utc_datetime_usec
end
```

✅ **Done**: Created migration `20250411000000_add_handoffs_table.exs`

### Step 4.2: Handoff API ✅

```elixir
# lib/mneme/handoff.ex
defmodule Recollect.Handoff do
  def create(scope_id, opts \\ [])
  def get(scope_id)
  def recent(scope_id, since \\ ...)
end
```

✅ **Done**: Created `lib/mneme/handoff.ex`

### Step 4.3: Working Memory Integration ✅

```elixir
# lib/mneme/working_memory.ex
def on_session_resume(scope_id) do
  case Recollect.Handoff.get(scope_id) do
    {:ok, handoff} ->
      push(scope_id, "📋 #{handoff.what}", importance: 0.95)
      Enum.each(handoff.next, &push(scope_id, "→ #{&1}", importance: 0.8))
    _ -> :ok
  end
end
```

✅ **Done**: Added `load_handoff/2` to `lib/mneme/working_memory.ex`

✅ **Done**: Added `Recollect.handoff/2` and `Recollect.get_handoff/1` to main API

---

## Phase 5: Mipmaps ✅ COMPLETE

**Goal**: Progressive detail levels for retrieval.

### Step 5.1: Mipmap Table ✅

```elixir
# priv/repo/migrations/..._add_mipmaps_table.exs
create table(:recollect_mipmaps, primary_key: false) do
  add :entry_id, :binary_id, primary_key: true
  add :level, :string, primary_key: true  # :anchor, :abstract, :summary, :full
  add :content, :text
  add :metadata, :map
  add :embedding, :bytea
end
```

✅ **Done**: Created migration and `lib/mneme/mipmap/generator.ex`

### Step 5.2: Mipmap Generator ✅

```elixir
# lib/mneme/mipmap/generator.ex
defmodule Recollect.Mipmap do
  def generate_for(entry) do
    # :full, :summary, :abstract, :anchor
  end
end
```

✅ **Done**: Created `lib/mneme/mipmap/generator.ex`

### Step 5.3: Pluggable Retriever ✅

✅ **Done**: Added `retrieve/3` to `Recollect.Mipmap` module

---

## Implementation Complete ✅

All 5 phases implemented:

| Phase | Status | Files |
|-------|--------|-------|
| 1. Context Foundation | ✅ | `context/detector.ex`, `context/booster.ex`, schema changes |
| 2. Learning Pipeline | ✅ | `learning/behaviour.ex`, `learning/git.ex`, `learning/pipeline.ex` |
| 3. Active Invalidation | ✅ | `invalidation.ex` |
| 4. Handoffs | ✅ | `handoff.ex`, migration, WorkingMemory integration |
| 5. Mipmaps | ✅ | `mipmap/generator.ex`, migration |

### New API Functions

```elixir
# Context-aware retrieval (automatic)
{:ok, results} = Recollect.search("terminal performance")
# Results are boosted if they match current git repo/path/OS

# Learning from git
{:ok, result} = Recollect.learn(scope_id: workspace_id)

# Active invalidation
{:ok, result} = Recollect.invalidate(scope_id: workspace_id)

# Session handoffs
Recollect.handoff(workspace_id, what: "Implementing auth", next: ["Add controller"])
{:ok, handoff} = Recollect.get_handoff(workspace_id)
Recollect.WorkingMemory.load_handoff(workspace_id)
```

### New Migrations Required

```bash
mix ecto.gen.migration add_context_hints
mix ecto.gen.migration add_handoffs_table
mix ecto.gen.migration add_mipmaps_table
mix ecto.migrate
```

| Phase | Steps | Dependencies |
|-------|-------|--------------|
| **1. Context** | 1.1 → 1.2 → 1.3 → 1.4 | None |
| **2. Learning** | 2.1 → 2.2 → 2.3 → 2.4 | Phase 1 |
| **3. Invalidation** | 3.1 → 3.2 → 3.3 | Phase 2 |
| **4. Handoffs** | 4.1 → 4.2 → 4.3 | Phase 1 |
| **5. Mipmaps** | 5.1 → 5.2 → 5.3 | None |

---

## File Structure After Implementation

```
lib/mneme/
  ├── application.ex              # (existing)
  ├── knowledge.ex                # (existing, modified)
  ├── recollect.ex                    # (existing)
  │
  ├── context/
  │   ├── detector.ex            # NEW
  │   └── booster.ex             # NEW
  │
  ├── learning/
  │   ├── behaviour.ex           # NEW
  │   ├── pipeline.ex            # NEW
  │   └── git.ex                 # NEW
  │
  ├── invalidation/
  │   ├── detector.ex            # NEW
  │   └── actions.ex             # NEW
  │
  ├── handoff.ex                  # NEW
  │
  ├── mipmap/
  │   ├── generator.ex            # NEW
  │   └── retriever.ex           # NEW
  │
  ├── search/
  │   ├── vector.ex               # (existing, modified)
  │   └── retriever.ex           # NEW (behaviour)
  │
  └── working_memory/
      ├── server.ex               # (existing, modified)
      └── ...                    # (existing)
```

---

## Testing Strategy

Each phase includes:
1. **Unit tests** for pure functions (detectors, mipmap generation)
2. **Integration tests** for API changes (remember captures context, search boosts)
3. **OTP tests** for GenServer interactions (working memory, learning pipeline)
4. **Property tests** for mathematical properties (strength decay, context boost bounds)

---

## Configuration After Implementation

```elixir
config :recollect,
  # Context detection
  context: [
    enabled: true,
    detectors: [:git, :path, :os],
    boost: [max: 0.5, per_match: 0.15]
  ],
  
  # Learning system
  learning: [
    enabled: true,
    sources: [:git],  # Expand to [:git, :terminal, :ci]
    git: [since_days: 7]
  ],
  
  # Active invalidation
  invalidation: [
    enabled: true,
    auto_detect: true,
    weaken_factor: 0.1
  ],
  
  # Handoffs
  handoff: [
    enabled: true,
    auto_resume: true
  ],
  
  # Mipmaps (optional)
  mipmap: [
    enabled: false  # Off by default
  ]
```

---

## Backward Compatibility

All changes are additive:
- `context_hints` defaults to `%{}` (backward compatible)
- Learning is opt-in via config
- Search context boost is opt-in
- Mipmaps are opt-in

No breaking changes to existing APIs.
