defmodule Recollect.Learner.OpenCode do
  @moduledoc """
  Learn from OpenCode conversations and projects.

  Detects:
  - Conversations with AI assistants
  - Decisions and implementations
  - Project context
  - Tool usage patterns

  ## Usage

      {:ok, result} = Recollect.Learner.OpenCode.run(scope_id: scope_id)
  """

  @behaviour Recollect.Learner

  alias Recollect.Telemetry

  @impl true
  def source, do: :opencode

  @impl true
  def fetch_since(_since, scope_id) do
    start_time = System.monotonic_time()

    paths = [
      Path.expand("~/.opencode"),
      Path.expand("~/Library/Application Support/opencode"),
      Path.expand("~/.config/opencode")
    ]

    conversations =
      paths
      |> Enum.find(fn p -> File.exists?(p) end)
      |> case do
        nil -> []
        path -> fetch_conversations(path)
      end

    duration =
      System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

    Telemetry.event(
      [:recollect, :learn, :opencode, :fetch, :stop],
      %{
        duration_ms: duration,
        sessions_found: length(conversations)
      },
      %{scope_id: scope_id}
    )

    {:ok, conversations}
  end

  @impl true
  def extract(conversation) do
    content = build_content(conversation)
    type = detect_type(conversation)
    valence = detect_valence(conversation)
    tags = build_tags(conversation)

    {:ok,
     %{
       content: content,
       entry_type: type,
       emotional_valence: valence,
       tags: tags,
       metadata: %{
         source: :opencode,
         session_id: conversation.session_id,
         timestamp: conversation.timestamp,
         project: conversation.project
       }
     }}
  end

  @doc "Run the full OpenCode learning pipeline for a scope."
  def run(opts \\ []) do
    scope_id = Keyword.get(opts, :scope_id)
    start_time = System.monotonic_time()

    with {:ok, conversations} <- fetch_since("1970-01-01", scope_id) do
      results = Enum.map(conversations, &process_conversation/1)

      learned_count = Enum.count(results, &match?({:ok, _}, &1))
      skipped_count = Enum.count(results, &match?({:skip, _}, &1))

      duration =
        System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

      Telemetry.event(
        [:recollect, :learn, :opencode, :stop],
        %{
          duration_ms: duration,
          fetched: length(conversations),
          learned: learned_count,
          skipped: skipped_count
        },
        %{scope_id: scope_id}
      )

      {:ok,
       %{
         fetched: length(conversations),
         learned: learned_count,
         skipped: skipped_count
       }}
    end
  end

  @impl true
  def detect_patterns(_conversations), do: []

  defp fetch_conversations(base_path) do
    # OpenCode stores sessions/conversations
    sessions_path = Path.join(base_path, "sessions")

    if File.exists?(sessions_path) do
      fetch_sessions(sessions_path)
    else
      # Try alternative locations
      fetch_alternative_conversations(base_path)
    end
  end

  defp fetch_sessions(sessions_path) do
    case File.ls(sessions_path) do
      {:ok, sessions} ->
        sessions
        |> Enum.map(&Path.join(sessions_path, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.map(&extract_session/1)
        |> Enum.reject(&is_nil/1)
        # Limit to recent 50
        |> Enum.take(50)

      _ ->
        []
    end
  end

  defp extract_session(session_path) do
    session_id = Path.basename(session_path)

    # Look for conversation files
    conversation_file = Path.join(session_path, "conversation.json")
    transcript_file = Path.join(session_path, "transcript.md")

    content =
      if File.exists?(conversation_file) do
        read_json_content(conversation_file)
      else
        if File.exists?(transcript_file) do
          read_file_content(transcript_file)
        else
          # Try to read any markdown/json files
          case File.ls(session_path) do
            {:ok, files} ->
              files
              |> Enum.filter(fn f -> String.ends_with?(f, [".md", ".json"]) end)
              |> Enum.map(fn f -> Path.join(session_path, f) end)
              |> Enum.find(&File.regular?/1)
              |> case do
                nil -> ""
                path -> read_file_content(path)
              end

            _ ->
              ""
          end
        end
      end

    if content != "" do
      project = extract_project_from_session(session_path)

      # Get timestamp
      timestamp =
        case File.stat(session_path) do
          {:ok, stat} -> stat.mtime
          _ -> DateTime.utc_now()
        end

      %{
        session_id: session_id,
        content: content,
        project: project,
        timestamp: timestamp
      }
    end
  end

  defp fetch_alternative_conversations(base_path) do
    # Check for other possible locations
    alt_paths = [
      Path.join(base_path, "history"),
      Path.join(base_path, "chats"),
      Path.join(base_path, "conversations")
    ]

    alt_paths
    |> Enum.find(fn p -> File.exists?(p) end)
    |> case do
      nil -> []
      path -> fetch_generic_conversations(path)
    end
  end

  defp fetch_generic_conversations(path) do
    case File.ls(path) do
      {:ok, files} ->
        files
        |> Enum.filter(fn f -> String.ends_with?(f, [".json", ".md", ".txt"]) end)
        |> Enum.take(20)
        |> Enum.map(fn f ->
          full_path = Path.join(path, f)
          content = read_file_content(full_path)

          %{
            session_id: Path.basename(f, Path.extname(f)),
            content: content,
            project: "unknown",
            timestamp: DateTime.utc_now()
          }
        end)

      _ ->
        []
    end
  end

  defp read_json_content(path) do
    case File.read(path) do
      {:ok, content} ->
        # Try to parse and extract messages
        case Jason.decode(content) do
          {:ok, data} -> extract_messages_from_json(data)
          _ -> content
        end

      _ ->
        ""
    end
  end

  defp extract_messages_from_json(data) when is_map(data) do
    # Handle different JSON structures
    messages =
      data["messages"] || data["conversation"] || data["items"] || []

    Enum.map_join(messages, "\n", &extract_message_text/1)
  end

  defp extract_messages_from_json(_), do: ""

  defp extract_message_text(msg) when is_map(msg) do
    content = msg["content"] || msg["message"] || msg["text"] || ""
    role = msg["role"] || msg["type"] || "unknown"

    "[#{role}] #{content}"
  end

  defp extract_message_text(_), do: ""

  defp read_file_content(path) do
    case File.read(path) do
      # Limit content size
      {:ok, content} -> String.slice(content, 0, 8000)
      _ -> ""
    end
  end

  defp extract_project_from_session(session_path) do
    # Try to find project name from session path or files
    case File.ls(session_path) do
      {:ok, files} ->
        # Look for project identifier
        files
        |> Enum.find(fn f -> String.contains?(f, "project") || String.contains?(f, "context") end)
        |> case do
          nil ->
            # Use parent directory name as project
            Path.basename(Path.dirname(session_path))

          f ->
            Path.basename(f, Path.extname(f))
        end

      _ ->
        "unknown"
    end
  end

  defp build_content(conversation) do
    # Summarize conversation for storage
    lines = String.split(conversation.content, "\n")

    # Take first N non-empty lines as summary
    summary =
      lines
      |> Enum.reject(fn l -> String.trim(l) == "" end)
      |> Enum.take(30)
      |> Enum.join("\n")

    "OpenCode session: #{conversation.session_id}\nProject: #{conversation.project}\n\n#{summary}"
  end

  defp detect_type(conversation) do
    content = String.downcase(conversation.content)

    cond do
      String.contains?(content, ["decided", "chose", "going with", "let's use"]) -> :decision
      String.contains?(content, ["created", "implemented", "built", "added"]) -> :note
      String.contains?(content, ["error", "bug", "failed", "broken"]) -> :observation
      true -> :note
    end
  end

  defp detect_valence(conversation) do
    content = String.downcase(conversation.content)

    cond do
      String.contains?(content, ["error", "fail", "broken", "bug", "issue"]) -> :negative
      String.contains?(content, ["success", "works", "fixed", "solved"]) -> :positive
      true -> :neutral
    end
  end

  defp build_tags(conversation) do
    base_tags = ["opencode", "session"]

    if conversation.project && conversation.project != "unknown" do
      ["project:#{conversation.project}" | base_tags]
    else
      base_tags
    end
  end

  defp process_conversation(conversation) do
    {:ok, extract} = extract(conversation)

    Recollect.remember(extract.content,
      entry_type: extract.entry_type,
      emotional_valence: extract.emotional_valence,
      tags: extract.tags,
      metadata: extract.metadata,
      source: "system"
    )
  end
end
