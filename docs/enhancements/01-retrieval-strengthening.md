# Enhancement 01: Retrieval Strengthening

**Priority:** High | **Effort:** Low | **Status:** Proposed

## Problem

Recollect currently tracks access count and last accessed time, but retrieving a memory has no effect on its longevity. In human memory (and in Hippo), recalled memories undergo "reconsolidation" — the act of retrieval destabilizes the trace, then re-encodes it stronger. This is the testing effect.

## Solution

Add retrieval strengthening mechanics to entries:

1. **Half-life extension** — each retrieval extends the half-life by a configurable amount (default: +2 days)
2. **Retrieval boost formula** — composite score includes `1 + 0.1 * :math.log2(count + 1)`
3. **ETS-backed counters** — high-write retrieval counts use ETS `:counter` with periodic GenServer flush to DB

## Architecture

```
Search → :ets.update_counter(:recollect_retrieval_counters, entry_id, {2, 1})
                                    ↓ (every 30s)
                     RetrievalCounter GenServer flush → bulk DB UPDATE
```

Instead of one async `UPDATE` per search result (current `bump_access` pattern), retrieval increments are O(1) ETS counter operations, batched into a single bulk UPDATE every 30 seconds.

## Schema Changes

Add to `recollect_entries`:

```elixir
add :half_life_days, :float, default: 7.0, null: false
add :pinned, :boolean, default: false, null: false
```

Note: **No `retrieval_count` column.** The counter lives in ETS and is flushed to `access_count` (existing column) during the periodic flush. If a separate persisted retrieval count is needed later, it can be added — but `access_count` already serves this purpose.

## ETS Counter + GenServer Flush

```elixir
defmodule Recollect.RetrievalCounter do
  @moduledoc """
  GenServer that owns an ETS :counter table for retrieval bumps.

  - bump/1: O(1) :ets.update_counter call
  - Periodic flush: single bulk UPDATE to DB
  - terminate/2: final flush on shutdown
  """
  use GenServer

  @table :recollect_retrieval_counters
  @flush_interval_ms 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Increment retrieval counter for an entry. O(1)."
  def bump(entry_id) do
    :ets.update_counter(@table, entry_id, {2, 1, 1, 1})
  end

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set])
    schedule_flush()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:flush, state) do
    do_flush()
    schedule_flush()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    do_flush()
  end

  defp do_flush do
    entries = :ets.tab2list(@table)

    if entries != [] do
      now = DateTime.utc_now()
      boost_days = Recollect.Config.get([:retrieval_strengthening, :half_life_boost_days], 2)

      # Single bulk UPDATE
      ids = Enum.map(entries, fn {id, _count} -> id end)

      Recollect.Config.repo().query("""
        UPDATE recollect_entries
        SET access_count = access_count + 1,
            half_life_days = half_life_days + $1,
            last_accessed_at = $2
        WHERE id = ANY($3)
      """, [boost_days, now, ids])

      # Reset all counters
      :ets.delete_all_objects(@table)
    end
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval_ms)
  end
end
```

## Strength Calculation

Pure function, no state:

```elixir
defmodule Recollect.Strength do
  @doc """
  Calculate current strength of an entry at a point in time.
  strength = decay × retrieval_boost × emotional_multiplier × confidence
  """
  def calculate(%{pinned: true}), do: 1.0

  def calculate(entry, at_time \\ DateTime.utc_now()) do
    decay = decay_factor(entry, at_time)
    retrieval = retrieval_boost(entry)
    emotional = emotional_multiplier(entry)

    min(1.0, max(0.0, decay * retrieval * emotional * entry.confidence))
  end

  defp decay_factor(entry, now) do
    last = entry.last_accessed_at || entry.inserted_at
    days = DateTime.diff(now, last, :day)
    :math.pow(0.5, days / entry.half_life_days)
  end

  defp retrieval_boost(%{access_count: count}) do
    1 + 0.1 * :math.log2(count + 1)
  end

  defp emotional_multiplier(%{emotional_valence: valence}) do
    multipliers = :persistent_term.get({:recollect, :emotional_multipliers}, %{})
    Map.get(multipliers, valence, 1.0)
  end
end
```

## Integration with Search

Replace the current `bump_access` in `Recollect.Search.Vector`:

```elixir
# Current (hits DB per search):
defp bump_access(results, repo) do
  Task.Supervisor.start_child(Recollect.TaskSupervisor, fn ->
    repo.query("UPDATE recollect_entries SET access_count = access_count + 1, ...")
  end)
end

# New (ETS counter, batched flush):
defp bump_access(results, _repo) do
  for %{"id" => id} <- results do
    Recollect.RetrievalCounter.bump(id)
  end
end
```

## Configuration

```elixir
config :recollect,
  retrieval_strengthening: [
    enabled: true,
    half_life_boost_days: 2,
    flush_interval_ms: 30_000
  ]
```

## Application Startup

Add to `Recollect.Application`:

```elixir
def start(_type, _args) do
  children = [
    {Task.Supervisor, name: Recollect.TaskSupervisor},
    Recollect.RetrievalCounter  # NEW
  ]

  opts = [strategy: :one_for_one, name: Recollect.Supervisor]
  Supervisor.start_link(children, opts)
end
```

## Migration

```elixir
defmodule Recollect.Repo.Migrations.AddRetrievalStrengthening do
  use Ecto.Migration

  def change do
    alter table(:recollect_entries) do
      add :half_life_days, :float, default: 7.0, null: false
      add :pinned, :boolean, default: false, null: false
    end

    create index(:recollect_entries, [:half_life_days])
  end
end
```

## Backward Compatibility

- `half_life_days` defaults to 7.0 (matches Hippo default)
- `pinned` defaults to false
- Existing entries work without modification
- Retrieval strengthening is opt-in via config (but enabled by default)
- If `Recollect.RetrievalCounter` is not started, `bump/1` is a no-op (graceful degradation)

## Testing

- Unit test: `Strength.calculate/2` formula with various half-life/access_count combinations
- Unit test: strength decreases monotonically with time (for non-retrieved entries)
- Unit test: strength increases with access_count
- GenServer test: bump increments ETS counter
- GenServer test: flush writes to DB and resets counters
- GenServer test: terminate flushes before shutdown
- Integration test: search results have updated access_count after flush
- Property test: ETS counter is lock-free under concurrent access

## References

- Hippo: `memory.ts:calculateStrength()` — strength formula with retrieval boost
- Hippo: `search.ts:markRetrieved()` — half-life extension on retrieval
- Nader et al. 2000 — memory reconsolidation
