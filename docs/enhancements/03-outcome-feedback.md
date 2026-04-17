# Enhancement 03: Outcome Feedback Loop

**Priority:** High | **Effort:** Low | **Status:** Proposed

## Problem

Recollect has no way to learn whether recalled memories were actually helpful. The system returns search results but never receives signal about their usefulness. This creates an open loop — memories that are irrelevant to the task at hand persist just as long as helpful ones.

Hippo closes this loop with `hippo outcome --good/--bad`, which adjusts half-life based on whether the recalled memories helped.

## Solution

Add outcome feedback API that adjusts the half-life of recently retrieved entries. Track last-retrieved IDs in an ETS table (no GenServer needed — simple public ETS with `:set` semantics).

## Schema Changes

Add to `recollect_entries`:

```elixir
add :outcome_score, :integer, null: true
# -1 = negative feedback, 0 = no feedback, 1 = positive feedback
```

## ETS-Based Last-Retrieved Tracking

```elixir
defmodule Recollect.OutcomeTracker do
  @moduledoc """
  ETS table for tracking the last-retrieved entry IDs per scope.

  No GenServer needed — this is a simple public ETS table
  that search writes to and outcome feedback reads from.
  """

  @table :recollect_last_retrieved

  @doc "Initialize the ETS table. Call from Application.start/2."
  def init do
    :ets.new(@table, [:named_table, :public, :set])
  end

  @doc "Store the retrieved entry IDs for a scope. Overwrites previous value."
  def set(scope_id, entry_ids) when is_list(entry_ids) do
    :ets.insert(@table, {scope_id, entry_ids})
  end

  @doc "Get the last-retrieved entry IDs for a scope."
  def get(scope_id) do
    case :ets.lookup(@table, scope_id) do
      [{^scope_id, ids}] -> ids
      [] -> []
    end
  end
end
```

## Outcome API

```elixir
defmodule Recollect.Outcome do
  @positive_delta 5
  @negative_delta -3

  @doc "Apply positive outcome to the last-retrieved entries for a scope."
  def good(scope_id, opts \\ []) do
    entry_ids = Recollect.OutcomeTracker.get(scope_id)
    apply_outcome(entry_ids, :good, opts)
  end

  @doc "Apply negative outcome to the last-retrieved entries for a scope."
  def bad(scope_id, opts \\ []) do
    entry_ids = Recollect.OutcomeTracker.get(scope_id)
    apply_outcome(entry_ids, :bad, opts)
  end

  @doc "Apply outcome to specific entry IDs."
  def apply(entry_ids, :good | :bad, opts \\ []) when is_list(entry_ids) do
    apply_outcome(entry_ids, :good, opts)
  end

  defp apply_outcome([], _direction, _opts), do: {:ok, 0}

  defp apply_outcome(entry_ids, :good, _opts) do
    delta = Recollect.Config.get([:outcome_feedback, :positive_half_life_delta], @positive_delta)

    Recollect.Config.repo().query("""
      UPDATE recollect_entries
      SET half_life_days = GREATEST(1, half_life_days + $1),
          outcome_score = 1,
          updated_at = $2
      WHERE id = ANY($3)
    """, [delta, DateTime.utc_now(), entry_ids])

    {:ok, length(entry_ids)}
  end

  defp apply_outcome(entry_ids, :bad, _opts) do
    delta = abs(Recollect.Config.get([:outcome_feedback, :negative_half_life_delta], @negative_delta))

    Recollect.Config.repo().query("""
      UPDATE recollect_entries
      SET half_life_days = GREATEST(1, half_life_days - $1),
          outcome_score = -1,
          updated_at = $2
      WHERE id = ANY($3)
    """, [delta, DateTime.utc_now(), entry_ids])

    {:ok, length(entry_ids)}
  end
end
```

## Integration with Search

In `Recollect.Search.Vector.do_search_entries/4`, after returning results:

```elixir
defp do_search_entries(embedding_str, scope_id, limit, min_score) do
  # ... existing query ...

  case repo.query(sql, [embedding_str, uuid_to_bin(scope_id), min_score, limit]) do
    {:ok, %{rows: rows, columns: columns}} ->
      results = Enum.map(rows, fn row -> row_to_map(columns, row) end)
      bump_access(results, repo)

      # Track for outcome feedback
      entry_ids = Enum.map(results, & &1["id"]) |> Enum.reject(&is_nil/1)
      if entry_ids != [], do: Recollect.OutcomeTracker.set(scope_id, entry_ids)

      {:ok, results}

    {:error, reason} ->
      {:error, reason}
  end
end
```

## Configuration

```elixir
config :recollect,
  outcome_feedback: [
    enabled: true,
    positive_half_life_delta: 5,
    negative_half_life_delta: -3
  ]
```

## Application Startup

Add ETS init to `Recollect.Application`:

```elixir
def start(_type, _args) do
  children = [
    {Task.Supervisor, name: Recollect.TaskSupervisor},
    {Registry, keys: :unique, name: Recollect.WorkingMemory.Registry},
    {DynamicSupervisor, strategy: :one_for_one, name: Recollect.WorkingMemory.Supervisor},
    Recollect.RetrievalCounter
  ]

  opts = [strategy: :one_for_one, name: Recollect.Supervisor]
  sup = Supervisor.start_link(children, opts)

  # Initialize ETS tables (no process owner needed)
  Recollect.OutcomeTracker.init()

  sup
end
```

## Migration

```elixir
defmodule Recollect.Repo.Migrations.AddOutcomeFeedback do
  use Ecto.Migration

  def change do
    alter table(:recollect_entries) do
      add :outcome_score, :integer, null: true
    end
  end
end
```

## Testing

- Unit test: positive outcome increases half_life_days
- Unit test: negative outcome decreases half_life_days (minimum 1 day)
- ETS test: set/2 overwrites previous value for same scope_id
- ETS test: get/2 returns [] for unknown scope_id
- Integration test: outcome affects subsequent strength calculation
- Integration test: search stores entry IDs in OutcomeTracker
