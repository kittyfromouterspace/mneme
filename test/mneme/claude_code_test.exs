defmodule Mneme.ClaudeCodeProviderTest do
  use ExUnit.Case, async: true

  alias Mneme.Learner.CodingAgent.ClaudeCode, as: Provider

  describe "source/0" do
    test "returns :claude_code" do
      assert Provider.agent_name() == :claude_code
    end
  end

  describe "extract/1 — memory files" do
    test "extracts project memory with frontmatter" do
      event = %{
        source: :memory_file,
        project: "-home-lenz-code-worth",
        path: "/fake/project_ui_redesign.md",
        filename: "project_ui_redesign.md",
        content: "",
        frontmatter: %{
          "name" => "Phoenix LiveView migration",
          "description" => "Worth migrated from TUI to LiveView",
          "type" => "project"
        },
        body: "The web UI lives in lib/worth_web/.",
        memory_type: "project"
      }

      {:ok, extract} = Provider.extract(event)

      assert extract.content =~ "Phoenix LiveView migration"
      assert extract.content =~ "The web UI lives in lib/worth_web/"
      assert extract.entry_type == :development_insight
      assert extract.emotional_valence == :neutral
      assert extract.half_life_days == 45.0
      assert extract.confidence == 0.95
      assert "claude" in extract.tags
      assert "memory" in extract.tags
      assert "type:project" in extract.tags
    end

    test "extracts feedback memory with negative valence" do
      event = %{
        source: :memory_file,
        project: "-home-lenz-code-ops_center",
        path: "/fake/feedback_no_manual_deploy.md",
        filename: "feedback_no_manual_deploy.md",
        content: "",
        frontmatter: %{
          "name" => "No manual deploys",
          "description" => "Never manually deploy code",
          "type" => "feedback"
        },
        body: "NEVER use manual commands to deploy code.",
        memory_type: "feedback"
      }

      {:ok, extract} = Provider.extract(event)

      assert extract.entry_type == :decision
      assert extract.emotional_valence == :negative
      assert extract.half_life_days == 60.0
    end

    test "extracts user preference memory" do
      event = %{
        source: :memory_file,
        project: "-home-lenz-code-worth",
        path: "/fake/user_python_ansible.md",
        filename: "user_python_ansible.md",
        content: "",
        frontmatter: %{
          "name" => "Python and Ansible preference",
          "type" => "user"
        },
        body: "Use Python for scripting and Ansible for config.",
        memory_type: "user"
      }

      {:ok, extract} = Provider.extract(event)

      assert extract.entry_type == :preference
      assert extract.emotional_valence == :positive
      assert extract.half_life_days == 90.0
    end
  end

  describe "extract/1 — CLAUDE.md" do
    test "extracts project instructions" do
      event = %{
        source: :claude_md,
        project: "-home-lenz-code-worth",
        content: "This is a Phoenix LiveView project.\nUse Tailwind for styling."
      }

      {:ok, extract} = Provider.extract(event)

      assert extract.content =~ "Phoenix LiveView project"
      assert extract.entry_type == :decision
      assert extract.emotional_valence == :neutral
      assert extract.half_life_days == 30.0
      assert "project_instructions" in extract.tags
    end
  end

  describe "extract/1 — session summaries" do
    test "extracts session with user prompts" do
      event = %{
        source: :session,
        project: "-home-lenz-code-worth",
        session_id: "29eac91a-2963-4cad-a6e1-c1116eedc6f0",
        user_prompts: [
          "Fix the page loading error",
          "The pub/sub messaging is not showing responses",
          "Can we have streaming messages?"
        ]
      }

      {:ok, extract} = Provider.extract(event)

      assert extract.content =~ "Fix the page loading error"
      assert extract.entry_type == :note
      assert "claude" in extract.tags
      assert "session" in extract.tags
    end

    test "skips session with no prompts" do
      event = %{
        source: :session,
        project: "-home-lenz-code-worth",
        session_id: "empty-session-id",
        user_prompts: []
      }

      assert {:skip, _} = Provider.extract(event)
    end
  end

  describe "summarize/2" do
    test "groups session summaries into development_insight" do
      events = [
        %{
          source: :session,
          project: "-home-lenz-code-worth",
          session_id: "session-1",
          user_prompts: ["Fix auth bug", "Add OAuth2"]
        },
        %{
          source: :session,
          project: "-home-lenz-code-worth",
          session_id: "session-2",
          user_prompts: ["Implement streaming"]
        },
        %{
          source: :memory_file,
          project: "-home-lenz-code-worth",
          memory_type: "project"
        }
      ]

      insights = Provider.summarize(events, "fake-scope-id")

      assert length(insights) == 1

      insight = hd(insights)
      assert insight.entry_type == :development_insight
      assert insight.content =~ "2 sessions"
      assert insight.content =~ "3 prompts"
      assert insight.half_life_days == 21.0
    end

    test "returns empty when no session events" do
      events = [
        %{source: :memory_file, project: "x", memory_type: "project"}
      ]

      insights = Provider.summarize(events, "fake-scope-id")

      assert insights == []
    end
  end

  describe "frontmatter parsing" do
    test "parses YAML frontmatter from markdown" do
      content = """
      ---
      name: Town art direction
      description: Visual design decisions for the hex map
      type: project
      ---

      The hex map uses a medieval town metaphor.
      """

      {fm, body} = parse_frontmatter(content)

      assert fm["name"] == "Town art direction"
      assert fm["description"] == "Visual design decisions for the hex map"
      assert fm["type"] == "project"
      assert body =~ "medieval town metaphor"
    end

    test "handles content without frontmatter" do
      content = "Just a plain note without frontmatter."

      {fm, body} = parse_frontmatter(content)

      assert fm == %{}
      assert body == "Just a plain note without frontmatter."
    end

    test "handles quoted values" do
      content = """
      ---
      name: "Quoted Name"
      description: 'Single quoted'
      ---
      Body text.
      """

      {fm, body} = parse_frontmatter(content)

      assert fm["name"] == "Quoted Name"
      assert fm["description"] == "Single quoted"
      assert body == "Body text."
    end
  end

  describe "detect_memory_type/1" do
    test "detects project type" do
      event = %{filename: "project_ui_redesign.md"}
      assert detect_memory_type(event.filename) == "project"
    end

    test "detects feedback type" do
      assert detect_memory_type("feedback_no_manual_deploy.md") == "feedback"
    end

    test "detects user type" do
      assert detect_memory_type("user_python_ansible.md") == "user"
    end

    test "detects human type" do
      assert detect_memory_type("human_agency_training.md") == "human"
    end

    test "defaults to project" do
      assert detect_memory_type("something_else.md") == "project"
    end
  end

  defp parse_frontmatter(content) do
    case String.split(content, "---", parts: 3) do
      ["", yaml_str, body] ->
        frontmatter =
          yaml_str
          |> String.trim()
          |> String.split("\n")
          |> Enum.map(&parse_yaml_line/1)
          |> Enum.reject(&is_nil/1)
          |> Map.new()

        {frontmatter, String.trim(body)}

      _ ->
        {%{}, String.trim(content)}
    end
  end

  defp parse_yaml_line(line) do
    case Regex.run(~r/^(\w[\w\s]*):\s*(.+)$/, String.trim(line)) do
      [_, key, value] ->
        v = String.trim(value)

        unquoted =
          cond do
            String.starts_with?(v, "\"") and String.ends_with?(v, "\"") ->
              String.slice(v, 1..-2//1)

            String.starts_with?(v, "'") and String.ends_with?(v, "'") ->
              String.slice(v, 1..-2//1)

            true ->
              v
          end

        {String.trim(key), unquoted}

      _ ->
        nil
    end
  end

  defp detect_memory_type(filename) do
    name = String.downcase(filename)

    cond do
      String.starts_with?(name, "project_") -> "project"
      String.starts_with?(name, "feedback_") -> "feedback"
      String.starts_with?(name, "user_") -> "user"
      String.starts_with?(name, "human_") -> "human"
      true -> "project"
    end
  end
end
