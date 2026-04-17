# Enhancement 06: Schema Acceleration

**Priority:** Medium | **Effort:** Medium | **Status:** Proposed

## Problem

Recollect treats all new entries the same regardless of how well they fit existing knowledge patterns. In Hippo, `schema_fit` computes how well new content fits the existing knowledge schema. Familiar memories consolidate faster; novel ones decay faster if unused.

The naive approach — `Repo.all()` every entry on every insert — is O(n) DB queries. With ETS, this becomes O(1).

## Solution

Add `schema_fit` scoring with an ETS-backed tag frequency index that is rebuilt during consolidation.

## Schema Changes

Add to `recollect_entries`:

```elixir
add :schema_fit, :float, default: 0.5, null: false
```

## ETS Schema Index

```elixir
defmodule Recollect.SchemaIndex do
  @moduledoc """
  ETS table for schema acceleration data.

  Rebuilt during consolidation pass. Read by compute/3 on every entry creation.
  No GenServer owner — public table, written by consolidation, read by everyone.
  """

  @table :recollect_schema_index

  @doc "Initialize the ETS table. Call from Application.start/2."
  def init do
    :ets.new(@table, [:named_table, :public, :set])
  end

  @doc "Rebuild the index from all active entries in the DB."
  def rebuild(repo) do
    # Single query: get content and tags for all non-archived entries
    rows = repo.query("""
      SELECT content, tags_json FROM recollect_entries WHERE entry_type != 'archived'
    """)

    entries = case rows do
      {:ok, %{rows: rows}} -> rows
      _ -> []
    end

    tag_freq = build_tag_frequency(entries)
    entry_count = length(entries)

    :ets.insert(@table, {:tag_frequency, tag_freq})
    :ets.insert(@table, {:entry_count, entry_count})
  end

  @doc "Get the tag frequency map. Returns %{} if index is empty."
  def tag_frequency do
    case :ets.lookup(@table, :tag_frequency) do
      [{:tag_frequency, freq}] -> freq
      [] -> %{}
    end
  end

  @doc "Get the total entry count. Returns 0 if index is empty."
  def entry_count do
    case :ets.lookup(@table, :entry_count) do
      [{:entry_count, count}] -> count
      [] -> 0
    end
  end

  defp build_tag_frequency(rows) do
    Enum.reduce(rows, %{}, fn [_content, tags_json], acc ->
      tags = case Jason.decode(tags_json) do
        {:ok, list} when is_list(list) -> list
        _ -> []
      end

      Enum.reduce(tags, acc, fn tag, acc ->
        Map.update(acc, tag, 1, &(&1 + 1))
      end)
    end)
  end
end
```

## Computation

