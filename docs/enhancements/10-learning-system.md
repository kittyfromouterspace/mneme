# Enhancement 10: Learning System

**Priority:** High | **Effort:** Medium | **Status:** Proposed

> Inspired by [Cognee's cognify pipeline](https://docs.cognee.ai/core-concepts/main-operations/cognify) and the hippo-memory learning concepts.

## Problem

Recollect currently relies on explicit calls to `Recollect.remember/2` for all knowledge ingestion. There's no system for automatically extracting knowledge from external sources like:
- Git history (commits, branches, PRs)
- Code review feedback
- CI/CD failures
- Documentation changes
- Terminal command history

Human memory is constantly learning from observation and interaction, not just explicit memorization. Hippo's `hippo learn` command demonstrates this for git, but the concept should be broader.

## Solution

A pluggable **Learning System** that observes external sources and creates memory entries automatically. Git is one input source; terminal history, CI failures, and others are others.

> **Cognee inspiration**: Cognee's `.cognify` operation transforms ingested data into chunks, embeddings, summaries, nodes, and edges. The same pipeline concept applies to learning — but instead of files, we ingest events from external systems.

```
┌─────────────────────────────────────────────────────────────┐
│                    Recollect.Learning                          │
│                                                             │
│   ┌─────────────────────────────────────────────────────┐   │
│   │ Learners (pluggable) — "ingest" stage               │   │
│   │                                                      │   │
│   │ ├── Recollect.Learner.Git                               │   │
│   │ ├── Recollect.Learner.Terminal                          │   │
│   │ ├── Recollect.Learner.CI                                │   │
│   │ └── Recollect.Learner.Documentation                     │   │
│   └─────────────────────────────────────────────────────┘   │
│                          │                                  │
│                          ▼                                  │
│   ┌─────────────────────────────────────────────────────┐   │
│   │ Extraction + Synthesis — "cognify" stage            │   │
│   │                                                      │   │
│   │ - Source parsing                                    │   │
│   │ - Pattern detection (fix, bug, revert, etc.)      │   │
│   │ - Content synthesis → memory entries               │   │
│   └─────────────────────────────────────────────────────┘   │
│                          │                                  │
│                          ▼                                  │
│   ┌─────────────────────────────────────────────────────┐   │
│   │ Enrichment — "memify" stage (optional)             │   │
│   │                                                      │   │
│   │ - Entity consolidation                              │   │
│   │ - Relationship building                             │   │
│   │ - Graph enrichment                                  │   │
│   └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## Core Concept: Learner Behaviour

Each learner implements the `Recollect.Learner` behaviour:

```elixir
defmodule Recollect.Learner do
  @moduledoc """
  Behaviour for learning modules that extract knowledge from external sources.
  
  Mirrors Cognee's Task concept — each learner is a small, composable unit
  that can be run independently or as part of a pipeline.
  """

  @doc "Return the source name (e.g., :git, :terminal, :ci)"
  @callback source() :: atom()

  @doc "Fetch new events/items to learn from since the last check."
  @callback fetch_since(since, scope_id :: binary()) :: {:ok, [event()]} | {:error, term()}

  @doc "Extract learnable content from an event."
  @callback extract(event :: event()) :: {:ok, extract()} | {:skip, reason :: binary()} | {:error, term()}

  @doc "Optional: Detect patterns across multiple events."
  @callback detect_pattern([event()]) :: [pattern()] | []

  @type event :: map()
  @type extract :: %{
    content: binary(),
    entry_type: atom(),
    emotional_valence: atom(),
    tags: [binary()],
    metadata: map()
  }
  @type pattern :: %{
    type: atom(),
    events: [event()],
    summary: binary()
  }
end
```

## Git Learner (Initial Implementation)

```elixir
defmodule Recollect.Learner.Git do
  @moduledoc """
  Learn from git history — commits, branches, tags.
  
  Detects:
  - Bug fixes ("fix", "bug", "patch")
  - Features ("feat", "feature", "add")
  - Reverts ("revert", "undo")
  - Breaking changes ("BREAKING", "migrate")
  - Documentation changes ("docs", "readme")
  """

  @behaviour Recollect.Learner

  @impl true
  def source, do: :git

  @impl true
  def fetch_since(since, scope_id) do
    # Get commits since the given date
    case System.cmd("git", ["log", "--since=#{since}", "--pretty=format:%H|%s|%b|%an", "--all"], stderr_to_stdout: true) do
      {output, 0} ->
        commits = output
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_commit/1)
        |> Enum.reject(&is_nil/1)
        
        {:ok, commits}
      
      _ ->
        {:error, :not_a_git_repo}
    end
  end

  @impl true
  def extract(commit) do
    message = commit.subject
    body = commit.body || ""
    full_message = if body != "", do: "#{message}\n\n#{body}", else: message

    type = detect_type(message)
    valence = detect_valence(type, message)
    tags = build_tags(type, commit)

    {:ok, %{
      content: "[#{type}] #{full_message}",
      entry_type: type_to_entry_type(type),
      emotional_valence: valence,
      tags: tags,
      metadata: %{
        commit_sha: commit.sha,
        author: commit.author,
        branch: commit.branch,
        source: :git
      }
    }}
  end

  @impl true
  def detect_pattern(events) do
    # Detect "migrate from X to Y" patterns across commits
    events
    |> Enum.filter(fn e -> String.contains?(e.subject, ["migrate", "migrated"]) end)
    |> Enum.chunk_by(fn e -> extract_migration_target(e.subject) end)
    |> Enum.filter(fn chunk -> length(chunk) >= 2 end)
    |> Enum.map(fn chunk ->
      [from, to] = extract_migration_pair(List.first(chunk).subject)
      
      %{
        type: :migration,
        summary: "Migration from #{from} to #{to}",
        events: chunk
      }
    end)
  end

  # ... helper functions
