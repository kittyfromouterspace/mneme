defmodule Recollect.MipmapTest do
  use ExUnit.Case, async: true

  describe "Recollect.Mipmap.generate_for/1" do
    test "generates all mipmap levels" do
      entry = %{
        id: "test-id",
        content: "This is a test entry with some content for mipmapping",
        entry_type: "note",
        tags: ["test", "mipmap"],
        emotional_valence: "neutral"
      }

      mipmaps = Recollect.Mipmap.generate_for(entry)

      assert Map.has_key?(mipmaps, :entry_id)
      assert Map.has_key?(mipmaps, :full)
      assert Map.has_key?(mipmaps, :summary)
      assert Map.has_key?(mipmaps, :abstract)
      assert Map.has_key?(mipmaps, :anchor)
    end

    test "full contains complete content" do
      entry = %{
        id: "test",
        content: "Full content here",
        entry_type: "note",
        tags: [],
        emotional_valence: "neutral"
      }

      mipmaps = Recollect.Mipmap.generate_for(entry)

      assert mipmaps.full.content == "Full content here"
    end

    test "summary truncates content" do
      long_content = String.duplicate("test content ", 50)

      entry = %{
        id: "test",
        content: long_content,
        entry_type: "note",
        tags: [],
        emotional_valence: "neutral"
      }

      mipmaps = Recollect.Mipmap.generate_for(entry)

      assert String.length(mipmaps.summary.content) <= 200
    end

    test "abstract uses first line" do
      entry = %{
        id: "test",
        content: "First line\nSecond line\nThird line",
        entry_type: "note",
        tags: [],
        emotional_valence: "neutral"
      }

      mipmaps = Recollect.Mipmap.generate_for(entry)

      assert mipmaps.abstract.content == "First line"
    end

    test "anchor extracts key term" do
      entry = %{
        id: "test",
        content: "Important keyword in content",
        entry_type: "note",
        tags: [],
        emotional_valence: "neutral"
      }

      mipmaps = Recollect.Mipmap.generate_for(entry)

      assert mipmaps.anchor.content == "Important"
    end
  end

  describe "Recollect.Mipmap.determine_level/1" do
    test "returns abstract for short queries" do
      assert Recollect.Mipmap.determine_level("auth") == :abstract
    end

    test "returns summary for medium queries" do
      query = String.duplicate("a", 100)
      assert Recollect.Mipmap.determine_level(query) == :summary
    end

    test "returns full for long queries" do
      query = String.duplicate("a", 250)
      assert Recollect.Mipmap.determine_level(query) == :full
    end
  end

  describe "Recollect.Mipmap.levels/0" do
    test "returns all levels" do
      assert Recollect.Mipmap.levels() == [:anchor, :abstract, :summary, :full]
    end
  end
end
