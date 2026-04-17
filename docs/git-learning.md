# Learning Pipeline

This document describes how Recollect learns from development activity — git history and coding agent sessions — covering the full pipeline from raw events to synthesized memory entries and stack deprecation events.

## Overview

### Git learning

```
git log ──→ fetch_since ──→ extract (per-commit) ──→ store individual entries
                 │                                          (breaking/migration/revert only)
                 │
                 └──→ summarize (batch) ──→ Grouper ──→ development_insight entries
                       │
                       └──→ StackDetector ──→ deprecation events ──→ Invalidation.deprecate
```

### Coding agent learning

```
CodingAgent dispatcher ──→ discover providers ──→ for each available provider:
  ├── fetch events (memory files, sessions, configs)
  ├── extract per event → Knowledge.remember
  └── summarize sessions → batched development_insight
```

Both pipelines use the same `Recollect.Learner` behaviour and are orchestrated by `Recollect.Learning.Pipeline`.

## Coding Agent Learning

The `Recollect.Learner.CodingAgent` module is a dispatcher that discovers and delegates to provider modules for each supported coding agent (Claude Code, Codex, Gemini, OpenCode). Each provider implements `Recollect.Learner.CodingAgent.Provider` and handles the specifics of its agent's data layout.

### Provider architecture

```
lib/mneme/learning/coding_agent.ex           # Dispatcher — implements Recollect.Learner
lib/mneme/learning/coding_agent/
├── provider.ex       # Behaviour: agent_name, available?, discover, fetch, extract, summarize
├── util.ex           # Shared helpers: frontmatter parsing, JSONL, project tags
├── claude_code.ex    # Claude Code provider
├── codex.ex          # OpenAI Codex provider
├── gemini.ex         # Gemini CLI provider
└── opencode.ex       # OpenCode provider
```

### Claude Code provider

Three-layer extraction:

1. **Memory files** (primary) — curated Markdown from `~/.claude/projects/<slug>/memory/`. Already distilled by Claude with YAML frontmatter. Classified by filename prefix:
   - `project_*` → `development_insight`
   - `feedback_*` → `decision`
   - `user_*` → `preference`
2. **CLAUDE.md** — project-level instructions stored as a `decision` entry.
3. **Session summarization** — JSONL transcripts summarized into batched `development_insight` entries.

### Codex provider

Reads from `~/.codex/`:
- `sessions/YYYY/MM/DD/rollup-*.jsonl` — session transcripts
- `instructions.md` — user instructions as a `decision` entry

### Gemini provider

Reads from `~/.gemini/`:
- `tmp/<project>/chats/session-*.json` — session transcripts
- `GEMINI.md` — project instructions

### OpenCode provider

Reads from `~/.local/share/opencode/opencode.db` (SQLite):
- `session`, `message`, `project` tables
- User prompts and assistant responses extracted per session

### Adding new providers

1. Create `lib/mneme/learning/coding_agent/my_agent.ex`
2. Implement `Recollect.Learner.CodingAgent.Provider` behaviour
3. Add the module to `@providers` in `coding_agent.ex`
4. The dispatcher auto-discovers available providers at runtime

## Entry Types

| Entry type | When produced | Half-life | Confidence |
|---|---|---|---|
| `decision` | Breaking changes, migrations stored individually | 7 days (default) | 1.0 |
| `observation` | Reverts stored individually | 7 days (default) | 1.0 |
| `development_insight` | Grouped commit narratives (Grouper) | 30 days | 0.9 |
| `development_insight` (deprecation) | Stack transitions detected | 60 days, pinned | 1.0 |
| `decision` (replacement) | New technology after deprecation | 45 days | 1.0 |

## Layer 1: Per-Event Extraction

**Module:** `Recollect.Learner.Git.extract/1`

Not every commit deserves its own memory entry. The extract function applies two filters:

### Noise filter

Commits matching these patterns are discarded entirely:

- Merge commits (`Merge pull request...`, `Merge branch...`)
- Version bumps (`1.2.3`, `v2.0.0`)
- Typo/whitespace/formatting fixes
- Lint fix commits
- WIP commits
- CI/deps chore commits

### Significance filter

After noise filtering, only commits of these types are stored individually:

- `:breaking` — stored as `decision` with negative valence
- `:migration` — stored as `decision` with negative valence
- `:revert` — stored as `hypothesis` with neutral valence

