# Enhancement 08: Sleep Consolidation

**Priority:** Low | **Effort:** High | **Status:** Proposed

## Problem

Recollect has no mechanism for compressing repeated episodic knowledge into stable semantic patterns. Entries accumulate individually without ever being synthesized. In human memory (and in Hippo), sleep consolidation replays compressed versions of recent episodes and "teaches" the neocortex by repeatedly activating the same patterns.

## Solution

Add a `Recollect.Consolidation` module that runs a multi-pass consolidation cycle using `Task.async_stream` for CPU-bound operations. No new process needed — uses the existing `Recollect.TaskSupervisor`.

## API

```elixir
defmodule Recollect.Consolidation do
  @doc """
  Run a full consolidation pass for a scope.
  Returns consolidation results.
  """
  def run(scope_id, opts \\ [])

  @doc """
  Preview what consolidation would do without making changes.
  """
  def dry_run(scope_id, opts \\ [])
end
```

### Usage

```elixir
# Full consolidation
{:ok, result} = Recollect.Consolidation.run(scope_id: workspace_id)
# %{
#   decayed: 23,
#   removed: 4,
#   merged: 6,
#   semantic_created: 2,
#   conflicts_detected: 1,
#   duration_ms: 1247
# }

# Preview
{:ok, preview} = Recollect.Consolidation.dry_run(scope_id: workspace_id)
```

## Consolidation Passes

### Pass 1: Decay

Calculate current strength for all entries, remove those below threshold:

```elixir
defp decay_pass(entries, opts) do
  threshold = Keyword.get(opts, :decay_threshold, 0.05)
  now = DateTime.utc_now()

  {survivors, removed} = Enum.split_with(entries, fn entry ->
    entry.pinned or Recollect.Strength.calculate(entry, now) >= threshold
  end)

  %{survivors: survivors, removed: removed, count: length(removed)}
end
```

### Pass 2: Merge — Parallel with Task.async_stream

Find entries with high text overlap, create semantic summaries. The overlap computation is CPU-bound — parallelize with `Task.async_stream`:

```elixir
defp merge_pass(entries, opts) do
  overlap_threshold = Keyword.get(opts, :merge_overlap_threshold, 0.35)
  min_cluster = Keyword.get(opts, :merge_min_cluster, 3)

  # Build pairs for parallel overlap computation
  pairs = for i <- 0..(length(entries) - 2),
              j <- (i + 1)..(length(entries) - 1) do
    {i, j}
  end

  # Parallel overlap computation
  overlaps =
    pairs
    |> Task.async_stream(
      fn {i, j} ->
        a = Enum.at(entries, i)
        b = Enum.at(entries, j)
        {i, j, text_overlap(a["content"], b["content"])}
      end,
      max_concurrency: System.schedulers_online(),
      timeout: 30_000
    )
    |> Enum.flat_map(fn
      {:ok, {i, j, overlap}} when overlap >= overlap_threshold -> [{i, j}]
      _ -> []
    end)

  # Build clusters from overlap graph (connected components)
  clusters = build_clusters(overlaps, length(entries))

  # Filter to minimum cluster size
  valid_clusters = Enum.filter(clusters, fn indices ->
    length(indices) >= min_cluster
  end)

  # Create semantic summaries
  summaries = Enum.map(valid_clusters, fn indices ->
    cluster = Enum.map(indices, &Enum.at(entries, &1))
    create_semantic_summary(cluster)
  end)

  %{
    merged: length(List.flatten(valid_clusters)),
    semantic_created: length(summaries),
    summaries: summaries,
    cluster_indices: valid_clusters
  }
end

defp build_clusters(overlaps, n) do
  # Union-Find for connected components
  parent = Enum.reduce(0..(n - 1), %{}, fn i, acc -> Map.put(acc, i, i) end)

  find = fn node ->
    # Path compression
    case parent[node] do
      ^node -> node
      p -> find.(p)
    end
  end

  union = fn {i, j} ->
    root_i = find.(i)
    root_j = find.(j)
    if root_i != root_j do
      Map.put(parent, root_i, root_j)
    else
      parent
    end
  end

  parent = Enum.reduce(overlaps, parent, union)

  # Group by root
  parent
  |> Enum.group_by(fn {_k, v} -> v end, fn {k, _v} -> k end)
  |> Map.values()
  |> Enum.filter(&(&1 != []))
end

defp create_semantic_summary(cluster) do
  base = Enum.max_by(cluster, &String.length(&1["content"]))

  if length(cluster) <= 2 do
    "[Consolidated from #{length(cluster)} related memories]\n\n#{base["content"]}"
  else
    bullets = Enum.map(cluster, fn e ->
      "- #{e["content"] |> String.split("\n") |> hd() |> String.slice(0, 120)}"
    end)

    "[Consolidated pattern from #{length(cluster)} related memories]\n\n#{Enum.join(bullets, "\n")}"
  end
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
  |> String.downcase()
  |> String.replace(~r/[^\w\s]/, " ")
  |> String.split()
  |> Enum.filter(&String.length(&1) > 1)
  |> MapSet.new()
end
```

