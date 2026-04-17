# Enhancement 09: Context-Aware Retrieval

**Priority:** High | **Effort:** Medium | **Status:** Proposed

## Problem

Recollect currently treats all entries within a scope equally, regardless of the agent's current environment. In human memory, context cues trigger relevant memories — being in a kitchen recalls cooking knowledge, being in a git repo recalls that project's conventions.

Currently:
- All entries in a scope are treated as equally relevant
- No awareness of git repo, branch, working directory, or physical location
- Context is implicit in scope but not used for relevance ranking

## Solution

Add **context hints** to entries and **context detection** at retrieval time. Entries carry environment signals they were created in (or inferred from), and search boosts entries that match the current environment.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Context Signal (transient, derived from environment)        │
│                                                             │
│   Recollect.Context.Detector                                    │
│   ├── current_git_repo() → %{repo: "owner/repo", branch: "main"} │
│   ├── current_path() → "/home/user/project/src"            │
│   └── current_location() → %{lat: 37.7, lon: -122.4}        │
├─────────────────────────────────────────────────────────────┤
│ Entry (persistent)                                          │
│                                                             │
│   context_hints: map (e.g., %{repo: "owner/repo", os: "linux"})   │
├─────────────────────────────────────────────────────────────┤
│ Retrieval (enhanced)                                        │
│                                                             │
│   Score = vector_similarity + context_boost                 │
│   where context_boost = f(entry.context_hints, current_context) │
└─────────────────────────────────────────────────────────────┘
```

## Schema Changes

Add to `recollect_entries`:

```elixir
add :context_hints, :map, default: %{}, null: false
```

The map stores key-value pairs like:
- `repo` — Git repository (e.g., "owner/repo")
- `branch` — Current git branch
- `path_prefix` — File path prefix (e.g., "lib/mneme")
- `os` — Operating system
- `language` — Programming language
- `location` — Lat/long for physical location

## Context Detection

```elixir
defmodule Recollect.Context.Detector do
  @moduldoc """
  Detect current environment context from the running system.
  
  Supports: Git repository, working directory, OS, custom context.
  """

  @doc "Detect all available context signals."
  def detect do
    []
    |> maybe_git_context()
    |> maybe_path_context()
    |> maybe_os_context()
    |> Enum.into(%{})
  end

  @doc "Detect only git context (safe to call even outside a repo)."
  def detect_git do
    []
    |> maybe_git_context()
    |> Enum.into(%{})
  end

  defp maybe_git_context(acc) do
    case git_repo() do
      nil -> acc
      repo -> [{:repo, repo} | acc]
    end
  end

  defp maybe_path_context(acc) do
    case System.get_env("PWD") || System.get_env("OLDPWD") do
      nil -> acc
      path -> [{:path_prefix, path} | acc]
    end
  end

  defp maybe_os_context(acc) do
    [{:os, :os.type() |> elem(0) |> Atom.to_string()} | acc]
  end

  defp git_repo do
    # Try git rev-parse --show-toplevel
    case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {path, 0} ->
        path = String.trim(path)
        
        # Extract owner/repo from remote if available
        case System.cmd("git", ["remote", "get-url", "origin"], cd: path, stderr_to_stdout: true) do
          {remote, 0} ->
            parse_git_remote(remote)
          _ ->
            # Fallback: use directory name as identifier
            Path.basename(path)
        end
      
      _ ->
        nil
    end
  end

  defp parse_git_remote(remote) do
    remote
    |> String.trim()
    |> String.replace_suffix(".git", "")
    |> String.replace_prefix("git@github.com:", "")
    |> String.replace_prefix("https://github.com/", "")
  end
end
```

## Context Hints on Entry Creation

When creating an entry, capture the current context automatically:

```elixir
defmodule Recollect.Knowledge do
  def remember(content, opts \\ []) do
    # Auto-capture context if not provided
    context_hints = 
      if opts[:context_hints] do
        opts[:context_hints]
      else
        Recollect.Context.Detector.detect()
      end
    
    # ... existing entry creation with context_hints added
  end