Everything else (`:fix`, `:feat`, `:refactor`, `:test`, `:docs`, `:other`) returns `{:skip, _}`. These commits are not lost — they feed into the summarize layer.

## Layer 2: Batch Summarization

**Module:** `Recollect.Learner.Git.summarize/2` (called by `Recollect.Learning.Pipeline`)

The optional `summarize/2` learner callback receives all fetched events and returns synthesized extracts. For the Git learner, this means two sub-steps: grouping and stack detection.

### 2a. Commit Grouping (Grouper)

**Module:** `Recollect.Learner.Git.Grouper`

1. **Filter noise** — same noise filter as Layer 1 (merges, version bumps, typos)
2. **Extract topics** — conventional-commit scope (`feat(auth):...`) or keyword extraction from the subject
3. **Group by topic** — commits sharing a topic form a cluster
4. **Build insights** — each cluster of 2+ commits becomes one `development_insight` entry

Each group insight contains:

```
Development activity in auth (3 commits):

Breakdown:
  - 2x fix
  - 1x feature

Commits:
  - fix: token refresh race condition
  - fix: session expiry handling
  - feat: add OAuth2 PKCE support
```

Group insights are classified:

| Classification | Criteria |
|---|---|
| `:migration` | Any commit in group is a migration |
| `:breaking_change` | Any commit is a breaking change |
| `:bug_cluster` | >50% of commits are fixes |
| `:feature_development` | >50% of commits are features |
| `:area_evolution` | Default — mixed activity in an area |

Valence is inferred from the commit types:
- High fix ratio (>50%) → `:negative`
- High breaking/migration ratio (>30%) → `:negative`
- Any feature commits → `:positive`
- Otherwise → `:neutral`

Singletons (topics with only 1 commit) are only emitted if the commit is significant (breaking/migration/revert).

### 2b. Stack Transition Detection (StackDetector)

**Module:** `Recollect.Learner.Git.StackDetector`

StackDetector scans commits for technology transitions and cross-references against a catalog of known migration paths.

#### Detection modes

1. **Commit scanning** (`detect_transitions_from_commits/1`) — inspects commit subjects for patterns like "migrate from X to Y", "replace X with Y", "switch from X to Y". This is the primary mode used during learning.

2. **Config file diff** (`detect_transitions/1`) — compares the current technology stack (from `package.json`, `mix.exs`, config files) against the stack at a point in the past (via `git show SHA:path`).

3. **Snapshot** (`detect_current/0`) — reads config files on disk right now and returns the detected technology map.

#### Technology catalog

StackDetector knows ~30 technologies across 10 categories:

| Category | Technologies |
|---|---|
| `build_tool` | webpack, vite, esbuild, rollup, parcel, turbo |
| `transpiler` | babel, swc |
| `language` | typescript |
| `test_framework` | jest, vitest, mocha, pytest, exunit |
| `css_framework` | tailwind |
| `css_preprocessor` | sass |
| `linter` | eslint, prettier |
| `ui_framework` | react, vue, svelte, angular |
| `web_framework` | phoenix, rails |
| `meta_framework` | next, nuxt |
| `database` | postgres, mysql, sqlite |
| `e2e_framework` | cypress, playwright |

Evidence for each technology comes from:
- `package.json` dependencies and devDependencies
- `package.json` scripts referencing tools
- `mix.exs` dep declarations
- Config file presence (`webpack.config.*`, `vite.config.*`, `tsconfig.json`, etc.)
- Dockerfile/docker-compose.yml

#### Transition catalog

~25 known migration paths across 7 categories. Examples:

```
build_tool:    webpack → vite, webpack → esbuild, rollup → vite
transpiler:    babel → swc, babel → esbuild
test_framework: jest → vitest, mocha → jest
css_framework:  sass → tailwind, less → tailwind
linter:         tslint → eslint, eslint → biome
```

When a transition is detected, the `summarize/2` function returns an extract with `metadata.deprecation: true`. The pipeline's `store_extract/3` picks up this flag and calls `Invalidation.deprecate/4`.

## Deprecation Flow

**Module:** `Recollect.Invalidation.deprecate/4`

When a stack transition is detected (e.g. webpack → vite):

