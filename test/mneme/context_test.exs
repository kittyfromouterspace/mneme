defmodule Mneme.ContextTest do
  use ExUnit.Case, async: true

  alias Mneme.Context.Detector
  alias Mneme.Search.ContextBooster

  describe "Detector.detect/0" do
    test "returns a map with detected context keys" do
      context = Detector.detect()

      assert is_map(context)
    end

    test "includes path_prefix when PWD is set" do
      context = Detector.detect()

      # When run in test, PWD should be set
      assert Map.has_key?(context, :path_prefix)
    end

    test "includes repo when in a git directory" do
      context = Detector.detect()

      # Should detect git repo in test environment
      assert Map.has_key?(context, :repo)
    end
  end

  describe "Detector.detect_os/0" do
    test "returns only OS context" do
      context = Detector.detect_os()

      # OS detection should always work
      assert Map.has_key?(context, :os)
    end
  end

  describe "Detector.detect_path/0" do
    test "returns only path context" do
      context = Detector.detect_path()

      assert Map.has_key?(context, :path_prefix)
    end
  end

  describe "Detector.context_matches/2" do
    test "returns 0 for empty hints" do
      matches = Detector.context_matches(%{}, %{os: "linux"})
      assert matches == 0
    end

    test "returns 0 for empty current context" do
      matches = Detector.context_matches(%{os: "linux"}, %{})
      assert matches == 0
    end

    test "returns count of matching keys" do
      hints = %{os: "linux", repo: "test/repo"}
      current = %{os: "linux", repo: "test/repo", path_prefix: "/home"}

      matches = Detector.context_matches(hints, current)
      assert matches == 2
    end

    test "returns 0 for no matches" do
      hints = %{os: "linux"}
      current = %{os: "darwin"}

      matches = Detector.context_matches(hints, current)
      assert matches == 0
    end
  end

  describe "Booster.boost/2" do
    test "returns 0 for empty entry hints" do
      boost = ContextBooster.boost(%{}, %{os: "linux"})
      assert boost == 0.0
    end

    test "returns 0 for empty current context" do
      boost = ContextBooster.boost(%{os: "linux"}, %{})
      assert boost == 0.0
    end

    test "returns boost for matching context" do
      hints = %{os: "linux", repo: "test/repo"}
      current = %{os: "linux", repo: "test/repo"}

      boost = ContextBooster.boost(hints, current)
      assert boost > 0.0
      assert boost <= 0.5
    end

    test "caps boost at max value" do
      # Many matches should cap at max boost
      hints = %{os: "linux", repo: "a", path_prefix: "b", something: "c"}
      current = %{os: "linux", repo: "a", path_prefix: "b", something: "c"}

      boost = ContextBooster.boost(hints, current)
      assert boost == 0.5
    end
  end

  describe "Booster.apply_boost/2" do
    test "applies boost to results" do
      results = [
        %{content: "Entry 1", context_hints: %{os: "linux"}},
        %{content: "Entry 2", context_hints: %{os: "darwin"}}
      ]

      current = %{os: "linux"}

      boosted = ContextBooster.apply_boost(results, current)

      assert length(boosted) == 2
      # First entry matches OS, should have boost
      assert hd(boosted)[:score] >= 0.15
    end

    test "sorts results by boosted score" do
      results = [
        %{content: "No match", context_hints: %{}},
        %{content: "Match", context_hints: %{os: "linux"}}
      ]

      current = %{os: "linux"}

      boosted = ContextBooster.apply_boost(results, current)

      assert hd(boosted)[:content] == "Match"
    end
  end
end
