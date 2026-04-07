# Enhancement 12: Session Handoffs

**Priority:** Medium | **Effort:** Low | **Status:** Proposed

## Problem

Mneme has a `session_summary` entry type, but there's no structured way to express "what to do next" when switching contexts. When an agent pauses work on project A and switches to project B (or ends the day), there's no explicit handoff mechanism.

This leads to:
- Lost context when resuming work
- Need to re-read previous session summaries
- No explicit "next steps" for the next session to pick up

## Solution

Add explicit session handoff — a structured way to transfer state between sessions with "what I was doing", "what's next", and "artifacts to continue with".

```
┌─────────────────────────────────────────────────────────────┐
│                 Session Handoff                            │
│                                                             │
│   {                                                         │
│     "what": "Implementing user auth",                      │
│     "next": [                                               │
│       "Add login controller",                                │
│       "Create session middleware"                           │
│     ],                                                      │
│     "artifacts": [                                          │
│       "lib/auth/user.ex",                                   │
│       "lib/auth/token.ex"                                   │
│     ],                                                      │
│     "blockers": ["Waiting on API spec"]                     │
│   }                                                         │
└─────────────────────────────────────────────────────────────┘
```

## Schema

```elixir
add :handoff, :map, default: nil
# Stored as JSONB, contains:
# - what: binary (current task)
# - next: [binary] (next steps)
# - artifacts: [binary] (files/links to continue with)
# - blockers: [binary] (what's blocking progress)
# - session_id: binary
```

## API

```elixir
defmodule Mneme.Handoff do
  @moduledoc """
  Create and retrieve session handoffs for continuing work across sessions.
  """

  @doc """
  Create a handoff at session end.
  
  ## Options
  - `:what` — What you were working on
  - `:next` — List of next steps
  - `:artifacts` — Files/links to continue with
  - `:blockers` — What's blocking progress
  """
  def create(scope_id, opts \\ [])

  @doc """
  Get the most recent handoff for a scope.
  """
  def get(scope_id)

  @doc """
  Get handoffs since a date.
  """
  def recent(scope_id, since \\ ~D[2024-01-01])
end
```

## Usage

```elixir
# At end of session
Mneme.Handoff.create(workspace_id,
  what: "Implementing user authentication",
  next: [
    "Add login controller",
    "Create session middleware",
    "Write auth tests"
  ],
  artifacts: [
    "lib/auth/user.ex",
    "lib/auth/token.ex"
  ],
  blockers: [
    "Waiting on API spec from backend team"
  ]
)

# At start of next session
{:ok, handoff} = Mneme.Handoff.get(workspace_id)

if handoff do
  IO.puts("Continuing: #{handoff.what}")
  IO.puts("Next: #{Enum.join(handoff.next, ", ")}")
end
```

## Integration with Working Memory

Handoffs feed directly into working memory on session start:

```elixir
# On session start (new scope or fresh scope)
def on_session_start(scope_id) do
  # Load previous handoff into working memory
  case Mneme.Handoff.get(scope_id) do
    {:ok, handoff} when not is_nil(handoff) ->
      # Push handoff items to working memory
      Mneme.WorkingMemory.push(scope_id, "📋 Previous context: #{handoff.what}")
      
      for next_step <- handoff.next do
        Mneme.WorkingMemory.push(scope_id, "→ #{next_step}", importance: 0.8)
      end
      
      for artifact <- handoff.artifacts do
        Mneme.WorkingMemory.push(scope_id, "📎 #{artifact}", importance: 0.7)
      end
    
    _ ->
      :ok
  end
end
```

## Context Formatting

Include handoff in context when it exists:

```elixir
def format_handoff(handoff) do
  """
  ## Previous Session Context
  
  **What I was doing:** #{handoff.what}
  
  **Next steps:**
  #{Enum.map_join(handoff.next, "\n", fn step -> "- #{step}" end)}
  
  #{if handoff.artifacts do}
  **Artifacts to continue with:**
  #{Enum.map_join(handoff.artifacts, "\n", fn a -> "- #{a}" end)}
  #{end}
  
  #{if handoff.blockers do}
  **Blockers:**
  #{Enum.map_join(handoff.blockers, "\n", fn b -> "- #{b}" end)}
  #{end}
  """
end
```

## Migration

```elixir
defmodule Mneme.Repo.Migrations.AddHandoff do
  use Ecto.Migration

  def change do
    alter table(:mneme_entries) do
      add :handoff, :map
    end

    create index(:mneme_entries, [:entry_type])  # For faster session_summary queries
  end
end
```

## Configuration

```elixir
config :mneme,
  handoff: [
    enabled: true,
    auto_load: true,  # Load handoff into working memory on session start
    max_next_steps: 5
  ]
```

## References

- n0tls: "session handoffs" — HN discussion
- Hippo: implicit continuation via session summaries