end
```

## Context Boost in Retrieval

Add a boost factor to search results based on context match:

```elixir
defmodule Recollect.Search.ContextBooster do
  @boost_threshold 0.3  # Only boost if hints match
  @default_boost 0.15   # 15% boost for matching context

  @doc """
  Calculate context boost for an entry given current context.
  
  Returns a float 0.0-0.5 representing the boost to add to the score.
  """
  def boost(entry_context_hints, current_context) do
    if map_size(entry_context_hints) == 0 or map_size(current_context) == 0 do
      0.0
    else
      matches = context_matches(entry_context_hints, current_context)
      
      if matches == 0 do
        0.0
      else
        # More matches = higher boost, capped at 0.5
        min(@default_boost * matches, 0.5)
      end
    end
  end

  defp context_matches(entry_hints, current) do
    Enum.reduce(entry_hints, 0, fn {key, value}, acc ->
      if Map.get(current, key) == value do
        acc + 1
      else
        acc
      end
    end)
  end
end
```

## Integration with Search

```elixir
# In Recollect.Search.Vector, after getting vector results:
defp boost_with_context(results, scope_id) do
  current_context = Recollect.Context.Detector.detect()
  
  if map_size(current_context) == 0 do
    results
  else
    Enum.map(results, fn entry ->
      entry_context_hints = entry["context_hints"] || %{}
      
      boost = ContextBooster.boost(entry_context_hints, current_context)
      
      # Add context_boost to the score (if vector score exists)
      original_score = entry["score"] || entry["similarity"] || 0.0
      Map.put(entry, "score", original_score + boost)
    end)
    |> Enum.sort_by(& &1["score"], :desc)
  end
end
```

## API

### Creating entries with context hints

```elixir
# Auto-detect current context (default)
{:ok, entry} = Recollect.remember("Use refterm for terminal performance")

# Explicit context hints
{:ok, entry} = Recollect.remember("Use refterm for terminal performance",
  context_hints: %{repo: "wez/wezterm", os: "linux"}
)

# Override auto-detection (e.g., creating entry for a different context)
{:ok, entry} = Recollect.remember("On macOS use Terminal.app",
  context_hints: %{os: "darwin"}
)
```

### Searching with context

```elixir
# Uses auto-detected context (current git repo, path, OS)
{:ok, results} = Recollect.search("terminal performance")

# Explicit context override
{:ok, results} = Recollect.search("terminal performance",
  context: %{repo: "wez/wezterm"}
)

# Disable context boost
{:ok, results} = Recollect.search("terminal performance",
  context_boost: false
)
```

### Migrating context on migration

When migrating code, update context hints:

```elixir
# After migrating from webpack to vite
Recollect.invalidate("webpack",
  reason: "migrated to vite",
  new_context: %{repo: "my-org/my-app"}
)
# This would weaken old webpack entries AND create new vite entry
# with updated context hints
```

## Migration

```elixir
defmodule Recollect.Repo.Migrations.AddContextHints do
  use Ecto.Migration

  def change do
    alter table(:recollect_entries) do
      add :context_hints, :map, default: %{}, null: false
    end

    create index(:recollect_entries, [:context_hints])
  end
end
```

## Configuration

```elixir
config :recollect,
  context_aware: [
    enabled: true,
    auto_detect: true,
    boost: [
      threshold: 0.3,
      default_boost: 0.15,
      max_boost: 0.5
    ],
    signals: [
      git: true,
      path: true,
      os: true
    ]
  ]
```

## Backward Compatibility

- `context_hints` defaults to `%{}` for all existing entries
- Auto-detection is opt-in (disabled if detector returns empty)
- No breaking changes to existing search API
- Context boost adds to score, never reduces it

## Testing

- Unit test: detector returns git repo when in a git directory
- Unit test: detector returns nil when not in a git directory
- Unit test: context_boost returns 0 when entry has no hints
- Unit test: context_boost increases with more matching hints
- Integration test: search results with matching context rank higher
- Integration test: context hints are captured on entry creation

## References

- Hippo: context-triggered recall based on project paths
- n0tls: "location triggers much more intrinsics than conscious memory" — HN discussion