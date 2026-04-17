# Enhancement 04: Confidence Lifecycle

**Priority:** Medium | **Effort:** Low | **Status:** Proposed

## Problem

Recollect's `confidence` field is a static float (0.0–1.0) set at creation time. It never changes, even if the entry goes unused for months. In Hippo, confidence is a **lifecycle state** — memories that haven't been retrieved in 30+ days are automatically marked `stale`, and if they're recalled again, they wake back up to `observed` so they can earn trust again.

## Solution

Add `confidence_state` column with automatic state transitions computed on-read. Pure functions, no OTP processes needed.

## Schema Changes

Add to `recollect_entries`:

```elixir
add :confidence_state, :string, default: "active", null: false
# Values: "active", "stale", "verified"
```

## Lifecycle State Machine

```
                    ┌──────────┐
     creation ─────▶│  active  │
                    └────┬─────┘
                         │
                         │ 30+ days without retrieval
                         ▼
                    ┌──────────┐
                    │  stale   │
                    └────┬─────┘
                         │
                         │ retrieved again
                         ▼
                    ┌──────────┐
                    │ observed │──▶ (can become verified via outcome feedback)
                    └──────────┘
```

## Implementation — Pure Functions

```elixir
defmodule Recollect.Confidence do
  @stale_threshold_days 30

  @doc """
  Resolve the effective confidence state for an entry.
  Called during search and decay passes. Computed on-read, no DB write.
  """
  def resolve_state(%{confidence_state: "verified"}), do: "verified"

  def resolve_state(%{confidence_state: "stale"} = entry) do
    if recently_retrieved?(entry), do: "observed", else: "stale"
  end

  def resolve_state(entry) do
    if days_since_last_access(entry) > @stale_threshold_days do
      "stale"
    else
      entry.confidence_state
    end
  end

  @doc """
  Wake up a stale entry when it's retrieved again.
  Returns a changeset ready for Repo.update.
  """
  def wake_up_changeset(%{confidence_state: "stale"} = entry) do
    Ecto.Changeset.change(entry, confidence_state: "observed")
  end

  def wake_up_changeset(entry), do: Ecto.Changeset.change(entry)

  @doc """
  Mark an entry as verified (e.g., after positive outcome feedback).
  """
  def verify_changeset(entry) do
    Ecto.Changeset.change(entry, confidence_state: "verified")
  end

  defp days_since_last_access(%{last_accessed_at: nil, inserted_at: inserted_at}) do
    DateTime.diff(DateTime.utc_now(), inserted_at, :day)
  end

  defp days_since_last_access(%{last_accessed_at: at}) do
    DateTime.diff(DateTime.utc_now(), at, :day)
  end

  defp recently_retrieved?(entry) do
    days_since_last_access(entry) < @stale_threshold_days
  end
end
```

## Integration with Search

When an entry is retrieved, check if it was stale and wake it up:

```elixir
# In Recollect.Search.Vector, after bump_access:
defp maybe_wake_stale_entries(results, repo) do
  for %{"id" => id, "confidence_state" => "stale"} <- results do
    Task.Supervisor.start_child(Recollect.Config.task_supervisor(), fn ->
      repo.query(
        "UPDATE recollect_entries SET confidence_state = 'observed', updated_at = $1 WHERE id = $2",
        [DateTime.utc_now(), id]
      )
    end)
  end
end
```

## Integration with Decay

During decay pass, stale entries get archived faster:

```elixir
defmodule Recollect.Maintenance.Decay do
  defp should_archive?(entry) do
    state = Recollect.Confidence.resolve_state(entry)

    cond do
      state == "verified" -> false
      state == "stale" -> days_since(entry) > 14
      true -> days_since(entry) > 90 and entry.access_count < 3
    end
  end
end
```

## Context Formatting

Include confidence state in context output:

```elixir
def format_entry(entry) do
  state = Recollect.Confidence.resolve_state(entry)

  prefix = case state do
    "verified" -> "[verified]"
    "observed" -> "[observed]"
    "stale" -> "[stale]"
    _ -> ""
  end

  "#{prefix} #{entry.content}"
end
```

## Configuration

```elixir
config :recollect,
  confidence_lifecycle: [
    enabled: true,
    stale_threshold_days: 30,
    stale_archive_days: 14
  ]
```

## Migration

```elixir
defmodule Recollect.Repo.Migrations.AddConfidenceLifecycle do
  use Ecto.Migration

  def change do
    alter table(:recollect_entries) do
      add :confidence_state, :string, default: "active", null: false
    end

    create index(:recollect_entries, [:confidence_state])
  end
end
```

## Backward Compatibility

- `confidence_state` defaults to `"active"` for all existing entries
- Existing `confidence` float field is unchanged
- Lifecycle is opt-in via config (but enabled by default)
- `resolve_state/1` is a pure function — no process to start

## Testing

- Unit test: active → stale transition after threshold
- Unit test: stale → observed transition on retrieval
- Unit test: verified entries never become stale
- Unit test: resolve_state is idempotent (calling twice returns same result)
- Integration test: context output includes confidence state prefix
- Integration test: stale entries archive faster than active entries