end
```

## Terminal Learner

```elixir
defmodule Recollect.Learner.Terminal do
  @moduledoc """
  Learn from command history — successful commands, failed commands.
  
  Detects:
  - Failed commands (opportunity to remember correct form)
  - Successful complex commands (best practices)
  - Directory-specific patterns
  """

  @behaviour Recollect.Learner

  @impl true
  def source, do: :terminal

  @impl true
  def fetch_since(since, _scope_id) do
    # Read from shell history (depends on shell: ~/.bash_history, ~/.zsh_history, etc.)
    # This is a simplified version
    history_file = System.get_env("HISTFILE") || "~/.bash_history"
    
    case File.read(Path.expand(history_file)) do
      {:ok, content} ->
        commands = content
        |> String.split("\n", trim: true)
        |> Enum.reject(&String.starts_with?(&1, "#"))
        |> Enum.take(-1000)  # Last 1000 commands
        
        {:ok, Enum.map(commands, &%{command: &1})}
      
      _ ->
        {:ok, []}
    end
  end

  @impl true
  def extract(event) do
    cmd = event.command
    
    # Skip common noise
    if skip_command?(cmd) do
      {:skip, "common command"}
    else
      # Detect if this was likely successful or failed
      valence = if contains_error_indicator?(cmd), do: :negative, else: :positive
      
      {:ok, %{
        content: "Command: #{cmd}",
        entry_type: :observation,
        emotional_valence: valence,
        tags: detect_command_tags(cmd),
        metadata: %{
          source: :terminal,
          working_directory: System.get_env("PWD")
        }
      }}
    end
  end

  defp skip_command?("ls " <> _), do: true
  defp skip_command?("cd " <> _), do: true
  defp skip_command?("git status"), do: true
  defp skip_command?("git log"), do: true
  defp skip_command?(_), do: false

  # ... more helpers
end
```

## Learning API

```elixir
defmodule Recollect.Learning do
  @moduledoc """
  Orchestrate learning from multiple sources.
  """

  @doc """
  Run learning from all enabled sources.
  
  ## Options
  - `:sources` — List of sources to learn from (default: all enabled)
  - `:since` — Learn from events since this time (default: last learning run)
  - `:dry_run` — If true, don't create entries
  
  ## Returns
  ```
  {:ok, %{
    git: %{events: 12, learned: 8, skipped: 4},
    terminal: %{events: 50, learned: 5, skipped: 45}
  }}
  ```
  """
  def run(opts \\ [])

  @doc "Register a new learner module."
  def register_learner(module)

  @doc "Get learning history."
  def history(scope_id, opts \\ [])
end
```

## Pipeline Stages (Cognee-Inspired)

The learning system follows Cognee's pipeline architecture:

```
┌─────────────────────────────────────────────────────────────────────┐
│  Recollect.Learning.run()                                              │
│                                                                     │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────┐           │
│  │   Ingest     │ → │   Cognify     │ → │   Memify     │           │
│  │ (Learners)   │   │ (Extract)     │   │ (Enrich)     │           │
│  └──────────────┘   └──────────────┘   └──────────────┘           │
│       fetch_*()         extract()        enrich_*()                │
└─────────────────────────────────────────────────────────────────────┘
```

### Stage 1: Ingest (Learners)

Each learner fetches events from its source:
- `Learner.Git.fetch_since/2` → commits, branches, PRs
- `Learner.Terminal.fetch_since/2` → command history
- `Learner.CI.fetch_since/2` → build failures

### Stage 2: Cognify (Extract + Transform)

Events are extracted into memory entries:

```elixir
# This is what happens inside Recollect.Learning.run/1
for learner <- enabled_learners do
  {:ok, events} = learner.fetch_since(since, scope_id)
  
  for event <- events do
    case learner.extract(event) do
      {:ok, extract} ->
        # Transform: event → memory entry
        Recollect.remember(extract.content,
          entry_type: extract.entry_type,
          emotional_valence: extract.emotional_valence,
          tags: extract.tags,
          metadata: Map.put(extract.metadata, :source, learner.source())
        )
      
      {:skip, _reason} ->
        :skip
      
      {:error, _reason} ->
        :error
    end
  end
