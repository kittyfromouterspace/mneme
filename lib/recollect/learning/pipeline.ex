defmodule Recollect.Learning.Pipeline do
  @moduledoc """
  Orchestrate learning from multiple sources.

  The pipeline:
  1. Fetches events from each enabled learner
  2. Extracts learnable content
  3. Creates memory entries via Recollect.remember/2
  4. Optionally triggers invalidation on pattern detection

  ## Usage

      # Run all enabled learners
      {:ok, result} = Recollect.Learning.Pipeline.run(scope_id: workspace_id)
      
      # Run specific learner only
      {:ok, result} = Recollect.Learning.Pipeline.run(scope_id: workspace_id, sources: [:git])
      
      # Dry run - preview what would be learned
      {:ok, preview} = Recollect.Learning.Pipeline.run(scope_id: workspace_id, dry_run: true)
  """

  alias Recollect.Knowledge
  alias Recollect.Telemetry

  @default_learners [Recollect.Learner.Git, Recollect.Learner.CodingAgent]

  @doc """
  Run learning from configured sources.

  ## Options
  - `:scope_id` - Required. The scope to learn for
  - `:sources` - List of learner modules (default: all enabled)
  - `:since` - Learn from events since this time (default: "7 days ago")
  - `:dry_run` - If true, don't create entries (default: false)

  ## Returns
  ```
  {:ok, %{
    git: %{fetched: 12, learned: 8, skipped: 4}
  }}
  ```
  """
  def run(opts \\ []) do
    scope_id = Keyword.fetch!(opts, :scope_id)
    sources = Keyword.get(opts, :sources, enabled_learners())
    since = Keyword.get(opts, :since, "7 days ago")
    dry_run = Keyword.get(opts, :dry_run, false)

    start_time = System.monotonic_time()
    Telemetry.event([:recollect, :learning, :start], %{scope_id: scope_id}, %{sources: sources})

    results =
      sources
      |> Task.async_stream(&run_learner(&1, scope_id, since, dry_run), max_concurrency: 2)
      |> Enum.reduce(%{}, fn
        {:ok, {source, result}}, acc ->
          Telemetry.event(
            [:recollect, :learn, :source, :stop],
            %{fetched: result[:fetched] || 0, learned: result[:learned] || 0},
            %{scope_id: scope_id, source: source}
          )

          Map.put(acc, source, result)

        _, acc ->
          acc
      end)

    duration =
      System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

    total_learned = results |> Map.values() |> Enum.map(&(&1[:learned] || 0)) |> Enum.sum()
    total_fetched = results |> Map.values() |> Enum.map(&(&1[:fetched] || 0)) |> Enum.sum()

    Telemetry.event(
      [:recollect, :learning, :stop],
      %{duration_ms: duration, total_learned: total_learned, total_fetched: total_fetched},
      %{scope_id: scope_id, sources: sources, dry_run: dry_run}
    )

    if dry_run do
      {:ok, %{results: results, dry_run: true, duration_ms: duration}}
    else
      {:ok, %{results: results, duration_ms: duration}}
    end
  end

  @doc "Get list of enabled learner modules from config."
  def enabled_learners do
    :recollect
    |> Application.get_env(:learning, [])
    |> Keyword.get(:sources, @default_learners)
  end

  @doc "Check if learning is enabled."
  def enabled? do
    :recollect
    |> Application.get_env(:learning, [])
    |> Keyword.get(:enabled, true)
  end

  # Private

  defp run_learner(learner_module, scope_id, since, dry_run) do
    source = learner_module.source()

    case learner_module.fetch_since(since, scope_id) do
      {:ok, events} ->
        extracts = Enum.map(events, &learner_module.extract/1)

        {learned, skipped} =
          Enum.reduce(extracts, {[], []}, fn
            {:ok, extract}, {learned, skipped} ->
              if dry_run do
                {[extract | learned], skipped}
              else
                case Knowledge.remember(extract.content,
                       entry_type: extract.entry_type,
                       emotional_valence: extract.emotional_valence,
                       tags: extract.tags,
                       metadata: Map.put(extract.metadata, :learned_from, source),
                       source: "system"
                     ) do
                  {:ok, _} -> {[extract | learned], skipped}
                  _ -> {learned, skipped}
                end
              end

            {:skip, _reason}, {learned, skipped} ->
              {learned, [skipped]}

            _, acc ->
              acc
          end)

        learned_from_summaries =
          if function_exported?(learner_module, :summarize, 2) do
            events
            |> learner_module.summarize(scope_id)
            |> Enum.filter(fn
              %{content: content} when is_binary(content) and content != "" -> true
              _ -> false
            end)
            |> Enum.reduce({[], []}, fn extract, {l, s} ->
              if dry_run do
                {[extract | l], s}
              else
                case Knowledge.remember(extract.content,
                       entry_type: Map.get(extract, :entry_type, :note),
                       emotional_valence: Map.get(extract, :emotional_valence, :neutral),
                       tags: Map.get(extract, :tags, []),
                       metadata: Map.put(Map.get(extract, :metadata, %{}), :learned_from, source),
                       source: "system"
                     ) do
                  {:ok, _} -> {[extract | l], s}
                  _ -> {l, s}
                end
              end
            end)
            |> then(fn {l, s} -> {l, s} end)
          else
            {[], []}
          end

        total_learned = learned ++ elem(learned_from_summaries, 0)
        total_skipped = skipped ++ elem(learned_from_summaries, 1)

        {source,
         %{
           fetched: length(events),
           learned: length(total_learned),
           skipped: length(total_skipped)
         }}

      {:error, reason} ->
        {source, %{fetched: 0, learned: 0, skipped: 0, error: inspect(reason)}}
    end
  end
end
