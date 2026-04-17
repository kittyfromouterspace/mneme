# Recollect Improvements — MemPalace Research

This document explores potential improvements inspired by MemPalace (https://github.com/milla-jovovich/mempalace), analyzing complexity vs. potential gains.

## Executive Summary

| Improvement | Complexity | Potential Gain | Recommendation |
|-------------|------------|----------------|----------------|
| LLM-free Memory Classification | Low | Medium | **Done** |
| KG-aware Contradiction Detection | Medium | High | **Done** |
| Enhanced Metadata Filtering | Low | Medium | **Done** |

---

## Task Tracking

### Phase 1: LLM-free Memory Classification

| Task | Status | Notes |
|------|--------|-------|
| Create `Recollect.Classification` module | ✅ Done | `lib/recollect/classification.ex` |
| Add regex patterns for 5 categories | ✅ Done | decision, preference, milestone, problem, emotional |
| Integrate into `Knowledge.remember/2` | ✅ Done | Added `:auto_classify` option |
| Add tests | ❌ Not done | — |

### Phase 2: Contradiction Detection

| Task | Status | Notes |
|------|--------|-------|
| Add claim extraction to Classification | ✅ Done | `extract_claims/1` function |
| Create `Knowledge.check_contradiction/3` | ✅ Done | Detects attribution & status conflicts |
| Add telemetry | ✅ Done | `[:recollect, :contradiction_check, :stop]` |
| Add conflict resolution UI | ❌ Not done | Future enhancement |

### Phase 3: Enhanced Filtering

| Task | Status | Notes |
|------|--------|-------|
| Extend Search.Vector with filters | ✅ Done | entry_type, temporal, confidence_min |
| Add temporal filter support | ✅ Done | `:recent` for last 30 days |
| Document new search patterns | ✅ Done | In telemetry.md |

---

## Implementation Details

### 1. LLM-free Memory Classification

### What is it?

MemPalace's `general_extractor.py` uses regex-based pattern matching to classify text into categories without calling an LLM:

- **DECISIONS** — "we went with X because Y", "decided to use"
- **PREFERENCES** — "always use X", "never do Y", "I prefer Z"
- **MILESTONES** — "it works", "breakthrough", "finally fixed"
- **PROBLEMS** — "bug", "error", "doesn't work", "root cause"
- **EMOTIONAL** — "love", "scared", "proud", "grateful"

### How would it work in Recollect?

Add a new module `Recollect.Classification` that runs before/after embedding:

```elixir
defmodule Recollect.Classification do
  @memory_types ~w[decision preference milestone problem emotional note]a
  
  def classify(text) do
    # Run regex patterns, return type with confidence
  end
end
```

Integrate into `Knowledge.remember/2`:

```elixir
def remember(content, opts \\ []) do
  {type, confidence} = Classification.classify(content)
  opts = Keyword.put(opts, :entry_type, type)
  # ... rest of remember
end
```

### Complexity Analysis

| Aspect | Estimate |
|--------|----------|
| New module | ~200 LOC |
| Regex patterns | ~50 patterns across 5 categories |
| Testing | ~100 LOC test code |
| Integration | Modify `Knowledge.remember/2` |

**Total Complexity: LOW**

### Potential Gains

1. **Automatic tagging** — Entries auto-classified without LLM calls
2. **Better search** — Users can filter by memory type
3. **Insight generation** — "Show me all decisions from Q1"

MemPalace benchmarks show this approach works for ~60-70% of content classification. The patterns are well-documented in their `general_extractor.py`.

### Risks

- Pattern matching is brittle — some content won't match
- Overlap between categories (a "fixed problem" is both)
- Requires ongoing pattern tuning

### Recommendation: **DO FIRST** — Low complexity, medium gains, good foundation for other features.

---

## 2. KG-aware Contradiction Detection

### What is it?

MemPalace has `fact_checker.py` that checks new facts against the knowledge graph:
- "Soren finished the auth migration" → conflicts with "Maya was assigned to auth migration"
- "Kai has been here 2 years" → conflicts with records showing 3 years

### Current State in Recollect

Recollect already has `ConflictDetection` (`lib/recollect/conflict_detection.ex`), but it:
- Compares entries **pairwise** (O(n²))
- Doesn't check against the **knowledge graph** entities/relations

### How would it work?

Add `Recollect.Knowledge.contradiction_check/2`:

```elixir
defmodule Recollect.Knowledge do
  @doc """
  Check if a new fact contradicts existing knowledge graph.
  Returns {:conflict, details} or :ok.
  """
  def check_contradiction(content, scope_id, owner_id) do
    # 1. Extract entity claims from content (simple regex for "X is Y", "X works on Y")
    # 2. Query KG for existing facts about that entity
    # 3. Compare and flag conflicts
  end
end
```

Example conflicts to detect:
- **Attribution conflicts** — "Alice did X" vs existing "Bob did X"
- **Temporal conflicts** — "started 2023" vs "started 2024"
- **Status conflicts** — "X is complete" vs "X is in progress"

### Complexity Analysis

| Aspect | Estimate |
|--------|----------|
| New function in Knowledge module | ~100 LOC |
| Claim extraction (regex) | ~50 patterns |
| KG query helpers | ~50 LOC |
| Integration hook | Modify pipeline |

**Total Complexity: MEDIUM**

### Potential Gains

1. **Data integrity** — Automatic flagging of contradictory entries
2. **Trust scoring** — Entries with conflicts get lower confidence
3. **User alerts** — "This conflicts with existing knowledge"

This is the core value prop of systems like Mem0 and Zep. MemPalace's 96.6% benchmark comes from raw storage, but KG-backed contradiction detection is a key differentiator.

### Risks

- Must define what constitutes a "contradiction" (harder than it looks)
- Performance: don't check every entry, only new ones
- False positives: "formerly worked at X" vs "works at X"

### Recommendation: **DO SECOND** — Medium complexity, high potential gains, differentiates Recollect.

---

## 3. Enhanced Metadata Filtering

### What is it?

MemPalace shows that filtering by wing+room provides +34% retrieval improvement:
```
Search all:        60.9% R@10
Search within wing: 73.1% (+12%)
Search wing + room: 94.8% (+34%)
```

### Current State in Recollect

Recollect already supports:
- `scope_id` — workspace/project
- `owner_id` — user
- `entry_type` — note, decision, event, etc.
- `tags` — custom tags (stored in metadata)

### What's Missing

1. **Multi-criteria filtering** — Combine scope + entry_type + tags in one query
2. **Temporal filtering** — "entries from last 30 days"
3. **Hall/Category filtering** — Align with MemPalace's halls (facts, events, discoveries, preferences, advice)

### How would it work?

Extend `Search.Vector`:

```elixir
def search(query_text, opts \\ []) do
  filters = Keyword.get(opts, :filters, %{})
  # %{scope_id: ..., entry_type: :decision, tags: ["auth"], temporal: :recent}
  
  # Build dynamic where clause
end
```

### Complexity Analysis

| Aspect | Estimate |
|--------|----------|
| New search options | ~50 LOC |
| Schema migration (if needed) | Minor |
| Tests | ~50 LOC |

**Total Complexity: LOW**

### Potential Gains

- Better retrieval accuracy (+34% per MemPalace)
- Users can find "decisions about auth in the last week"
- Foundation for more sophisticated filtering

### Risks

- Query complexity increases
- Performance with many filters

### Recommendation: **CONSIDER** — Low complexity, medium gains. Good foundation but not urgent.

---

## 4. Memory Type Taxonomy Alignment

### What is it?

MemPalace uses "halls" as memory categories:
- `hall_facts` — decisions made, choices locked in
- `hall_events` — sessions, milestones, debugging
- `hall_discoveries` — breakthroughs, new insights
- `hall_preferences` — habits, likes, opinions
- `hall_advice` — recommendations and solutions

### Current State in Recollect

Recollect's `entry_types`:
```elixir
~w(outcome event decision observation hypothesis note session_summary conversation_turn archived)
```

### Alignment Analysis

| MemPalace Hall | Recollect Entry Type | Alignment |
|----------------|------------------|-----------|
| hall_facts | decision, outcome | ✅ Close |
| hall_events | event, session_summary | ✅ Close |
| hall_discoveries | hypothesis, observation | ✅ Close |
| hall_preferences | note (with preference tag) | ⚠️ Needs tag |
| hall_advice | note (with advice tag) | ⚠️ Needs tag |

### Recommendation: **SKIP** — Recollect's taxonomy is already close. Add tags via classification feature instead.

---

## Implementation Roadmap

### Phase 1: Classification (Week 1)

1. Create `Recollect.Classification` module
2. Add regex patterns for 5 categories
3. Integrate into `Knowledge.remember/2`
4. Add tests

### Phase 2: Contradiction Detection (Week 1-2)

1. Add claim extraction to Classification
2. Create `Knowledge.check_contradiction/3`
3. Integrate into pipeline (optional, or on-demand)
4. Add conflict resolution UI (future)

### Phase 3: Enhanced Filtering (Week 2)

1. Extend Search.Vector with filter options
2. Add temporal filter support
3. Document new search patterns

---

## Appendix: Key Files Reference

### MemPalace (inspiration)
- `general_extractor.py` — LLM-free classification (519 lines)
- `knowledge_graph.py` — Temporal KG (387 lines)
- `searcher.py` — ChromaDB search (152 lines)
- `layers.py` — 4-layer memory stack (515 lines)

### Recollect (current)
- `lib/recollect/knowledge.ex` — Tier 2 API (144 lines)
- `lib/recollect/conflict_detection.ex` — Pairwise conflict (192 lines)
- `lib/recollect/schema/entry.ex` — Entry schema (78 lines)
- `lib/recollect/schema/entity.ex` — Entity schema (60 lines)
- `lib/recollect/search.ex` — Unified search (111 lines)

---

## Conclusion

The most valuable additions are:

1. **LLM-free classification** — Immediate value, low complexity
2. **KG-aware contradiction detection** — High value, medium complexity

These align with Recollect's existing architecture and extend capabilities without requiring significant rewrites.

The enhanced filtering is a "nice to have" that can be addressed once the core features are stable.