end
```

### Stage 3: Memify (Enrich - Optional)

After learning, run enrichment on created entries:

```elixir
# Post-learning enrichment
defp memify_stage(entries, scope_id) do
  # Entity consolidation (merge duplicate entities)
  Recollect.Learning.EntityConsolidation.run(entries)
  
  # Graph enrichment (build relationships between new entries)
  Recollect.Learning.GraphEnrichment.run(entries)
  
  # Schema acceleration (update tag frequency index)
  Recollect.SchemaIndex.rebuild()
end
```

This mirrors Cognee's approach:
- **Ingest** = Cognee's `add` (bring data in)
- **Cognify** = Transform into searchable knowledge
- **Memify** = Enrich existing knowledge with derived facts

## Usage

```elixir
# Run all enabled learners
{:ok, result} = Recollect.Learning.run(scope_id: workspace_id)
# => %{git: %{learned: 5}, terminal: %{learned: 3}}

# Run specific source only
{:ok, result} = Recollect.Learning.run(scope_id: workspace_id, sources: [:git])

# Preview what would be learned (dry run)
{:ok, preview} = Recollect.Learning.run(scope_id: workspace_id, dry_run: true)
```

## Configuration

```elixir
config :recollect,
  learning: [
    enabled: true,
    sources: [:git, :terminal],
    
    # Git learner config
    git: [
      since_days: 7,
      skip_merge_commits: true,
      entry_types: %{
        fix: :observation,
        feat: :note,
        docs: :note,
        revert: :hypothesis,
        BREAKING: :decision
      }
    ],
    
    # Terminal learner config
    terminal: [
      skip_common: true,
      max_per_run: 10
    ]
  ]
```

## Integration with Consolidation

Learning runs as part of the consolidation cycle:

```elixir
defmodule Recollect.Consolidation do
  defp run_passes(scope_id, opts) do
    # ... existing passes ...
    
    # New: Learning pass
    if Keyword.get(opts, :run_learning, true) do
      Recollect.Learning.run(scope_id: scope_id)
    end
  end
end
```

## Telemetry

```elixir
Recollect.Telemetry.event([:recollect, :learning, :source, :stop], %{
  source: :git,
  events_fetched: 15,
  events_learned: 8,
  events_skipped: 7,
  duration_ms: 234
})
```

## Migration

```elixir
defmodule Recollect.Repo.Migrations.AddSourceTracking do
  use Ecto.Migration

  def change do
    alter table(:recollect_entries) do
      add :source, :string
      add :source_metadata, :map
    end

    create index(:recollect_entries, [:source])
  end
end
```

## Backward Compatibility

- Learning is opt-in via config
- `source` and `source_metadata` default to nil (legacy entries have no source)
- Dry-run mode available to preview without persisting

## Testing

- Unit test: git learner parses commit message correctly
- Unit test: git learner detects fix vs feat vs revert
- Unit test: terminal learner skips common commands
- Unit test: learner registry registers and discovers learners
- Integration test: learning.run creates entries in database
- Integration test: learning.run respects since parameter

## Extending: Adding New Learners

To add a new source (e.g., CI failures):

```elixir
defmodule Recollect.Learner.CI do
  @behaviour Recollect.Learner

  @impl true
  def source, do: :ci

  @impl true
  def fetch_since(since, scope_id) do
    # Fetch from GitHub Actions, CircleCI, etc.
  end

  @impl true
  def extract(event) do
    {:ok, %{
      content: "[CI Failure] #{event.failure_message}",
      entry_type: :observation,
      emotional_valence: :negative,
      tags: ["ci", "failure", event.workflow],
      metadata: %{source: :ci, job_id: event.id}
    }}
  end
end
```

Then add to config:
```elixir
config :recollect,
  learning: [sources: [:git, :terminal, :ci]]
```

## References

- Hippo: `hippo learn --git` — initial inspiration
- Cognee: [Cognify](https://docs.cognee.ai/core-concepts/main-operations/cognify) — pipeline architecture for data → knowledge transformation
- Cognee: [Memify](https://docs.cognee.ai/core-concepts/main-operations/memify) — enrichment of existing knowledge graphs
- n0tls: "observation leads to learning" — HN discussion
- Complementary Learning Systems: experience replay during learning