### Pass 3: Conflict Detection

Delegate to `Recollect.ConflictDetection` (see Enhancement 07):

```elixir
defp conflict_pass(scope_id) do
  Recollect.ConflictDetection.detect(scope_id)
end
```

### Pass 4: Schema Indexing

Rebuild the ETS schema index (see Enhancement 06):

```elixir
defp schema_indexing_pass do
  Recollect.SchemaIndex.rebuild(Recollect.Config.repo())
end
```

### Pass 5: Persist Results

```elixir
defp persist_consolidation_run(scope_id, results, duration_ms) do
  repo = Recollect.Config.repo()

  repo.query("""
    INSERT INTO recollect_consolidation_runs
      (id, scope_id, timestamp, decayed, removed, merged, semantic_created, conflicts_detected, duration_ms)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
  """, [
    Ecto.UUID.generate(),
    scope_id,
    DateTime.utc_now(),
    results.decayed,
    results.removed,
    results.merged,
    results.semantic_created,
    results.conflicts_detected,
    duration_ms
  ])
end
```

## Full Consolidation Pipeline

```elixir
def run(opts \\ []) do
  scope_id = Keyword.fetch!(opts, :scope_id)
  dry_run = Keyword.get(opts, :dry_run, false)
  start_time = System.monotonic_time()

  entries = fetch_entries(scope_id)

  # Pass 1: Decay
  decay_result = decay_pass(entries, opts)

  # Pass 2: Merge (parallel)
  merge_result = merge_pass(decay_result.survivors, opts)

  # Pass 3: Conflict detection (parallel)
  conflicts = conflict_pass(scope_id)

  # Pass 4: Rebuild schema index
  schema_indexing_pass()

  # Pass 5: Persist (unless dry run)
  duration_ms = System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

  unless dry_run do
    persist_consolidation_run(scope_id, %{
      decayed: decay_result.count,
      removed: length(decay_result.removed),
      merged: merge_result.merged,
      semantic_created: merge_result.semantic_created,
      conflicts_detected: length(conflicts)
    }, duration_ms)

    # Persist conflict records
    persist_conflicts(scope_id, conflicts)

    # Create semantic summary entries
    create_summary_entries(scope_id, merge_result.summaries)
  end

  {:ok, %{
    decayed: decay_result.count,
    removed: length(decay_result.removed),
    merged: merge_result.merged,
    semantic_created: merge_result.semantic_created,
    conflicts_detected: length(conflicts),
    duration_ms: duration_ms,
    dry_run: dry_run
  }}
end
```

## Scheduling

### Option 1: Mix Task

