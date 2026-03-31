defmodule Mneme.Pipeline.Ingester do
  @moduledoc """
  Ingests content into the memory system with content-hash deduplication.
  Creates or updates MemoryDocuments within a collection.
  """

  import Ecto.Query
  alias Mneme.Config
  alias Mneme.Schema.{Collection, Document}
  alias Mneme.Pipeline.Chunker

  require Logger

  @doc """
  Ingest text content as a document.

  Returns `{:ok, document}` if created/updated, `{:ok, :unchanged}` if
  content hash matches, or `{:error, reason}`.

  ## Options
  - `:owner_id` (required) — UUID owner
  - `:collection_name` — Collection name (default: "default")
  - `:source_type` — "artifact", "conversation", "manual" (default: "manual")
  - `:source_id` — External ID for dedup
  - `:metadata` — Extra data map
  """
  def ingest(title, content, opts \\ []) do
    owner_id = Keyword.fetch!(opts, :owner_id)
    collection_name = Keyword.get(opts, :collection_name, "default")
    source_type = Keyword.get(opts, :source_type, "manual")
    source_id = Keyword.get(opts, :source_id)
    metadata = Keyword.get(opts, :metadata, %{})
    repo = Config.repo()

    content_hash = hash_content(content)

    with {:ok, collection} <- ensure_collection(owner_id, collection_name, repo) do
      case find_existing(collection.id, source_type, source_id, repo) do
        nil ->
          create_document(
            collection,
            title,
            content,
            content_hash,
            source_type,
            source_id,
            owner_id,
            metadata,
            repo
          )

        existing when existing.content_hash == content_hash ->
          {:ok, :unchanged}

        existing ->
          update_document(existing, content, content_hash, repo)
      end
    end
  end

  defp ensure_collection(owner_id, name, repo) do
    query =
      from(c in Collection,
        where: c.owner_id == ^owner_id and c.name == ^name and c.collection_type == "user"
      )

    case repo.one(query) do
      nil ->
        %Collection{}
        |> Collection.changeset(%{name: name, collection_type: "user", owner_id: owner_id})
        |> repo.insert()
        |> case do
          {:ok, collection} ->
            {:ok, collection}

          {:error, _} ->
            # Race condition — another process created it
            {:ok, repo.one!(query)}
        end

      collection ->
        {:ok, collection}
    end
  end

  defp find_existing(_collection_id, _source_type, nil, _repo), do: nil

  defp find_existing(collection_id, source_type, source_id, repo) do
    from(d in Document,
      where:
        d.collection_id == ^collection_id and
          d.source_type == ^source_type and
          d.source_id == ^source_id
    )
    |> repo.one()
  end

  defp create_document(
         collection,
         title,
         content,
         content_hash,
         source_type,
         source_id,
         owner_id,
         metadata,
         repo
       ) do
    %Document{}
    |> Document.changeset(%{
      collection_id: collection.id,
      title: title,
      content: content,
      content_hash: content_hash,
      source_type: source_type,
      source_id: source_id,
      status: "pending",
      token_count: Chunker.estimate_tokens(content),
      metadata: metadata,
      owner_id: owner_id
    })
    |> repo.insert()
  end

  defp update_document(existing, content, content_hash, repo) do
    existing
    |> Document.changeset(%{
      content: content,
      content_hash: content_hash,
      status: "pending",
      token_count: Chunker.estimate_tokens(content)
    })
    |> repo.update()
  end

  @doc "Compute SHA-256 hash of content for deduplication."
  def hash_content(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end
end
