defmodule Mneme.Learner.Git.Grouper do
  @moduledoc """
  Groups git commits into synthesized development insights.

  Instead of storing every commit as a separate memory entry, this module
  clusters related commits by topic and produces high-level narrative entries
  (`development_insight`) that capture the *story* of what changed and why.

  ## Grouping strategy

  1. **Filter noise** — drop merges, version bumps, typo fixes, etc.
  2. **Extract topics** — conventional-commit scope (`feat(auth):`) or
     keyword extraction from the subject line.
  3. **Group by topic** — commits sharing a topic land in the same cluster.
  4. **Build insights** — each cluster of 2+ commits becomes one
     `development_insight` extract; singletons that are significant enough
     (breaking changes, migrations) are emitted individually.

  ## Result shape

  Each insight is an `%{content, entry_type, emotional_valence, tags,
  metadata}` map ready for `Knowledge.remember/2`, with optional overrides
  (`half_life_days`, `confidence`, `summary`).
  """

  alias Mneme.Learner.Git, as: GitLearner

  @noise_prefixes ~w(merge branch merge\ pull)
  @noise_patterns [
    ~r/^v?\d+\.\d+\.\d+/,
    ~r/^merge\s/i,
    ~r/^(initial\s+commit|first\s+commit)/i
  ]
  @noise_words ~w(typo whitespace formatting) ++ ["lint fix", "wip"]

  @stop_words ~w(
    the a an is are was were be been being have has had do does did
    will would shall should may might can could must need to of in
    for on with at by from as into through during before after above
    below between out off over under again further then once and but
    or nor not so yet both either neither each every all any few more
    most other some such no only own same than too very just also
    add fix update remove refactor move rename clean
  )

  @doc """
  Group commits and return a list of `development_insight` extracts.

  Only groups of 2+ commits produce an insight. Individual significant
  commits (breaking changes, migrations) are also emitted as single-entry
  insights when they survive noise filtering.
  """
  def summarize(commits) do
    filtered = filter_noise(commits)

    {grouped, singletons} =
      filtered
      |> Enum.map(&{&1, extract_topic(&1)})
      |> group_by_topic()

    group_insights = Enum.map(grouped, &build_group_insight/1)

    singleton_insights =
      singletons
      |> Enum.filter(&significant_singleton?/1)
      |> Enum.map(&build_singleton_insight/1)

    group_insights ++ singleton_insights
  end

  defp filter_noise(commits) do
    Enum.reject(commits, &noise?/1)
  end

  defp noise?(commit) do
    subject = String.downcase(commit.subject)

    Enum.any?(@noise_patterns, &Regex.match?(&1, subject)) or
      Enum.any?(@noise_words, &String.contains?(subject, &1)) or
      String.starts_with?(subject, @noise_prefixes)
  end

  defp extract_topic(commit) do
    case Regex.run(~r/^\w+\(([^)]+)\)\s*:/, commit.subject) do
      [_, scope] ->
        String.downcase(scope)

      _ ->
        commit.subject
        |> String.downcase()
        |> String.split(~r/[^a-z0-9_]+/, trim: true)
        |> Enum.reject(&(&1 in @stop_words))
        |> Enum.reject(&(String.length(&1) < 3))
        |> List.first("general")
    end
  end

  defp group_by_topic(tagged_commits) do
    grouped =
      tagged_commits
      |> Enum.group_by(fn {_commit, topic} -> topic end, fn {commit, _topic} -> commit end)
      |> Enum.map(fn {topic, commits} -> {topic, Enum.sort_by(commits, & &1.sha)} end)
      |> Enum.split_with(fn {_topic, commits} -> length(commits) >= 2 end)

    singletons =
      grouped
      |> elem(1)
      |> Enum.flat_map(fn {topic, commits} ->
        Enum.map(commits, fn commit -> {commit, topic} end)
      end)

    {elem(grouped, 0), singletons}
  end

  defp significant_singleton?({commit, _topic}) do
    type = GitLearner.detect_type(commit.subject)
    type in [:breaking, :migration, :revert]
  end

  defp build_group_insight({topic, commits}) do
    types = Enum.map(commits, &GitLearner.detect_type(&1.subject))
    type_counts = Enum.frequencies(types)

    content =
      Enum.join(
        [
          "Development activity in #{topic} (#{length(commits)} commits):",
          "",
          "Breakdown:",
          format_type_counts(type_counts),
          "",
          "Commits:" | format_commit_list(commits)
        ],
        "\n"
      )

    summary = "#{topic}: #{length(commits)} commits — #{summarize_types(type_counts)}"

    %{
      content: content,
      entry_type: :development_insight,
      emotional_valence: infer_valence(types),
      tags: ["git", "development_insight", "area:#{topic}"],
      metadata: %{
        source: :git,
        commit_count: length(commits),
        types: Enum.uniq(types),
        insight_type: classify_group(types),
        commit_shas: Enum.map(commits, & &1.sha),
        authors: commits |> Enum.map(& &1.author) |> Enum.uniq()
      },
      half_life_days: 30.0,
      confidence: 0.9,
      summary: summary
    }
  end

  defp build_singleton_insight({commit, topic}) do
    type = GitLearner.detect_type(commit.subject)

    content =
      "Significant change in #{topic}: #{commit.subject}" <>
        if(commit.body && commit.body != "",
          do: "\n\n#{commit.body}",
          else: ""
        )

    %{
      content: content,
      entry_type: :development_insight,
      emotional_valence: if(type in [:breaking, :migration], do: :negative, else: :neutral),
      tags: ["git", "development_insight", "area:#{topic}", "type:#{type}"],
      metadata: %{
        source: :git,
        commit_count: 1,
        types: [type],
        insight_type: :significant_change,
        commit_shas: [commit.sha],
        authors: [commit.author]
      },
      half_life_days: 30.0,
      confidence: 0.9,
      summary: commit.subject
    }
  end

  defp format_type_counts(type_counts) do
    type_counts
    |> Enum.sort_by(fn {_type, count} -> -count end)
    |> Enum.map_join("\n", fn {type, count} -> "  - #{count}x #{type}" end)
  end

  defp format_commit_list(commits) do
    shown = Enum.take(commits, 10)
    rest = length(commits) - 10

    lines = Enum.map(shown, fn c -> "  - #{c.subject}" end)

    if rest > 0 do
      lines ++ ["  ... and #{rest} more"]
    else
      lines
    end
  end

  defp summarize_types(type_counts) do
    type_counts
    |> Enum.sort_by(fn {_type, count} -> -count end)
    |> Enum.take(3)
    |> Enum.map_join(", ", fn {type, count} -> "#{count} #{type}#{if count > 1, do: "s", else: ""}" end)
  end

  defp infer_valence(types) do
    fix_ratio = Enum.count(types, &(&1 == :fix)) / max(length(types), 1)
    breaking_ratio = Enum.count(types, &(&1 in [:breaking, :migration])) / max(length(types), 1)

    cond do
      breaking_ratio > 0.3 -> :negative
      fix_ratio > 0.5 -> :negative
      Enum.any?(types, &(&1 == :feature)) -> :positive
      true -> :neutral
    end
  end

  defp classify_group(types) do
    cond do
      :migration in types -> :migration
      :breaking in types -> :breaking_change
      Enum.count(types, &(&1 == :fix)) > length(types) / 2 -> :bug_cluster
      Enum.count(types, &(&1 == :feature)) > length(types) / 2 -> :feature_development
      true -> :area_evolution
    end
  end
end
