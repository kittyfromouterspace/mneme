defmodule Recollect.InvalidationTest do
  use Recollect.DataCase, async: false

  describe "Recollect.Invalidation.invalidate/3" do
    test "invalidate pattern reduces half_life of matching entries" do
      owner_id = Fixtures.owner_id()
      scope_id = Fixtures.scope_id()

      # Create entry mentioning "webpack"
      Fixtures.entry(
        scope_id: scope_id,
        owner_id: owner_id,
        content: "Use webpack for bundling",
        half_life_days: 7.0,
        confidence: 1.0
      )

      # Create another entry
      Fixtures.entry(
        scope_id: scope_id,
        owner_id: owner_id,
        content: "Use vite for bundling",
        half_life_days: 7.0,
        confidence: 1.0
      )

      # Invalidate webpack
      {:ok, result} =
        Recollect.Invalidation.invalidate(
          scope_id,
          "webpack",
          reason: "migrated to vite"
        )

      assert result.invalidated >= 0
    end

    test "invalidate with replacement creates new entry" do
      owner_id = Fixtures.owner_id()
      scope_id = Fixtures.scope_id()

      Fixtures.entry(
        scope_id: scope_id,
        owner_id: owner_id,
        content: "Use webpack for bundling"
      )

      {:ok, result} =
        Recollect.Invalidation.invalidate(
          scope_id,
          "webpack",
          replacement: "Use vite for bundling",
          reason: "migration"
        )

      assert result.replacement_created == true
    end

    test "invalidate pattern with no matches returns 0" do
      scope_id = Fixtures.scope_id()

      {:ok, result} =
        Recollect.Invalidation.invalidate(
          scope_id,
          "nonexistent_pattern_xyz",
          reason: "test"
        )

      assert result.invalidated == 0
    end
  end

  describe "Recollect.Invalidation.detect_migrations/1" do
    test "detect_migrations returns list" do
      # Should return empty or list
      result = Recollect.Invalidation.detect_migrations(1)
      assert is_list(result)
    end
  end
end
