defmodule Mneme.HandoffTest do
  use ExUnit.Case, async: true

  describe "Mneme.Mipmap.generate_for/1" do
    test "generates all mipmap levels" do
      entry = %{
        id: "test-id",
        content: "This is a test entry with some content for mipmapping",
        entry_type: "note",
        tags: ["test", "mipmap"],
        emotional_valence: "neutral"
      }

      mipmaps = Mneme.Mipmap.generate_for(entry)

      assert Map.has_key?(mipmaps, :entry_id)
      assert Map.has_key?(mipmaps, :full)
      assert Map.has_key?(mipmaps, :summary)
      assert Map.has_key?(mipmaps, :abstract)
      assert Map.has_key?(mipmaps, :anchor)
    end
  end
end
