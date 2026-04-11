defmodule Mneme.Learner.CodingAgent.Gemini do
  @moduledoc """
  Provider for Google Gemini CLI (`~/.gemini/`).

  Reads session chat files stored under per-project directories
  in the tmp/ folder, plus the projects index.

  ## Directory layout

      ~/.gemini/
      ├── tmp/<project-slug>/chats/session-*.json  # session transcripts
      ├── history/<project-slug>/.project_root      # project roots
      ├── projects.json                             # project index
      └── settings.json                             # auth settings (skipped)
  """

  @behaviour Mneme.Learner.CodingAgent.Provider

  alias Mneme.Learner.CodingAgent.Util

  @impl true
  def agent_name, do: :gemini

  @impl true
  def data_paths, do: ["~/.gemini"]

  @impl true
  def available?, do: Util.dir_exists?(hd(data_paths()))

  @impl true
  def fetch_events, do: fetch_events([])

  @impl true
  def fetch_events(opts) do
    base = Util.expand(hd(data_paths()))
    fetch_sessions(base, opts)
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
      prompts = evts |> Enum.flat_map(& &1.user_prompts) |> Enum.take(10)

      %{
        content:
          "Gemini activity in #{project}: #{length(evts)} sessions\n\nTopics:\n#{Enum.map_join(prompts, "\n", &"  • #{&1}")}",
        entry_type: :development_insight,
        emotional_valence: :neutral,
        tags: ["gemini", "session_activity", Util.project_tag(project)],
        metadata: %{source: :gemini, insight_type: :session_activity, project: project, session_count: length(evts)},
        half_life_days: 21.0,
        confidence: 0.7,
        summary: "#{project}: #{length(evts)} Gemini sessions"
      }
    end)
  end

  defp extract_session(%{user_prompts: []}), do: {:skip, "no user prompts"}

  defp extract_session(%{user_prompts: prompts, project: project, session_id: sid}) do
    {:ok,
     %{
       content: "Gemini session #{Util.short_id(sid)} in #{project}: #{Enum.join(prompts, "\n• ")}",
       entry_type: :note,
       emotional_valence: :neutral,
       tags: ["gemini", "session", Util.project_tag(project)],
       metadata: %{source: :gemini, session_id: sid, project: project}
     }}
  end

  defp fetch_sessions(base, opts) do
    tmp_dir = Path.join(base, "tmp")
    since = Keyword.get(opts, :since, %{})
    projects = Keyword.get(opts, :projects)

    if File.dir?(tmp_dir) do
      tmp_dir
      |> Path.join("*/chats/session-*.json")
      |> Path.wildcard()
      |> maybe_filter_by_projects(projects)
      |> Enum.filter(fn path ->
        case since do
          s when is_map(s) and map_size(s) > 0 ->
            since_dt = s |> Map.values() |> Enum.sort() |> Enum.at(0)
            file_newer_than?(path, since_dt)

          _ ->
            true
        end
      end)
      |> Enum.take(30)
      |> Enum.map(&parse_gemini_session/1)
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  defp maybe_filter_by_projects(paths, nil), do: paths

  defp maybe_filter_by_projects(paths, projects) when is_list(projects) do
    Enum.filter(paths, fn path ->
      parts = Path.split(path)
      slug = Enum.at(parts, -4, "")
      slug in projects
    end)
  end

  defp file_newer_than?(_path, nil), do: true

  defp file_newer_than?(path, since_str) when is_binary(since_str) do
    case DateTime.from_iso8601(since_str) do
      {:ok, dt, _} -> file_newer_than?(path, dt)
      _ -> true
    end
  end

  defp file_newer_than?(path, %DateTime{} = since_dt) do
    case File.stat(path) do
      {:ok, stat} ->
        {{y, m, d}, {h, min, s}} = stat.mtime
        {:ok, ndt} = NaiveDateTime.new(y, m, d, h, min, s)
        file_dt = DateTime.from_naive!(ndt, "Etc/UTC")
        DateTime.after?(file_dt, since_dt)

      _ ->
        true
    end
  end

  defp parse_gemini_session(path) do
    with {:ok, content} <- File.read(path),
         {:ok, data} <- Jason.decode(content) do
      messages = Map.get(data, "messages", [])

      user_prompts =
        messages
        |> Enum.filter(fn msg ->
          Map.get(msg, "type") == "user" and
            is_list(Map.get(msg, "content", []))
        end)
        |> Enum.flat_map(fn msg ->
          msg
          |> Map.get("content", [])
          |> Enum.filter(&(is_map(&1) and Map.has_key?(&1, "text")))
          |> Enum.map(& &1["text"])
          |> Enum.reject(&(&1 == "" or String.length(&1) < 10))
        end)
        |> Enum.take(20)

      project =
        case Map.get(data, "projectHash") do
          nil ->
            path
            |> Path.split()
            |> Enum.at(-4, "unknown")

          hash ->
            String.slice(hash, 0, 8)
        end

      session_id = Map.get(data, "sessionId", Path.basename(path, ".json"))

      if user_prompts != [] do
        %{agent: :gemini, source: :session, project: project, session_id: session_id, user_prompts: user_prompts}
      end
    end
  end
end
