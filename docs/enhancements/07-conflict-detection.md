# Enhancement 07: Conflict Detection

**Priority:** Medium | **Effort:** Medium | **Status:** Proposed

## Problem

Mneme has a `contradicts` edge type but no automatic detection of contradictory memories. When two entries make opposing claims (e.g., "feature X is enabled" vs "feature X is disabled"), both can coexist silently, leading to agent confusion. Hippo detects contradictions during consolidation and flags them for resolution.

## Solution

Add automatic conflict detection that identifies entries with overlapping content but contradictory polarity. The detection algorithm is CPU-bound text comparison — use `Task.async_stream` for parallelization. Conflicts are stored in a DB table (persistent, need resolution tracking).

## Schema

New table `mneme_conflicts`:

```elixir
create table(:mneme_conflicts, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :owner_id, :binary_id, null: false
  add :scope_id, :binary_id, null: false
  add :entry_a_id, :binary_id, null: false
  add :entry_b_id, :binary_id, null: false
  add :reason, :string, null: false
  add :score, :float, null: false
  add :status, :string, default: "open", null: false
  add :resolved_by, :binary_id, null: true
  add :detected_at, :utc_datetime_usec
  add :updated_at, :utc_datetime_usec
end

create index(:mneme_conflicts, [:scope_id, :status])
create index(:mneme_conflicts, [:entry_a_id])
create index(:mneme_conflicts, [:entry_b_id])
create unique_index(:mneme_conflicts, [:entry_a_id, :entry_b_id])
```

## Conflict Detection — Parallel with Task.async_stream

The detection algorithm is O(n²) pairwise comparison. For 100 entries, that's ~5000 comparisons — perfect for `Task.async_stream`:

```elixir
defmodule Mneme.ConflictDetection do
  @conflict_threshold 0.55

  @doc """
  Detect conflicts among entries in a scope.
  Uses Task.async_stream for parallel pairwise comparison.
  """
  def detect(scope_id, opts \\ []) do
    entries = get_active_entries(scope_id)

    if length(entries) < 2 do
      []
    else
      # Generate all unique pairs
      pairs = generate_pairs(entries)

      # Parallel comparison
      pairs
      |> Task.async_stream(
        fn {a, b} -> check_conflict(a, b) end,
        max_concurrency: System.schedulers_online(),
        timeout: 30_000
      )
      |> Enum.flat_map(fn
        {:ok, result} -> if result, do: [result], else: [] end
        {:exit, _reason} -> []
      end)
    end
  end

  defp generate_pairs(entries) do
    for i <- 0..(length(entries) - 2),
        j <- (i + 1)..(length(entries) - 1) do
      {Enum.at(entries, i), Enum.at(entries, j)}
    end
  end

  defp check_conflict(entry_a, entry_b) do
    # Step 1: Check content overlap (stripped of polarity words)
    stripped_overlap = text_overlap(
      strip_polarity(entry_a["content"]),
      strip_polarity(entry_b["content"])
    )

    # Step 2: Check tag overlap
    tag_overlap = jaccard(
      entry_a["tags"] || [],
      entry_b["tags"] || []
    )

    # Combined overlap score
    overlap_score = max(stripped_overlap, tag_overlap * 0.75)

    if overlap_score < @conflict_threshold do
      nil
    else
      # Step 3: Check for contradictory polarity
      case classify_conflict(entry_a["content"], entry_b["content"]) do
        nil -> nil
        reason -> %{
          entry_a_id: entry_a["id"],
          entry_b_id: entry_b["id"],
          reason: reason,
          score: overlap_score
        }
      end
    end
  end

  @doc """
  Classify the type of conflict between two texts.
  """
  def classify_conflict(text_a, text_b) do
    a = String.downcase(text_a)
    b = String.downcase(text_b)

    polarity_a = infer_polarity(text_a)
    polarity_b = infer_polarity(text_b)

    cond do
      enabled_disabled?(a, b) ->
        "enabled/disabled mismatch on overlapping statement"

      true_false?(a, b) ->
        "true/false mismatch on overlapping statement"

      always_never?(a, b) ->
        "always/never mismatch on overlapping statement"

      polarity_a == :positive and polarity_b == :negative ->
        "negation polarity mismatch on overlapping statement"
      polarity_a == :negative and polarity_b == :positive ->
        "negation polarity mismatch on overlapping statement"

      true ->
        nil
    end
  end

  defp enabled_disabled?(a, b) do
    (contains_any?(a, ["enabled", "enable", "on"]) and contains_any?(b, ["disabled", "disable", "off"])) or
    (contains_any?(b, ["enabled", "enable", "on"]) and contains_any?(a, ["disabled", "disable", "off"]))
  end

  defp true_false?(a, b) do
    (contains_any?(a, [" true ", " true.", " yes "]) and contains_any?(b, [" false ", " false.", " no "])) or
    (contains_any?(b, [" true ", " true.", " yes "]) and contains_any?(a, [" false ", " false.", " no "]))
  end

  defp always_never?(a, b) do
    (contains_any?(a, ["always", "must"]) and contains_any?(b, ["never", "must not"])) or
    (contains_any?(b, ["always", "must"]) and contains_any?(a, ["never", "must not"]))
  end

  defp infer_polarity(text) do
    lowered = " #{String.downcase(text)} "

    negative_patterns = [
      " not ", " never ", " no ", " don't ", " do not ", " doesn't ", " does not ",
      " can't ", " cannot ", " shouldn't ", " should not ", " disabled ", " disable ",
      " false ", " missing ", " broken ", " failed "
    ]

    positive_patterns = [
      " enabled ", " enable ", " works ", " working ", " true ", " available ", " present "
    ]

    cond do
      contains_any?(lowered, negative_patterns) -> :negative
      contains_any?(lowered, positive_patterns) -> :positive
      true -> :neutral
    end
  end

  defp strip_polarity(text) do
    text
    |> String.downcase()
    |> String.replace(~r/\b(?:not|never|no|don'?t|do\s+not|doesn'?t|does\s+not|can'?t|cannot|shouldn'?t|should\s+not|enabled|enable|disabled|disable|on|off|true|false|always|must|must\s+not|works?|working|missing|broken|failed|available|present)\b/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp text_overlap(a, b) do
    set_a = tokenize(a)
    set_b = tokenize(b)

    if MapSet.size(set_a) == 0 and MapSet.size(set_b) == 0, do: 1.0
    else
      intersection = MapSet.intersection(set_a, set_b) |> MapSet.size()
      union = MapSet.union(set_a, set_b) |> MapSet.size()
      if union == 0, do: 0.0, else: intersection / union
    end
  end

  defp tokenize(text) do
    text
    |> String.replace(~r/[^\w\s]/, " ")
    |> String.split()
    |> Enum.filter(&String.length(&1) > 1)
    |> MapSet.new()
  end

  defp jaccard(list_a, list_b) do
    set_a = MapSet.new(list_a)
    set_b = MapSet.new(list_b)

    if MapSet.size(set_a) == 0 and MapSet.size(set_b) == 0, do: 0.0
    else
      intersection = MapSet.intersection(set_a, set_b) |> MapSet.size()
      union = MapSet.union(set_a, set_b) |> MapSet.size()
      intersection / union
    end
  end

  defp contains_any?(text, needles) do
    Enum.any?(needles, &String.contains?(text, &1))
  end

  defp get_active_entries(scope_id) do
    repo = Mneme.Config.repo()

    repo.query("""
      SELECT id, content, tags_json FROM mneme_entries
      WHERE scope_id = $1 AND entry_type != 'archived'
    """, [scope_id])
    |> case do
      {:ok, %{rows: rows, columns: columns}} ->
        Enum.map(rows, fn row ->
          map = Enum.zip(columns, row) |> Map.new()
          # Parse tags_json
          tags = case Jason.decode(map["tags_json"]) do
            {:ok, list} when is_list(list) -> list
            _ -> []
          end
          Map.put(map, "tags", tags)
        end)
      _ -> []
    end
  end
end
```

## Conflict Resolution API

