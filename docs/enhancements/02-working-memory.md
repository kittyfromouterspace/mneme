# Enhancement 02: Working Memory Layer

**Priority:** High | **Effort:** Medium | **Status:** Proposed

## Problem

Mneme has no concept of ephemeral session state. All entries in `mneme_entries` are long-term knowledge. When an agent is mid-task and needs to track "what am I working on right now?", it has nowhere to put that information except the long-term store — where it persists indefinitely and clutters search results.

Hippo solves this with a separate bounded buffer (`working_memory` SQLite table, max 20 entries per scope). In Elixir, this is a textbook GenServer use case — **no database table needed**.

## Solution

Add a working memory tier (Tier 0) — a `DynamicSupervisor` managing one `GenServer` per scope. Each GenServer holds a bounded, importance-sorted list in memory. Eviction is O(n log n) for n ≤ 20.

## Architecture

```
Mneme.WorkingMemory.Supervisor (DynamicSupervisor)
├── WorkingMemory.Server (scope_id: "abc-123")  ← [{0.9, content, ...}, {0.7, ...}, ...]
├── WorkingMemory.Server (scope_id: "def-456")  ← [{0.5, content, ...}]
└── ... (auto-started on first push, auto-killed on flush)
```

- **Push**: start GenServer via `DynamicSupervisor.start_child` if not running, then `GenServer.call` to insert
- **Eviction**: in-memory sort by importance, drop lowest — no DB query
- **Crash recovery**: GenServer restarts with empty state (correct semantics for ephemeral working memory)
- **Optional persistence**: snapshot to DB on flush if host app wants crash recovery

## API

```elixir
defmodule Mneme.WorkingMemory do
  @supervisor Mneme.WorkingMemory.Supervisor

  @doc """
  Push a new entry into working memory for a scope.
  Starts the scope GenServer if not running.
  If the scope exceeds max entries, the lowest-importance entry is evicted.
  """
  def push(scope_id, content, opts \\ []) do
    pid = ensure_scope(scope_id)
    GenServer.call(pid, {:push, content, opts})
  end

  @doc """
  Read working memory entries for a scope, sorted by importance DESC.
  Returns [] if no scope exists.
  """
  def read(scope_id, opts \\ []) do
    case whereis_scope(scope_id) do
      nil -> {:ok, []}
      pid -> GenServer.call(pid, {:read, opts})
    end
  end

  @doc """
  Clear working memory for a scope and terminate the GenServer.
  """
  def clear(scope_id) do
    case whereis_scope(scope_id) do
      nil -> {:ok, 0}
      pid ->
        count = GenServer.call(pid, :clear)
        DynamicSupervisor.terminate_child(@supervisor, pid)
        {:ok, count}
    end
  end

  @doc "Semantic alias for clear, used at session boundaries."
  def flush(scope_id), do: clear(scope_id)

  defp ensure_scope(scope_id) do
    case whereis_scope(scope_id) do
      nil -> start_scope(scope_id)
      pid -> pid
    end
  end

  defp start_scope(scope_id) do
    child_spec = {Mneme.WorkingMemory.Server, scope_id: scope_id}

    case DynamicSupervisor.start_child(@supervisor, child_spec) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp whereis_scope(scope_id) do
    Registry.lookup(Mneme.WorkingMemory.Registry, scope_id)
    |> case do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end
```

## GenServer Implementation

```elixir
defmodule Mneme.WorkingMemory.Server do
  @moduledoc """
  GenServer holding a bounded working memory buffer for a single scope.

  State: %{scope_id: binary(), entries: [%{id, importance, content, metadata, inserted_at}], max: pos_integer()}
  """
  use GenServer

  @default_max 20

  def start_link(opts) do
    scope_id = Keyword.fetch!(opts, :scope_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(scope_id))
  end

  @impl true
  def init(opts) do
    max = Keyword.get(opts, :max_entries, @default_max)
    {:ok, %{scope_id: opts[:scope_id], entries: [], max: max}}
  end

  @impl true
  def handle_call({:push, content, opts}, _from, state) do
    entry = %{
      id: generate_id(),
      importance: Keyword.get(opts, :importance, 0.0),
      content: content,
      metadata: Keyword.get(opts, :metadata, %{}),
      inserted_at: DateTime.utc_now()
    }

    entries = [entry | state.entries]

    # Evict if over capacity: sort by importance ASC, then inserted_at ASC, drop lowest
    entries =
      if length(entries) > state.max do
        entries
        |> Enum.sort_by(fn e -> {e.importance, e.inserted_at} end)
        |> Enum.drop(1)  # drop the lowest-importance oldest entry
      else
        entries
      end

    {:reply, {:ok, entry}, %{state | entries: entries}}
  end

  def handle_call({:read, _opts}, _from, state) do
    sorted = Enum.sort_by(state.entries, fn e -> {-e.importance, e.inserted_at} end)
    {:reply, {:ok, sorted}, state}
  end

  def handle_call(:clear, _from, state) do
    count = length(state.entries)
    {:reply, count, %{state | entries: []}}
  end

  defp via_tuple(scope_id) do
    {:via, Registry, {Mneme.WorkingMemory.Registry, scope_id}}
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end
```

## Process Discovery

Use a `Registry` for scope_id → pid mapping:

```elixir
# In Mneme.Application:
children = [
  {Task.Supervisor, name: Mneme.TaskSupervisor},
  {Registry, keys: :unique, name: Mneme.WorkingMemory.Registry},
  {DynamicSupervisor, strategy: :one_for_one, name: Mneme.WorkingMemory.Supervisor},
  Mneme.RetrievalCounter
]
```

## Context Integration

Working memory entries are included **before** long-term memories in context output:

```elixir
def build_context_with_working_memory(search_results, scope_id) do
  working = case Mneme.WorkingMemory.read(scope_id) do
    {:ok, entries} -> entries
    _ -> []
  end

  [
    format_working_memory(working),
    Mneme.build_context(search_results)
  ]
  |> Enum.filter(&(&1 != ""))
  |> Enum.join("\n\n")
end
```

## Configuration

```elixir
config :mneme,
  working_memory: [
    enabled: true,
    max_entries_per_scope: 20
  ]
```

## Why Not a Database Table?

| Aspect | DB Table | GenServer |
|--------|----------|-----------|
| Write latency | ~5ms (round trip) | <1μs (in-memory) |
| Eviction query | `DELETE ... ORDER BY ... LIMIT` | `Enum.sort_by` on ≤20 items |
| Session isolation | WHERE clause filter | Separate process per scope |
| Crash semantics | Data persists (wrong for ephemeral) | Empty state (correct) |
| Concurrency | Row locks | Message queue (serialized per scope) |
| Complexity | Migration + schema + queries | ~80 lines of GenServer |

If crash recovery is desired (e.g., host app wants working memory to survive application restarts), add an optional `:persistent` config that snapshots to a single `mneme_working_memory_snapshots` table on flush. This is opt-in and adds minimal complexity.

## Testing

- Unit test: eviction removes lowest-importance entry
- Unit test: ties broken by oldest inserted_at
- GenServer test: push → read → clear lifecycle
- GenServer test: scope isolation (different scope_ids don't interfere)
- Property test: scope never exceeds max_entries after push
- Concurrent test: multiple pushes to same scope are serialized correctly
- Registry test: scope process is discoverable by scope_id
