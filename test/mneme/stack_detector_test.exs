defmodule Mneme.StackDetectorTest do
  use ExUnit.Case, async: true

  alias Mneme.Learner.Git.StackDetector

  describe "detect_transitions_from_commits/1" do
    test "detects webpack to vite migration from commit subjects" do
      commits = [
        %{sha: "a1", subject: "migrate from webpack to vite", body: "", author: "dev", branch: "main"},
        %{sha: "a2", subject: "remove webpack config files", body: "", author: "dev", branch: "main"},
        %{sha: "a3", subject: "add vite config", body: "", author: "dev", branch: "main"}
      ]

      transitions = StackDetector.detect_transitions_from_commits(commits)

      transition = Enum.find(transitions, &(&1.from == "webpack" and &1.to == "vite"))

      assert transition
      assert transition.type == :deprecation
      assert transition.category == :build_tool
    end

    test "detects jest to vitest transition" do
      commits = [
        %{sha: "b1", subject: "replace jest with vitest", body: "", author: "dev", branch: "main"}
      ]

      transitions = StackDetector.detect_transitions_from_commits(commits)

      transition = Enum.find(transitions, &(&1.from == "jest" and &1.to == "vitest"))

      assert transition
      assert transition.category == :test_framework
    end

    test "detects babel to esbuild transition" do
      commits = [
        %{sha: "c1", subject: "switch from babel to esbuild", body: "", author: "dev", branch: "main"}
      ]

      transitions = StackDetector.detect_transitions_from_commits(commits)

      transition = Enum.find(transitions, &(&1.from == "babel" and &1.to == "esbuild"))

      assert transition
      assert transition.category == :transpiler
    end

    test "returns empty when no transitions detected" do
      commits = [
        %{sha: "d1", subject: "fix: resolve timeout issue", body: "", author: "dev", branch: "main"},
        %{sha: "d2", subject: "feat: add dark mode", body: "", author: "dev", branch: "main"}
      ]

      transitions = StackDetector.detect_transitions_from_commits(commits)

      assert transitions == []
    end

    test "deduplicates transitions" do
      commits = [
        %{sha: "e1", subject: "migrate from webpack to vite", body: "", author: "dev", branch: "main"},
        %{sha: "e2", subject: "migrate from webpack to vite step 2", body: "", author: "dev", branch: "main"}
      ]

      transitions = StackDetector.detect_transitions_from_commits(commits)

      webpack_to_vite = Enum.filter(transitions, &(&1.from == "webpack" and &1.to == "vite"))
      assert length(webpack_to_vite) == 1
    end

    test "ignores non-transition commits mentioning technologies" do
      commits = [
        %{sha: "f1", subject: "fix: webpack build error", body: "", author: "dev", branch: "main"},
        %{sha: "f2", subject: "feat: add vite plugin", body: "", author: "dev", branch: "main"}
      ]

      transitions = StackDetector.detect_transitions_from_commits(commits)

      refute Enum.any?(transitions, &(&1.from == "webpack" and &1.to == "vite"))
    end
  end

  describe "category_transitions coverage" do
    test "knows all standard build_tool transitions" do
      known = StackDetector.known_transition?("webpack", "vite")
      assert known
    end

    test "knows test_framework transitions" do
      known = StackDetector.known_transition?("jest", "vitest")
      assert known
    end

    test "knows css_framework transitions" do
      known = StackDetector.known_transition?("sass", "tailwind")
      assert known
    end

    test "rejects unknown transitions" do
      known = StackDetector.known_transition?("react", "postgres")
      refute known
    end

    test "rejects same-technology" do
      known = StackDetector.known_transition?("webpack", "webpack")
      refute known
    end
  end
end
