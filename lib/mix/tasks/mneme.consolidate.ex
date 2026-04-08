defmodule Mix.Tasks.Mneme.Consolidate do
  @moduledoc """
  Run Mneme sleep consolidation for a scope.

      mix mneme.consolidate --scope-id SCOPE_ID

  ## Options

  - `--scope-id` (required) — The scope to consolidate
  - `--dry-run` — Preview what would happen without making changes
  - `--decay-threshold` — Minimum strength to survive (default: 0.05)
  - `--merge-threshold` — Text overlap threshold for merging (default: 0.35)
  - `--min-cluster` — Minimum entries to form a merge cluster (default: 3)

  ## Example

      mix mneme.consolidate --scope-id abc-123
      mix mneme.consolidate --scope-id abc-123 --dry-run
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          scope_id: :string,
          dry_run: :boolean,
          decay_threshold: :float,
          merge_threshold: :float,
          min_cluster: :integer
        ]
      )

    if !opts[:scope_id] do
      raise "--scope-id is required"
    end

    consolidation_opts = [
      scope_id: opts[:scope_id],
      dry_run: opts[:dry_run] || false,
      decay_threshold: opts[:decay_threshold] || 0.05,
      merge_threshold: opts[:merge_threshold] || 0.35,
      min_cluster: opts[:min_cluster] || 3
    ]

    IO.puts("\n#{IO.ANSI.green()}Running Mneme consolidation...#{IO.ANSI.reset()}\n")

    {:ok, result} = Mneme.Consolidation.run(consolidation_opts)
    IO.puts("Decayed: #{result.decayed}")
    IO.puts("Removed: #{result.removed}")
    IO.puts("Merged: #{result.merged}")
    IO.puts("Semantic summaries created: #{result.semantic_created}")
    IO.puts("Conflicts detected: #{result.conflicts_detected}")
    IO.puts("Duration: #{result.duration_ms}ms")
    IO.puts("\n#{IO.ANSI.green()}Consolidation complete!#{IO.ANSI.reset()}")
  end
end
