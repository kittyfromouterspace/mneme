defmodule Mneme.Learner.ClaudeCode do
  @moduledoc """
  Learn from Claude Code conversations and projects.

  Detects:
  - Decisions made during conversations
  - Code changes and implementations
  - Errors and fixes
  - Project context switches
  - Tool usage patterns

  ## Usage

      {:ok, result} = Mneme.Learner.ClaudeCode.run(scope_id: scope_id)
  """

  @behaviour Mneme.Learner

  alias Mneme.Telemetry

  @impl true
  def source, do: :claude_code

  @impl true
  def fetch_since(_since, scope_id) do
    start_time = System.monotonic_time()

    projects_dir = Path.expand("~/.claude/projects")

    result =
      if File.exists?(projects_dir) do
        projects = fetch_projects(projects_dir)
        {:ok, projects}
      else
        {:ok, []}
      end

    duration =
      System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

    {:ok, projects} = result

    Telemetry.event(
      [:mneme, :learn, :claude_code, :fetch, :stop],
      %{
        duration_ms: duration,
        projects_found: length(projects)
      },
      %{scope_id: scope_id}
    )

    result
  end

  @impl true
  def extract(project) do
    content = build_content(project)
    type = detect_type(project)
    valence = detect_valence(project)
    tags = build_tags(project)

    {:ok,
     %{
       content: content,
       entry_type: type,
       emotional_valence: valence,
       tags: tags,
       metadata: %{
         source: :claude_code,
         project_name: project.name,
         last_accessed: project.last_accessed
       }
     }}
  end

  @impl true
  def detect_patterns(_projects), do: []

  @doc "Run the full Claude Code learning pipeline for a scope."
  def run(opts \\ []) do
    scope_id = Keyword.get(opts, :scope_id)
    start_time = System.monotonic_time()

    with {:ok, projects} <- fetch_since("1970-01-01", scope_id) do
      results = Enum.map(projects, &process_project/1)

      learned_count = Enum.count(results, &match?({:ok, _}, &1))
      skipped_count = Enum.count(results, &match?({:skip, _}, &1))

      duration =
        System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

      Telemetry.event(
        [:mneme, :learn, :claude_code, :stop],
        %{
          duration_ms: duration,
          fetched: length(projects),
          learned: learned_count,
          skipped: skipped_count
        },
        %{scope_id: scope_id}
      )

      {:ok,
       %{
         fetched: length(projects),
         learned: learned_count,
         skipped: skipped_count
       }}
    end
  end

  # Private implementation

  defp fetch_projects(dir) do
    dir
    |> File.ls!()
    |> Enum.map(&Path.join(dir, &1))
    |> Enum.filter(&File.dir?/1)
    |> Enum.map(&extract_project_info/1)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_project_info(project_path) do
    name = Path.basename(project_path)

    case File.stat(project_path) do
      {:ok, stat} ->
        %{
          name: name,
          path: project_path,
          last_accessed: stat.mtime,
          conversations: fetch_conversations(project_path)
        }

      _ ->
        nil
    end
  end

  defp fetch_conversations(project_path) do
    paths_to_check = [
      Path.join(project_path, "chats"),
      Path.join(project_path, "conversations"),
      Path.join(project_path, "history")
    ]

    conversations =
      paths_to_check
      |> Enum.find(fn p -> File.exists?(p) end)
      |> case do
        nil -> []
        chats_dir -> fetch_chat_files(chats_dir)
      end

    project_files = fetch_project_files(project_path)

    conversations ++ project_files
  end

  defp fetch_chat_files(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(fn f -> String.ends_with?(f, [".json", ".txt", ".md"]) end)
        |> Enum.take(10)
        |> Enum.map(fn f ->
          path = Path.join(dir, f)
          content = read_file_content(path)
          %{file: f, content: content, type: :conversation}
        end)

      _ ->
        []
    end
  end

  defp fetch_project_files(project_path) do
    result = []

    claude_md = Path.join(project_path, "CLAUDE.md")

    result =
      if File.exists?(claude_md) do
        [%{file: "CLAUDE.md", content: File.read!(claude_md), type: :context} | result]
      else
        result
      end

    settings_dir = Path.join(project_path, ".claude")

    result =
      if File.dir?(settings_dir) do
        case File.ls(settings_dir) do
          {:ok, settings_files} ->
            Enum.reduce(settings_files, result, fn f, acc ->
              path = Path.join(settings_dir, f)

              if File.regular?(path) do
                [%{file: ".claude/#{f}", content: read_file_content(path), type: :settings} | acc]
              else
                acc
              end
            end)

          _ ->
            result
        end
      else
        result
      end

    result
  end

  defp read_file_content(path) do
    case File.read(path) do
      {:ok, content} -> String.slice(content, 0, 5000)
      _ -> ""
    end
  end

  defp build_content(project) do
    conversation_summaries = Enum.map_join(project.conversations, "\n", &summarize_conversation/1)

    project_files =
      project.conversations
      |> Enum.filter(&(&1.type != :conversation))
      |> Enum.map_join("\n", &summarize_file/1)

    "Claude Code project: #{project.name}\n\nConversations:\n#{conversation_summaries}\n\nProject files:\n#{project_files}"
  end

  defp summarize_conversation(conv) do
    content = conv.content

    lines = content |> String.split("\n") |> Enum.take(20)
    summary = Enum.join(lines, " ")

    "[#{conv.file}] #{summary}"
  end

  defp summarize_file(file) do
    "[#{file.type}] #{file.file}: #{String.slice(file.content, 0, 200)}"
  end

  defp detect_type(project) do
    all_content = Enum.map_join(project.conversations, " ", & &1.content)

    if String.contains?(all_content, ["decided", "chose", "went with"]) do
      :decision
    else
      :note
    end
  end

  defp detect_valence(project) do
    all_content =
      project.conversations
      |> Enum.map_join(" ", & &1.content)
      |> String.downcase()

    if String.contains?(all_content, ["error", "fail", "broken", "bug"]) do
      :negative
    else
      :neutral
    end
  end

  defp build_tags(project) do
    tags = ["claude", "code", "project:#{project.name}"]

    type_tags =
      project.conversations
      |> Enum.map(& &1.type)
      |> Enum.uniq()
      |> Enum.map(fn t -> "type:#{t}" end)

    tags ++ type_tags
  end

  defp process_project(project) do
    {:ok, extract} = extract(project)

    Mneme.remember(extract.content,
      entry_type: extract.entry_type,
      emotional_valence: extract.emotional_valence,
      tags: extract.tags,
      metadata: extract.metadata,
      source: "system"
    )
  end
end