```elixir
defmodule Mneme.Conflicts do
  @doc "List open conflicts for a scope."
  def list(scope_id) do
    repo = Mneme.Config.repo()

    repo.query("""
      SELECT id, entry_a_id, entry_b_id, reason, score, status, detected_at
      FROM mneme_conflicts
      WHERE scope_id = $1 AND status = 'open'
      ORDER BY score DESC
    """, [scope_id])
    |> case do
      {:ok, %{rows: rows, columns: columns}} ->
        {:ok, Enum.map(rows, fn row -> Enum.zip(columns, row) |> Map.new() end)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Resolve a conflict by keeping one entry and weakening the other.
  The loser's half-life is halved.
  """
  def resolve(conflict_id, keep_entry_id) do
    repo = Mneme.Config.repo()

    # Get conflict details
    {:ok, %{rows: [[loser_id]]}} = repo.query("""
      SELECT CASE
        WHEN entry_a_id = $1 THEN entry_b_id
        ELSE entry_a_id
      END
      FROM mneme_conflicts WHERE id = $2
    """, [keep_entry_id, conflict_id])

    repo.transaction(fn ->
      # Mark conflict as resolved
      repo.query("""
        UPDATE mneme_conflicts
        SET status = 'resolved', resolved_by = $1, updated_at = $2
        WHERE id = $3
      """, [keep_entry_id, DateTime.utc_now(), conflict_id])

      # Weaken loser
      repo.query("""
        UPDATE mneme_entries
        SET half_life_days = GREATEST(1, half_life_days / 2), updated_at = $1
        WHERE id = $2
      """, [DateTime.utc_now(), loser_id])
    end)
  end

  @doc "Resolve a conflict by deleting the losing entry."
  def resolve_and_forget(conflict_id, keep_entry_id) do
    repo = Mneme.Config.repo()

    {:ok, %{rows: [[loser_id]]}} = repo.query("""
      SELECT CASE
        WHEN entry_a_id = $1 THEN entry_b_id
        ELSE entry_a_id
      END
      FROM mneme_conflicts WHERE id = $2
    """, [keep_entry_id, conflict_id])

    repo.transaction(fn ->
      repo.query("""
        UPDATE mneme_conflicts
        SET status = 'resolved', resolved_by = $1, updated_at = $2
        WHERE id = $3
      """, [keep_entry_id, DateTime.utc_now(), conflict_id])

      repo.query("DELETE FROM mneme_entries WHERE id = $1", [loser_id])
    end)
  end
end
```

## Integration with Sleep Consolidation

Conflict detection runs as part of the consolidation pass (see Enhancement 08):

```elixir
def consolidate(scope_id, opts \\ []) do
  # ... decay pass, merge pass ...

  # Conflict detection pass (parallel via Task.async_stream)
  conflicts = Mneme.ConflictDetection.detect(scope_id)
  persist_conflicts(scope_id, conflicts)

  %{conflicts_detected: length(conflicts)}
end
```

## Context Formatting

Include conflict warnings in context output:

```elixir
def format_entry_with_conflicts(entry, conflicts) do
  entry_conflicts = Enum.filter(conflicts, fn c ->
    c["entry_a_id"] == entry["id"] or c["entry_b_id"] == entry["id"]
  end)

  conflict_warning = if Enum.any?(entry_conflicts) do
    "\n  Warning: This entry conflicts with #{length(entry_conflicts)} other memory(ies)"
  else
    ""
  end

  "#{entry["content"]}#{conflict_warning}"
end
```

## Migration

```elixir
defmodule Mneme.Repo.Migrations.AddConflictDetection do
  use Ecto.Migration

  def change do
    create table(:mneme_conflicts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :owner_id, :binary_id, null: false
      add :scope_id, :binary_id, null: false
      add :entry_a_id, :binary_id, null: false
      add :entry_b_id, :binary_id, null: false
      add :reason, :string, null: false
      add :score, :float, null: false
      add :status, :string, default: "open", null: false
      add :resolved_by, :binary_id
      add :detected_at, :utc_datetime_usec
      add :updated_at, :utc_datetime_usec
    end

    create index(:mneme_conflicts, [:scope_id, :status])
    create index(:mneme_conflicts, [:entry_a_id])
    create index(:mneme_conflicts, [:entry_b_id])
    create unique_index(:mneme_conflicts, [:entry_a_id, :entry_b_id])
  end
end
```

## Testing

- Unit test: conflict detection finds enabled/disabled mismatches
- Unit test: conflict detection finds true/false mismatches
- Unit test: conflict detection finds always/never mismatches
- Unit test: non-conflicting overlapping entries are not flagged
- Unit test: conflict resolution weakens loser's half-life
- Task.async_stream test: parallel detection handles failures gracefully
- Integration test: conflicts appear in context output with warnings
- Property test: conflict pairs are always canonically ordered (a < b)

## References

- Hippo: `consolidate.ts:detectConflicts()` — conflict detection during sleep
- Hippo: `consolidate.ts:classifyConflictType()` — pattern-based contradiction classification
