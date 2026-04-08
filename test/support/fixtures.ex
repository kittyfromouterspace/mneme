defmodule Mneme.Fixtures do
  @moduledoc """
  Test fixtures for creating test data.
  """

  alias Mneme.Config
  alias Mneme.Schema.Chunk
  alias Mneme.Schema.Collection
  alias Mneme.Schema.Document
  alias Mneme.Schema.Edge
  alias Mneme.Schema.Entity
  alias Mneme.Schema.Entry

  def owner_id, do: Ecto.UUID.generate()
  def scope_id, do: Ecto.UUID.generate()

  def collection(attrs \\ []) do
    attrs = Map.merge(default_collection_attrs(), Map.new(attrs))

    {:ok, collection} =
      %Collection{}
      |> Collection.changeset(attrs)
      |> Config.repo().insert()

    collection
  end

  def document(attrs \\ []) do
    coll =
      attrs[:collection] ||
        collection(owner_id: attrs[:owner_id], scope_id: attrs[:scope_id])

    attrs =
      attrs
      |> Keyword.delete(:collection)
      |> Map.new()
      |> Map.put(:collection_id, coll.id)

    {:ok, document} =
      %Document{}
      |> Document.changeset(attrs)
      |> Config.repo().insert()

    document
  end

  def entry(attrs \\ []) do
    attrs = Map.merge(default_entry_attrs(), Map.new(attrs))

    {:ok, entry} =
      %Entry{}
      |> Entry.changeset(attrs)
      |> Config.repo().insert()

    entry
  end

  def connected_entries(attrs \\ []) do
    entry1 = entry(attrs)
    entry2 = entry(attrs)

    {:ok, edge} =
      %Edge{}
      |> Edge.changeset(%{
        source_entry_id: entry1.id,
        target_entry_id: entry2.id,
        relation: "supports"
      })
      |> Config.repo().insert()

    {entry1, entry2, edge}
  end

  def chunk(attrs \\ []) do
    doc =
      attrs[:document] ||
        document(owner_id: attrs[:owner_id], scope_id: attrs[:scope_id])

    attrs =
      attrs
      |> Keyword.delete(:document)
      |> Map.new()
      |> Map.put(:document_id, doc.id)

    {:ok, chunk} =
      %Chunk{}
      |> Chunk.changeset(attrs)
      |> Config.repo().insert()

    chunk
  end

  def entity(attrs \\ []) do
    coll =
      attrs[:collection] ||
        collection(owner_id: attrs[:owner_id], scope_id: attrs[:scope_id])

    attrs =
      default_entity_attrs()
      |> Map.merge(Map.new(attrs))
      |> Map.delete(:collection)
      |> Map.put(:collection_id, coll.id)

    {:ok, entity} =
      %Entity{}
      |> Entity.changeset(attrs)
      |> Config.repo().insert()

    entity
  end

  defp default_collection_attrs do
    %{
      name: "test-collection",
      collection_type: "user",
      owner_id: owner_id(),
      scope_id: scope_id()
    }
  end

  defp default_entry_attrs do
    %{
      content: "Test entry content",
      entry_type: "note",
      scope_id: scope_id(),
      owner_id: owner_id(),
      source: "system"
    }
  end

  defp default_entity_attrs do
    %{
      name: "Test Entity",
      entity_type: "concept",
      owner_id: owner_id(),
      scope_id: scope_id()
    }
  end
end
