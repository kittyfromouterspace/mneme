defmodule Recollect.Invalidation do
  @moduledoc """
  Active memory invalidation based on detected or explicit breaking changes.

  When a breaking change is detected (e.g., migrating from webpack to vite),
  this module weakens related memories and optionally creates replacement entries.

  ## Usage

      # Auto-detect and invalidate from git history
      {:ok, result} = Recollect.Invalidation.run_from_git(scope_id: workspace_id)
      
      # Manual invalidation
      Recollect.Invalidation.invalidate(scope_id, "webpack",
        reason: "migrated to vite"
      )
  """

  alias Recollect.Config
  alias Recollect.Knowledge
  alias Recollect.Telemetry

  @migration_patterns [
    ~r/migrate[ds]?\s+(?:from\s+)?(\w+)\s+(?:to|with)\s+(\w+)/i,
    ~r/(?:refactor|rewrite):\s+(\w+)\s+(?:to|->)\s+(\w+)/i,
    ~r/replace[dr]?\s+(\w+)\s+(?:with|by)\s+(\w+)/i,
    ~r/drop(?:ped)?\s+(?:support\s+for\s+)?(\w+)/i,
    ~r/remove[dr]?\s+(\w+)\s+(?:and|use)\s+(\w+)/i,
    ~r/BREAKING(?:\s+CHANGE)?:/i
  ]

  @default_weaken_factor 0.1

  @doc """
  Run invalidation detection from git history.

  Scans recent commits for migration patterns and invalidates related memories.
  """
  def run_from_git(opts \\ []) do
    scope_id = Keyword.fetch!(opts, :scope_id)
    days = Keyword.get(opts, :days, 7)

    start_time = System.monotonic_time()
    Telemetry.event([:recollect, :invalidation, :start], %{scope_id: scope_id}, %{days: days})

    migrations = detect_migrations(days)

    results =
      Enum.map(migrations, fn migration ->
        weaken_related(scope_id, migration.from, migration.to)
      end)

    duration =
      System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

    total_invalidated = Enum.sum(results)

    Telemetry.event(
      [:recollect, :invalidation, :stop],
      %{
        duration_ms: duration,
        migrations_detected: length(migrations),
        invalidations: total_invalidated
      },
      %{scope_id: scope_id, days: days}
    )

    {:ok,
     %{
       migrations_detected: length(migrations),
       invalidations: total_invalidated,
       migrations: migrations
     }}
  end

  @doc """
  Invalidate memories matching a pattern.

  ## Options
  - `:reason` - Why this is being invalidated
  - `:replacement` - What replaces it (creates new entry with supersedes link)
  - `:weaken_factor` - Multiply half-life by this (default: 0.1)
  """
  def invalidate(scope_id, pattern, opts \\ []) do
    reason = Keyword.get(opts, :reason, "manual_invalidation")
    replacement = Keyword.get(opts, :replacement)
    weaken_factor = Keyword.get(opts, :weaken_factor, @default_weaken_factor)

    start_time = System.monotonic_time()

    # Find and weaken matching entries
    count = weaken_matching(scope_id, pattern, weaken_factor)

    # Optionally create replacement entry
    replacement_created =
      if replacement do
        case Knowledge.remember(replacement,
               scope_id: scope_id,
               entry_type: "note",
               metadata: %{supersedes: pattern, reason: reason},
               source: "system"
             ) do
          {:ok, _} -> true
          _ -> false
        end
      else
        false
      end

    duration =
      System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

    Telemetry.event(
      [:recollect, :invalidate, :stop],
      %{duration_ms: duration, invalidated: count, replacement_created: replacement_created},
      %{scope_id: scope_id, pattern: pattern, reason: reason}
    )

    {:ok, %{invalidated: count, replacement_created: replacement_created}}
  end

  @doc """
  Detect migration patterns in recent git commits.
  """
  def detect_migrations(days \\ 7) do
    case System.cmd("git", ["log", "--since=#{days} days", "--pretty=format:%s"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&parse_migration/1)

      _ ->
        []
    end
  end

  # Private

  defp parse_migration(subject) do
    Enum.reduce(@migration_patterns, [], fn pattern, acc ->
      case Regex.run(pattern, subject) do
        [_, from, to] ->
          [%{type: :migration, from: from, to: to, subject: subject} | acc]

        _ ->
          acc
      end
    end)
  end

  defp weaken_related(scope_id, from_concept, _to_concept) do
    # Find entries mentioning the old concept
    pattern = "%#{from_concept}%"

    repo = Config.repo()

    # Update half-life for matching entries
    result =
      repo.query(
        """
          UPDATE recollect_entries
          SET half_life_days = GREATEST(0.5, half_life_days * $1),
              confidence = GREATEST(0.05, confidence * $1),
              updated_at = $2
          WHERE scope_id = $3
            AND entry_type != 'archived'
            AND content ILIKE $4
            AND half_life_days > 0.5
        """,
        [@default_weaken_factor, DateTime.utc_now(), Recollect.Util.uuid_to_bin(scope_id), pattern]
      )

    case result do
      {:ok, %{num_rows: count}} -> count
      _ -> 0
    end
  end

  defp weaken_matching(scope_id, pattern, factor) do
    repo = Config.repo()

    result =
      repo.query(
        """
          UPDATE recollect_entries
          SET half_life_days = GREATEST(0.5, half_life_days * $1),
              confidence = GREATEST(0.05, confidence * $1),
              updated_at = $2
          WHERE scope_id = $3
            AND entry_type != 'archived'
            AND content ILIKE $4
        """,
        [factor, DateTime.utc_now(), Recollect.Util.uuid_to_bin(scope_id), "%#{pattern}%"]
      )

    case result do
      {:ok, %{num_rows: count}} -> count
      _ -> 0
    end
  end
end
