defmodule Mneme.SearchTest do
  use Mneme.DataCase, async: false

  alias Mneme.Config
  alias Mneme.Schema.Entry

  describe "search API" do
    test "search returns context pack structure" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      Fixtures.entry(scope_id: scope_id, owner_id: owner_id, content: "Test entry")

      {:ok, context} = Mneme.search("query", scope_id: scope_id, owner_id: owner_id)

      assert is_map(context)
      assert Map.has_key?(context, :chunks)
      assert Map.has_key?(context, :entries)
      assert Map.has_key?(context, :related_entries)
      assert Map.has_key?(context, :entities)
      assert Map.has_key?(context, :relations)
      assert Map.has_key?(context, :query)
    end

    test "search accepts tier option" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      Fixtures.entry(scope_id: scope_id, owner_id: owner_id, content: "Test entry")

      {:ok, context} =
        Mneme.search("query", scope_id: scope_id, owner_id: owner_id, tier: :lightweight)

      assert context.chunks == []
      assert is_list(context.entries)
    end

    test "search_vectors returns list of results" do
      scope_id = Fixtures.scope_id()

      Fixtures.entry(scope_id: scope_id, content: "Test content")

      {:ok, results} = Mneme.search_vectors("query", scope_id: scope_id)
      assert is_list(results)
    end
  end

  describe "access tracking" do
    test "forget removes entry from database" do
      entry = Fixtures.entry()

      assert Config.repo().get(Entry, entry.id)

      {:ok, _} = Mneme.forget(entry.id)

      assert Config.repo().get(Entry, entry.id) == nil
    end
  end
end
