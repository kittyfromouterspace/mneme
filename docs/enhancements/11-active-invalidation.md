# Enhancement 11: Active Invalidation

**Priority:** High | **Effort:** Medium | **Status:** Proposed

## Problem

Mneme currently only handles memory decay through passive mechanisms — entries age out based on access patterns. But there's a more active scenario: when a **breaking change** happens (e.g., migrating from webpack to vite), the old knowledge becomes actively wrong, not just stale.

Hippo handles this with `hippo learn --git` which detects migrations and weakens related memories. Without this, users have:
- Memories about "use webpack" that persist long after migrating to vite
- Conflicting memories that confuse the agent
- No way to mark "this is no longer true"

## Solution

Active invalidation — detect breaking changes and proactively weaken or replace related memories.

```
┌─────────────────────────────────────────────────────────────┐
│                 Active Invalidation                        │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ Detectors                                           │    │
│  │                                                      │    │
│  │ - Git commit patterns (migrate, refactor, remove)  │    │
│  │ - Config file changes (.eslintrc → eslint.config)  │    │
│  │ - Package.json deps (remove, replace)               │    │
│  │ - Manual invalidation via API                      │    │
│  └─────────────────────────────────────────────────────┘    │
│                          │                                  │
│                          ▼                                  │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ Actions                                             │    │
│  │                                                      │    │
│  │ - Weaken: reduce half-life, mark as "superseded"    │    │
│  │ - Replace: create new entry with "supersedes" link  │    │
│  │ - Archive: move to archived with reason            │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

## Git-Based Detection

```elixir
defmodule Mneme.Invalidation.GitDetector do
  @moduledoc """
  Detect breaking changes from git history.
  
  Patterns that trigger invalidation:
  - "migrate from X to Y"
  - "refactor: remove X, use Y"
  - "replace X with Y"
  - "drop support for X"
  - "BREAKING CHANGE:"
  """

  @migration_patterns [
    ~r/migrate(?:d)?\s+(?:from\s+)?(\w+)\s+(?:to|with)\s+(\w+)/i,
    ~r/(?:refactor|rewrite):\s+(\w+)\s+(?:to|->)\s+(\w+)/i,
    ~r/replace[dr]?\s+(\w+)\s+(?:with|by)\s+(\w+)/i,
    ~r/drop(?:ped)?\s+(?:support\s+for\s+)?(\w+)/i,
    ~r/remove[dr]?\s+(\w+)\s+(?:and|use)\s+(\w+)/i,
    ~r/BREAKING(?:\s+CHANGE)?:/i
  ]

  @doc "Detect migration events from recent commits."
  def detect_migrations(scope_id, options \\ []) do
    days = Keyword.get(options, :days, 7)
    
    case System.cmd("git", ["log", "--since=#{days} days", "--pretty=format:%s", "-p"], stderr_to_stdout: true) do
      {output, 0} ->
        commits = String.split(output, "\n---")
        Enum.flat_map(commits, &parse_migration/1)
      
      _ ->
        []
    end
  end

  defp parse_migration(commit_text) do
    # Check subject and diff for migration patterns
    subject = commit_text |> String.split("\n") |> List.first() || ""
    
    Enum.reduce(@migration_patterns, [], fn pattern, acc ->
      case Regex.run(pattern, subject) do
        [_, from, to] ->
          [%{type: :migration, from: from, to: to, subject: subject} | acc]
        _ ->
          acc
      end
    end)
  end

  @doc "Detect file-based migrations (config files changing)."
  def detect_file_migrations(scope_id, options \\ []) do
    days = Keyword.get(options, :days, 7)
    
    # Look for config file renames/changes
    case System.cmd("git", ["log", "--since=#{days} days", "--name-status", "--diff-filter=R"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_rename/1)
        |> Enum.reject(&is_nil/1)
      
      _ ->
        []
    end
  end

  defp parse_rename(line) do
    # R100\toldpath\tnewpath format
    case String.split(line, "\t") do
      ["R", old_path, new_path] ->
        %{
          type: :file_rename,
          from: old_path,
          to: new_path,
          category: categorize_file_change(old_path, new_path)
        }
      _ ->
        nil
    end
  end

  defp categorize_file_change(old, new) do
    cond do
      String.match?(old, ~r/\.config\.(js|ts|json)$/) and 
        String.match?(new, ~r/eslint\.(config|js|ts)/) -> :linter_change
      
      String.match?(old, ~r/webpack/) -> :build_change
      String.match?(old, ~r/vite|rollup|esbuild/) -> :build_change
      
      String.match?(old, ~r/tsconfig/) -> :tsconfig_change
      
      true -> :other
    end
  end
end
```

## Invalidation API

```elixir
defmodule Mneme.Invalidation do
  @moduledoc """
  Active memory invalidation based on detected or explicit breaking changes.
  """

  @doc """
  Invalidate memories matching a pattern (e.g., "webpack").
  
  ## Options
  - `:reason` — Why this is being invalidated
  - `:replacement` — What replaces it (creates supersedes link)
  - `:weaken` — If true, reduce half-life instead of archiving (default: true)
  """
  def invalidate(scope_id, pattern, opts \\ [])

  @doc """
  Invalidate based on detected migration.
  """
  def invalidate_migration(scope_id, migration, opts \\ [])

  @doc """
  List pending invalidations for review.
  """
  def pending_invalidations(scope_id)
end
```

## Usage

```elixir
# Auto-detect and invalidate from recent git history
{:ok, result} = Mneme.Invalidation.run_from_git(scope_id: workspace_id)
# => %{invalidations: 5, migrations_detected: 2}

# Manual invalidation
Mneme.Invalidation.invalidate("webpack", 
  reason: "migrated to vite",
  scope_id: workspace_id
)

# Invalidate with replacement
Mneme.Invalidation.invalidate("create-react-app",
  replacement: "vite",
  reason: "migration to vite",
  scope_id: workspace_id
)
```

## Integration with Learning

The learning system (Enhancement 10) can trigger invalidation:

```elixir
# In Mneme.Learning.run/1, after processing commits:
defp maybe_invalidate(entries, scope_id) do
  # Check for migration patterns in newly learned entries
  migrations = Enum.filter(entries, fn e ->
    String.contains?(e.content, ["migrate", "refactor", "replace"])
  end)
  
  for migration <- migrations do
    Mneme.Invalidation.invalidate_migration(scope_id, migration)
  end
end
```

## Schema Changes

```elixir
# Track invalidation history
create table(:mneme_invalidations, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :scope_id, :binary_id, null: false
  add :entry_id, :binary_id, null: false
  add :reason, :string, null: false
  add :replacement_entry_id, :binary_id
  add :type, :string, null: false  # :weaken, :archive, :supersede
  add :detected_at, :utc_datetime_usec
end
```

## Configuration

```elixir
config :mneme,
  invalidation: [
    enabled: true,
    auto_detect: true,
    sources: [:git],
    weaken_factor: 0.1,  # Multiply half-life by this
    max_invalidations_per_run: 50
  ]
```

## References

- Hippo: `hippo learn --git` — detect migrations and weaken related memories
- n0tls: "active invalidation" — HN discussion