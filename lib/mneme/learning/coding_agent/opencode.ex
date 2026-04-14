defmodule Mneme.Learner.CodingAgent.OpenCode do
  @moduledoc """
  Provider for OpenCode (`~/.local/share/opencode/`).

  Reads session data from the SQLite database, including session titles,
  projects, and first user messages. OpenCode does not have a curated
  memory system — only session transcripts.

  ## Directory layout

      ~/.local/share/opencode/
      ├── opencode.db              # SQLite with session/message tables
      ├── snapshot/                # file snapshots (not read)
      ├── log/                     # logs (not read)
      └── tool-output/             # tool output (not read)
  """

  @behaviour Mneme.Learner.CodingAgent.Provider

  alias Mneme.Learner.CodingAgent.Util

  @impl true
  def agent_name, do: :opencode

  @impl true
  def default_data_paths, do: ["~/.local/share/opencode"]

  def data_paths, do: default_data_paths()

  @impl true
  def available?(config \\ %{}) do
    path = Path.join(Util.expand(hd(resolve_paths(config))), "opencode.db")
    File.exists?(path)
  end

  @impl true
  def fetch_events(config \\ %{}), do: fetch_events(config, [])

  @impl true
  def fetch_events(config, opts) do
    base = Util.expand(hd(resolve_paths(config)))
    db_path = Path.join(base, "opencode.db")

    if File.exists?(db_path) do
      fetch_sessions(db_path, opts)
    else
      []
    end
  end

  @impl true
  def extract(%{source: :session} = event), do: extract_session(event)
  def extract(_), do: {:skip, "unknown"}

  @impl true
  def summarize(events, _scope_id) do
    events
    |> Enum.group_by(& &1.project)
    |> Enum.filter(fn {_project, evts} -> length(evts) >= 2 end)
    |> Enum.map(fn {project, evts} ->
      titles = evts |> Enum.map(& &1.title) |> Enum.take(10)

      %{
        content:
          "OpenCode activity in #{project}: #{length(evts)} sessions\n\nSessions:\n#{Enum.map_join(titles, "\n", &"  • #{&1}")}",
        entry_type: :development_insight,
        emotional_valence: :neutral,
        tags: ["opencode", "session_activity", Util.project_tag(project)],
        metadata: %{source: :opencode, insight_type: :session_activity, project: project, session_count: length(evts)},
        half_life_days: 21.0,
        confidence: 0.7,
        summary: "#{project}: #{length(evts)} OpenCode sessions"
      }
    end)
  end

  defp extract_session(%{title: title, project: project, directory: directory}) do
    {:ok,
     %{
       content: "OpenCode session: #{title}\nProject: #{project}\nDirectory: #{directory}",
       entry_type: :note,
       emotional_valence: :neutral,
       tags: ["opencode", "session", Util.project_tag(project)],
       metadata: %{source: :opencode, project: project, directory: directory},
       summary: title
     }}
  end

  defp fetch_sessions(db_path, opts) do
    projects = Keyword.get(opts, :projects)
    since = Keyword.get(opts, :since, %{})

    where_clauses = ["s.time_archived IS NULL"]

    where_clauses =
      if projects && projects != [] do
        project_list = Enum.map_join(projects, ",", &"'#{&1}'")
        where_clauses ++ ["p.path IN (#{project_list})"]
      else
        where_clauses
      end

    where_clauses =
      if since && map_size(since) > 0 do
        since_dt = since |> Map.values() |> Enum.sort() |> Enum.at(0)
        if since_dt, do: where_clauses ++ ["s.time_created > '#{since_dt}'"], else: where_clauses
      else
        where_clauses
      end

    where = Enum.join(where_clauses, " AND ")

    query = """
    SELECT s.id, s.title, s.directory, p.path
    FROM session s
    LEFT JOIN project p ON s.project_id = p.id
    WHERE #{where}
    ORDER BY s.time_created DESC
    LIMIT 50
    """

    case System.cmd("sqlite3", [db_path, "-json", query], stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, rows} when is_list(rows) ->
            rows
            |> Enum.map(&parse_session_row/1)
            |> Enum.reject(&is_nil/1)

          _ ->
            []
        end

      _ ->
        []
    end
  end

  defp resolve_paths(%{data_paths: [_ | _] = paths}), do: paths
  defp resolve_paths(_), do: default_data_paths()

  defp parse_session_row(%{"id" => id, "title" => title, "directory" => directory, "path" => project_path}) do
    project =
      cond do
        is_binary(project_path) and project_path != "" -> Path.basename(project_path)
        is_binary(directory) and directory != "" -> Path.basename(directory)
        true -> "unknown"
      end

    %{
      agent: :opencode,
      source: :session,
      session_id: id,
      title: title || "Untitled",
      project: project,
      directory: directory || ""
    }
  end

  defp parse_session_row(_), do: nil
end