```
┌────────────────────────────────────────────────────────────┐
│  StackDetector detects "webpack → vite" transition         │
│                         │                                  │
│                         ▼                                  │
│  summarize/2 returns extract with metadata.deprecation     │
│                         │                                  │
│                         ▼                                  │
│  Pipeline.store_extract calls Invalidation.deprecate/4     │
│                         │                                  │
│          ┌──────────────┼──────────────┐                   │
│          ▼              ▼              ▼                   │
│   Weaken memories   Create pinned    Create decision      │
│   mentioning        deprecation      replacement entry    │
│   "webpack"         insight entry    "now using vite"     │
│   (×0.1 half-life,  (60-day,         (45-day,            │
│    ×0.1 confidence)  pinned)          supersedes link)    │
└────────────────────────────────────────────────────────────┘
```

Three things happen atomically:

1. **Weaken** — All entries mentioning the old technology have their `half_life_days` and `confidence` multiplied by 0.1 (floored at 0.5 and 0.05 respectively). This makes them decay rapidly without deleting them.

2. **Deprecation entry** — A pinned `development_insight` entry is created with 60-day half-life recording the deprecation event. Content: `"DEPRECATED: webpack has been replaced by vite."`

3. **Replacement entry** — A `decision` entry with 45-day half-life stating the new technology. Has `supersedes` metadata linking back to the old technology.

## Pipeline Orchestration

**Module:** `Recollect.Learning.Pipeline`

```
Pipeline.run(scope_id: id)
  │
  ├─ For each enabled learner (Git, CodingAgent):
  │    │
  │    ├─ fetch_since(since, scope_id) → [events]
  │    │
  │    ├─ For each event: extract(event)
  │    │    ├─ {:ok, extract} → store_extract → Knowledge.remember
  │    │    └─ {:skip, _} → count as skipped
  │    │
  │    └─ summarize(events, scope_id)  [if exported]
  │         └─ For each insight: store_extract
  │              ├─ maybe_trigger_deprecation (if metadata.deprecation)
  │              └─ Knowledge.remember
  │
  └─ Return %{results: %{git: %{fetched, learned, skipped, insights}, ...}}
```

Key detail: `store_extract/3` checks for `metadata[:deprecation]` before storing. If present, it calls `Invalidation.deprecate/4` as a side-effect. This means deprecation happens exactly once — during the actual store, not during dry-run previews.

## Scope and Context

All entries created during learning are scoped to the workspace (`scope_id`). The pipeline now correctly passes `scope_id` through to `Knowledge.remember/2`, ensuring entries are retrievable per-workspace.

Context hints (git repo, file path, OS) are auto-captured by `Knowledge.remember/2` for every entry.

## File Layout

```
lib/mneme/learning/
├── behaviour.ex          # Recollect.Learner behaviour definition
├── pipeline.ex           # Orchestration: fetch → extract → summarize → store
├── git.ex                # Recollect.Learner.Git — fetch, extract, summarize
├── git/
│   ├── grouper.ex        # Commit grouping and insight synthesis
│   └── stack_detector.ex # Technology detection and transition tracking
├── coding_agent.ex       # Recollect.Learner.CodingAgent — dispatcher
└── coding_agent/
    ├── provider.ex       # Provider behaviour
    ├── util.ex           # Shared helpers (frontmatter, JSONL, project tags)
    ├── claude_code.ex    # Claude Code provider
    ├── codex.ex          # OpenAI Codex provider
    ├── gemini.ex         # Gemini CLI provider
    └── opencode.ex       # OpenCode provider

lib/mneme/
├── invalidation.ex       # Deprecation via deprecate/4, weakening, replacement
├── knowledge.ex          # Knowledge.remember/2 — the store function
└── schema/entry.ex       # Entry schema with entry_types including development_insight
```

## Usage

```elixir
# Run all learners (Git, CodingAgent)
{:ok, result} = Recollect.learn(scope_id: workspace_id)

# Run git learner only
{:ok, result} = Recollect.learn(scope_id: workspace_id, sources: [:git])

# Preview without storing
{:ok, preview} = Recollect.learn(scope_id: workspace_id, dry_run: true)

# Trigger deprecation manually
Recollect.Invalidation.deprecate(scope_id, "webpack", "vite",
  category: :build_tool,
  evidence: "manual deprecation"
)

# Detect current stack
stack = Recollect.Learner.Git.StackDetector.detect_current()
# => %{"vite" => %{category: :build_tool, evidence: [...]}, ...}

# Detect transitions from last 30 days
transitions = Recollect.Learner.Git.StackDetector.detect_transitions("30 days ago")
# => [%{type: :deprecation, from: "jest", to: "vitest", ...}]
```
