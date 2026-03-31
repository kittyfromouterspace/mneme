defmodule Mneme.Pipeline.Embedder do
  @moduledoc """
  Embeds chunks and entities using the configured embedding provider.
  Supports batch processing and async embedding via TaskSupervisor.
  """

  alias Mneme.{Config, EmbeddingProvider}
  alias Mneme.Schema.Entity

  require Logger

  @doc """
  Embed a list of chunks. Updates embedding column via direct SQL.

  Returns `{:ok, chunks}` with embeddings populated.
  """
  def embed_chunks(chunks) when is_list(chunks) do
    texts = Enum.map(chunks, & &1.content)

    case EmbeddingProvider.generate(texts) do
      {:ok, embeddings} ->
        repo = Config.repo()

        updated =
          Enum.zip(chunks, embeddings)
          |> Enum.map(fn {chunk, embedding} ->
            store_embedding(repo, "mneme_chunks", chunk.id, embedding)
            %{chunk | embedding: embedding}
          end)

        {:ok, updated}

      {:error, reason} ->
        Logger.error("Mneme.Embedder: chunk embedding failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "Embed a single entity's name + description."
  def embed_entity(%Entity{} = entity) do
    text = "#{entity.name}: #{entity.description || ""}"

    case EmbeddingProvider.embed(text) do
      {:ok, embedding} ->
        repo = Config.repo()
        store_embedding(repo, "mneme_entities", entity.id, embedding)
        {:ok, %{entity | embedding: embedding}}

      {:error, reason} ->
        Logger.warning(
          "Mneme.Embedder: entity embedding failed for #{entity.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc "Embed a single entry asynchronously."
  def embed_entry_async(%{id: entry_id, content: content}) when is_binary(content) do
    Task.Supervisor.start_child(
      Config.task_supervisor(),
      fn ->
        case EmbeddingProvider.embed(content) do
          {:ok, embedding} ->
            store_embedding(Config.repo(), "mneme_entries", entry_id, embedding)

          {:error, reason} ->
            Logger.warning(
              "Mneme.Embedder: entry embedding failed for #{entry_id}: #{inspect(reason)}"
            )
        end
      end,
      restart: :temporary
    )
  rescue
    _ -> :ok
  end

  def embed_entry_async(_), do: :ok

  @doc "Embed a query string for search (no storage)."
  def embed_query(text) do
    EmbeddingProvider.embed(text)
  end

  defp store_embedding(repo, table, id, embedding) do
    pgvec = Pgvector.new(embedding)
    query = "UPDATE #{table} SET embedding = $1 WHERE id = $2"

    case repo.query(query, [pgvec, id]) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Mneme.Embedder: failed to store embedding for #{id}: #{inspect(reason)}")
    end
  end
end