```elixir
defmodule Recollect.SchemaFit do
  @doc """
  Compute how well new content fits existing knowledge patterns.
  Returns 0.0..1.0. Uses ETS for O(1) tag frequency lookup.
  """
  def compute(content, tags, _scope_id) do
    tag_freq = Recollect.SchemaIndex.tag_frequency()
    n = Recollect.SchemaIndex.entry_count()

    if n == 0 do
      0.5  # no schema yet, neutral
    else
      tag_score = compute_tag_fit(tags, tag_freq, n)
      content_score = compute_content_fit(content, _scope_id)

      # Blend: 60% tag overlap, 40% content overlap
      0.6 * tag_score + 0.4 * content_score
    end
  end

  defp compute_tag_fit(tags, tag_freq, n) do
    if Enum.empty?(tags) do
      0.5
    else
      weighted_overlap = Enum.reduce(tags, 0, fn tag, acc ->
        freq = Map.get(tag_freq, tag, 0)

        if freq > 0 do
          idf = :math.log(n / freq) + 1
          acc + idf
        else
          acc
        end
      end)

      max_idf = :math.log(n + 1) + 1
      total_weight = length(tags) * max_idf

      if total_weight > 0 do
        min(1.0, (weighted_overlap / total_weight) * 2)
      else
        0.0
      end
    end
  end

  defp compute_content_fit(content, scope_id) do
    new_tokens = tokenize(content)

    if Enum.empty?(new_tokens) do
      0.5
    else
      # Content overlap requires DB query — use Task.async_stream for parallelism
      # This is the expensive part; tag overlap (above) is the fast path
      repo = Recollect.Config.repo()
      entries = fetch_entries_for_overlap(scope_id, repo)

      matches = Enum.count(entries, fn entry ->
        entry_tokens = tokenize(entry["content"])
        overlap = jaccard(new_tokens, entry_tokens)
        overlap > 0.2
      end)

      n = length(entries)
      min(1.0, matches / max(5, n * 0.1))
    end
  end

  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, " ")
    |> String.split()
    |> Enum.filter(&String.length(&1) > 3)
    |> MapSet.new()
  end

  defp jaccard(set_a, set_b) do
    intersection = MapSet.intersection(set_a, set_b) |> MapSet.size()
    union = MapSet.union(set_a, set_b) |> MapSet.size()

    if union == 0, do: 1.0, else: intersection / union
  end

  defp fetch_entries_for_overlap(scope_id, repo) do
    # Limit to most recent 500 entries for performance
    repo.query("""
      SELECT content FROM recollect_entries
      WHERE scope_id = $1 AND entry_type != 'archived'
      ORDER BY inserted_at DESC
      LIMIT 500
    """, [scope_id])
    |> case do
      {:ok, %{rows: rows, columns: columns}} ->
        Enum.map(rows, fn row -> Enum.zip(columns, row) |> Map.new() end)
      _ -> []
    end
  end
end
```

## Impact on Half-Life

```elixir
def adjust_half_life_for_schema_fit(half_life_days, schema_fit) do
  cond do
    schema_fit > 0.7 -> half_life_days * 1.5
    schema_fit < 0.3 -> half_life_days * 0.5
    true -> half_life_days
  end
end
```

## Integration with Entry Creation

```elixir
def remember(content, opts \\ []) do
  tags = opts[:tags] || []
  scope_id = opts[:scope_id]

  schema_fit = Recollect.SchemaFit.compute(content, tags, scope_id)
  base_half_life = opts[:half_life_days] || 7.0
  adjusted_half_life = adjust_half_life_for_schema_fit(base_half_life, schema_fit)

  opts = opts
  |> Keyword.put(:schema_fit, schema_fit)
  |> Keyword.put(:half_life_days, adjusted_half_life)

  # ... create entry ...
end
```

## Configuration

```elixir
config :recollect,
  schema_acceleration: [
    enabled: true,
    high_fit_threshold: 0.7,
    high_fit_multiplier: 1.5,
    low_fit_threshold: 0.3,
    low_fit_multiplier: 0.5
  ]
```

## Application Startup

```elixir
# In Recollect.Application.start/2:
Recollect.SchemaIndex.init()
# Initial rebuild is deferred — run first consolidation to populate
```

## Migration

```elixir
defmodule Recollect.Repo.Migrations.AddSchemaAcceleration do
  use Ecto.Migration

  def change do
    alter table(:recollect_entries) do
      add :schema_fit, :float, default: 0.5, null: false
    end

    create index(:recollect_entries, [:schema_fit])
  end
end
```

## Performance Comparison

| Operation | Without ETS | With ETS |
|-----------|------------|----------|
| Tag frequency lookup | `Repo.all()` — O(n) rows | `:ets.lookup/2` — O(1) |
| Entry count | `Repo.aggregate(:count)` — O(n) | `:ets.lookup/2` — O(1) |
| Content overlap | `Repo.all()` — O(n) rows | Limited to 500 most recent |

## Testing

- Unit test: schema_fit computation with empty index returns 0.5
- Unit test: high tag overlap yields high schema_fit
- Unit test: rare shared tags score higher than common ones
- ETS test: rebuild populates tag_frequency and entry_count
- ETS test: tag_frequency returns %{} before rebuild
- Integration test: entry creation computes and stores schema_fit
- Property test: schema_fit is always in range [0.0, 1.0]

## References

- Hippo: `memory.ts:computeSchemaFit()` — IDF-weighted tag overlap + content overlap
- Schema theory in cognitive psychology
