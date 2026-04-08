defmodule Mneme.Pipeline.Embedder do
  @moduledoc """
  Embeds chunks and entities using the configured embedding provider.
  Supports batch processing and async embedding via TaskSupervisor.
  """

  alias Mneme.Config
  alias Mneme.EmbeddingProvider
  alias Mneme.Schema.Entity

  require Logger

  @doc """
  Embed a list of chunks. Updates embedding column via direct SQL.

  Returns `{:ok, chunks}` with embeddings populated.
  """
  def embed_chunks(chunks) when is_list(chunks) do
    start_time = System.monotonic_time()
    texts = Enum.map(chunks, & &1.content)

    result =
      case EmbeddingProvider.generate(texts) do
        {:ok, embeddings} ->
          repo = Config.repo()

          updated =
            chunks
            |> Enum.zip(embeddings)
            |> Enum.map(fn {chunk, embedding} ->
              store_embedding(repo, "mneme_chunks", chunk.id, embedding)
              %{chunk | embedding: embedding}
            end)

          {:ok, updated}

        {:error, reason} ->
          Logger.error("Mneme.Embedder: chunk embedding failed: #{inspect(reason)}")
          {:error, reason}
      end

    duration = System.monotonic_time() - start_time

    Mneme.Telemetry.event([:mneme, :embed, :stop], %{
      duration: duration,
      count: length(chunks),
      provider: Config.embedding_provider()
    })

    result
  end

  @doc "Embed a single entity's name + description."
  def embed_entity(%Entity{} = entity) do
    start_time = System.monotonic_time()
    text = "#{entity.name}: #{entity.description || ""}"

    result =
      case EmbeddingProvider.embed(text) do
        {:ok, embedding} ->
          repo = Config.repo()
          store_embedding(repo, "mneme_entities", entity.id, embedding)
          {:ok, %{entity | embedding: embedding}}

        {:error, reason} ->
          Logger.warning("Mneme.Embedder: entity embedding failed for #{entity.id}: #{inspect(reason)}")

          {:error, reason}
      end

    duration = System.monotonic_time() - start_time

    Mneme.Telemetry.event([:mneme, :embed, :stop], %{
      duration: duration,
      count: 1,
      provider: Config.embedding_provider()
    })

    result
  end

  @doc "Embed a single entry asynchronously. No-op if embedding is disabled."
  def embed_entry_async(%{id: entry_id, content: content}) when is_binary(content) do
    if !Config.embedding_enabled?(), do: throw(:disabled)

    Task.Supervisor.start_child(
      Config.task_supervisor(),
      fn ->
        start_time = System.monotonic_time()

        result =
          case EmbeddingProvider.embed(content) do
            {:ok, embedding} ->
              store_embedding(Config.repo(), "mneme_entries", entry_id, embedding)

            {:error, reason} ->
              Logger.warning("Mneme.Embedder: entry embedding failed for #{entry_id}: #{inspect(reason)}")
          end

        duration = System.monotonic_time() - start_time

        Mneme.Telemetry.event([:mneme, :embed, :stop], %{
          duration: duration,
          count: 1,
          provider: Config.embedding_provider()
        })

        result
      end,
      restart: :temporary
    )
  rescue
    _ -> :ok
  catch
    :disabled -> :ok
  end

  def embed_entry_async(_), do: :ok

  @doc "Embed a query string for search (no storage)."
  def embed_query(text) do
    start_time = System.monotonic_time()
    result = EmbeddingProvider.embed(text)
    duration = System.monotonic_time() - start_time

    Mneme.Telemetry.event([:mneme, :embed, :stop], %{
      duration: duration,
      count: 1,
      provider: Config.embedding_provider()
    })

    result
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