```elixir
defmodule Mix.Tasks.Recollect.Consolidate do
  use Mix.Task

  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [scope_id: :string, dry_run: :boolean])

    scope_id = opts[:scope_id] || raise "scope_id is required"

    if opts[:dry_run] do
      {:ok, preview} = Recollect.Consolidation.dry_run(scope_id: scope_id)
      IO.inspect(preview)
    else
      {:ok, result} = Recollect.Consolidation.run(scope_id: scope_id)
      IO.puts("Decayed: #{result.decayed}")
      IO.puts("Removed: #{result.removed}")
      IO.puts("Merged: #{result.merged}")
      IO.puts("Semantic created: #{result.semantic_created}")
      IO.puts("Conflicts detected: #{result.conflicts_detected}")
      IO.puts("Duration: #{result.duration_ms}ms")
    end
  end
end
```

### Option 2: Host Application Scheduler

Let the host app decide when to consolidate — no built-in scheduler needed:

```elixir
# In host app's application.ex (using Quantum)
children = [
  # ...
  {Quantum, cron: "0 6 * * *", job: {Recollect.Consolidation, :run, [[scope_id: workspace_id]]}}
]
```

### Option 3: Event-Triggered

```elixir
# After session end with many entries
def on_session_end(session) do
  if session.entry_count > 10 do
    Recollect.Consolidation.run(scope_id: session.scope_id)
  end
end
```

## LLM-Powered Merge (Future)

The text-overlap merge is a starting point. Future: use the extraction provider's `llm_fn` for better summaries:

```elixir
defp create_semantic_summary_llm(cluster) do
  prompt = """
  Synthesize the following related memories into a single concise summary:

  #{Enum.map_join(cluster, "\n\n", fn e -> "- #{e["content"]}" end)}

  Return a single paragraph that captures the common pattern.
  """

  {provider, provider_opts} = {Recollect.Config.extraction_provider(), Recollect.Config.extraction_opts()}

  case provider.extract(prompt, provider_opts) do
    {:ok, summary} -> summary
    _ -> create_semantic_summary(cluster)  # fallback
  end
end
```

## Telemetry Integration

Emit telemetry events for consolidation runs:

```elixir
def run(opts \\ []) do
  # ...
  Recollect.Telemetry.event([:recollect, :consolidation, :stop], %{
    duration: duration_ms,
    decayed: result.decayed,
    removed: result.removed,
    merged: result.merged,
    semantic_created: result.semantic_created,
    conflicts_detected: result.conflicts_detected
  })
end
```

## Configuration

```elixir
config :recollect,
  sleep_consolidation: [
    enabled: true,
    decay_threshold: 0.05,
    merge_overlap_threshold: 0.35,
    merge_min_cluster: 3
  ]
```

## Migration

```elixir
defmodule Recollect.Repo.Migrations.AddConsolidationRuns do
  use Ecto.Migration

  def change do
    create table(:recollect_consolidation_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :scope_id, :binary_id, null: false
      add :timestamp, :utc_datetime_usec, null: false
      add :decayed, :integer, default: 0
      add :removed, :integer, default: 0
      add :merged, :integer, default: 0
      add :semantic_created, :integer, default: 0
      add :conflicts_detected, :integer, default: 0
      add :duration_ms, :integer
    end

    create index(:recollect_consolidation_runs, [:scope_id, :timestamp])
  end
end
```

## Testing

- Unit test: decay pass removes entries below threshold
- Unit test: decay pass preserves pinned entries
- Unit test: merge pass clusters entries by overlap
- Unit test: merge pass creates semantic summaries
- Task.async_stream test: parallel overlap computation handles failures
- Integration test: full consolidation pipeline
- Integration test: dry run reports changes without persisting
- Property test: consolidation is idempotent (running twice yields same result)
- Telemetry test: consolidation emits [:recollect, :consolidation, :stop] event

## References

- Hippo: `consolidate.ts:consolidate()` — decay + merge + conflict detection
- McClelland et al. 1995 — Complementary Learning Systems theory
- Sleep-dependent memory consolidation neuroscience
