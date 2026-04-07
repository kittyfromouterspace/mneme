defmodule Mneme.LearningTest do
  use Mneme.DataCase, async: false

  describe "Mneme.Learner (behaviour)" do
    test "Git learner has correct source" do
      assert Mneme.Learner.Git.source() == :git
    end
  end

  describe "Mneme.Learner.Git.extract/1" do
    test "extracts commit into memory format" do
      commit = %{
        sha: "abc123",
        subject: "fix: resolve bug",
        body: "This fixes the bug",
        author: "john@example",
        branch: "main"
      }

      {:ok, extract} = Mneme.Learner.Git.extract(commit)

      assert extract.content =~ "fix: resolve bug"
      assert extract.entry_type == :observation
      assert extract.emotional_valence == :negative
      assert "git" in extract.tags
      assert extract.metadata.commit_sha == "abc123"
    end

    test "extracts feature commit" do
      commit = %{
        sha: "def456",
        subject: "feat: add new feature",
        body: "",
        author: "jane@example",
        branch: "main"
      }

      {:ok, extract} = Mneme.Learner.Git.extract(commit)

      assert extract.entry_type == :note
      assert extract.emotional_valence == :positive
    end

    test "extracts breaking change" do
      commit = %{
        sha: "ghi789",
        subject: "BREAKING: change API",
        body: "",
        author: "dev@example",
        branch: "main"
      }

      {:ok, extract} = Mneme.Learner.Git.extract(commit)

      assert extract.emotional_valence == :negative
    end
  end

  describe "Mneme.Learner.Git.detect_patterns/1" do
    test "detects migration patterns" do
      commits = [
        %{subject: "migrate from webpack to vite", sha: "1"},
        %{subject: "migrate from webpack to vite", sha: "2"}
      ]

      patterns = Mneme.Learner.Git.detect_patterns(commits)

      assert is_list(patterns)
    end
  end

  describe "Mneme.Learning.Pipeline" do
    test "enabled_learners returns configured learners" do
      learners = Mneme.Learning.Pipeline.enabled_learners()
      assert is_list(learners)
      assert Mneme.Learner.Git in learners
    end

    test "enabled? returns boolean" do
      assert is_boolean(Mneme.Learning.Pipeline.enabled?())
    end

    test "run with dry_run returns preview" do
      scope_id = Fixtures.scope_id()

      result = Mneme.Learning.Pipeline.run(scope_id: scope_id, dry_run: true)

      assert is_tuple(result)
    end

    test "run with scope_id and sources works" do
      scope_id = Fixtures.scope_id()

      result =
        Mneme.Learning.Pipeline.run(
          scope_id: scope_id,
          sources: [Mneme.Learner.Git],
          since: "7 days ago"
        )

      assert {:ok, %{results: _}} = result
    end
  end
end
