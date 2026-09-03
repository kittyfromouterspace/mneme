defmodule Recollect.SearchTierTest do
  use Recollect.DataCase, async: false

  alias Recollect.Search

  describe "resolve_tier/1" do
    test "short factual queries route to :lightweight" do
      assert Search.resolve_tier("deploy script") == :lightweight
      assert Search.resolve_tier("where is the runbook stored?") == :lightweight
      assert Search.resolve_tier("one two three four five six") == :lightweight
    end

    test "diagnostic words route to :both, case-insensitive" do
      assert Search.resolve_tier("why is the deploy failing") == :both
      assert Search.resolve_tier("how does auth work") == :both
      assert Search.resolve_tier("debug this") == :both
      assert Search.resolve_tier("WHY did it break") == :both
      assert Search.resolve_tier("what caused the outage") == :both
      assert Search.resolve_tier("the daemon keeps failing") == :both
      assert Search.resolve_tier("search depends on meilisearch") == :both
    end

    test "diagnostic words win over short length" do
      assert Search.resolve_tier("why") == :both
      assert Search.resolve_tier("is it broken") == :both
    end

    test "long queries route to :both" do
      long = "tell me about the relationship between the parser and the index builder component"
      assert Search.resolve_tier(long) == :both
    end

    test "mid-length non-diagnostic queries route to :both" do
      assert Search.resolve_tier("one two three four five six seven eight") == :both
      assert Search.resolve_tier("notes about the deploy pipeline structure today") == :both
    end

    test "word-boundary matching: 'however' is not 'how'" do
      assert Search.resolve_tier("however the deploy script seems to work fine") == :both
    end

    test "non-binary input falls back to :both" do
      assert Search.resolve_tier(nil) == :both
    end
  end

  describe "search/2 with tier: :auto" do
    test "context pack carries the resolved tier" do
      scope_id = Fixtures.scope_id()
      owner_id = Fixtures.owner_id()

      Fixtures.entry(scope_id: scope_id, owner_id: owner_id, content: "Test entry")

      {:ok, pack} = Recollect.search("why is this failing", scope_id: scope_id, tier: :auto)
      assert pack.resolved_tier == :both

      {:ok, pack} = Recollect.search("deploy script", scope_id: scope_id, tier: :auto)
      assert pack.resolved_tier == :lightweight

      {:ok, pack} = Recollect.search("query", scope_id: scope_id, tier: :full)
      assert pack.resolved_tier == :full

      {:ok, pack} = Recollect.search("query", scope_id: scope_id)
      assert pack.resolved_tier == :both
    end
  end
end
