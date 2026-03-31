defmodule Mneme.Maintenance.Reembed do
  @moduledoc """
  Re-embeds entries and chunks that have nil embeddings.
  Useful after model changes or backfill.
  """

  import Ecto.Query
  alias Mneme.{Config, EmbeddingProvider}

  require Logger

  @doc """
  Re-embed all records with nil embeddings.

  ## Options
  - `:batch_size` — Records per batch (default: 20)
  - `:concurrency` — Parallel tasks (default: 2)
  - `:tables` — List of tables to process (default: ["mneme_entries", "mneme_chunks"])
  """
  def run(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 20)
    concurrency = Keyword.get(opts, :concurrency, 2)
    tables = Keyword.get(opts, :tables, ["mneme_entries", "mneme_chunks"])
    repo = Config.repo()

    total =
      Enum.reduce(tables, 0, fn table, acc ->
        case reembed_table(table, repo, batch_size, concurrency) do
          {:ok, count} -> acc + count
          _ -> acc
        end
      end)

    Logger.info("Mneme.Reembed: re-embedded #{total} records")
    {:ok, total}
  end

  defp reembed_table(table, repo, batch_size, concurrency) do
    stream =
      repo.stream(
        from(e in table,
          where: is_nil(e.embedding),
          select: %{id: e.id, content: e.content},
          order_by: [desc: e.inserted_at]
        ),
        max_rows: batch_size
      )

    repo.transaction(fn ->
      stream
      |> Stream.chunk_every(batch_size)
      |> Enum.reduce(0, fn batch, acc ->
        batch
        |> Task.async_stream(
          fn %{id: id, content: content} ->
            case EmbeddingProvider.embed(content) do
              {:ok, embedding} ->
                pgvec = Pgvector.new(embedding)
                repo.query("UPDATE #{table} SET embedding = $1 WHERE id = $2", [pgvec, id])

              _ ->
                :skip
            end
          end,
          max_concurrency: concurrency,
          timeout: 60_000
        )
        |> Enum.count()
        |> Kernel.+(acc)
      end)
    end)
  end
end
