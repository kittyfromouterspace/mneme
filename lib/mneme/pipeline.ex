defmodule Mneme.Pipeline do
  @moduledoc """
  Orchestrates the full memory ingestion pipeline.

  Stages: Chunk → Embed Chunks → Extract → Embed Entities → Complete.
  Tracks progress via PipelineRun records.
  """

  import Ecto.Query
  alias Mneme.Config
  alias Mneme.Schema.{Chunk, PipelineRun}
  alias Mneme.Pipeline.{Chunker, Embedder, Extractor}

  require Logger

  @doc """
  Run the full pipeline synchronously on a document.
  Returns `{:ok, pipeline_run}` or `{:error, reason}`.
  """
  def process(document, opts \\ []) do
    telemetry_metadata = %{document_id: document.id, owner_id: document.owner_id}

    Mneme.Telemetry.span([:mneme, :pipeline], telemetry_metadata, fn ->
      repo = Config.repo()
      owner_id = document.owner_id

      {:ok, run} =
        %PipelineRun{}
        |> PipelineRun.changeset(%{
          document_id: document.id,
          status: "pending",
          owner_id: owner_id,
          scope_id: document.scope_id
        })
        |> repo.insert()

      scope_id = document.scope_id

      pipeline_opts =
        Keyword.merge(opts,
          owner_id: owner_id,
          scope_id: scope_id,
          collection_id: document.collection_id
        )

      result =
        with {:ok, run} <- update_run(run, "chunking", repo),
             {:ok, chunks} <- do_chunk(document, pipeline_opts, repo),
             {:ok, run} <- update_run(run, "embedding", %{chunks_created: length(chunks)}, repo),
             {:ok, chunks} <- do_embed_chunks(chunks),
             {:ok, run} <- update_run(run, "extracting", %{chunks_embedded: length(chunks)}, repo),
             {:ok, extraction} <- do_extract(chunks, pipeline_opts),
             {:ok, run} <-
               update_run(
                 run,
                 "syncing",
                 %{
                   entities_extracted: length(extraction.entities),
                   relations_extracted: length(extraction.relations)
                 },
                 repo
               ),
             {:ok, _} <- do_embed_entities(extraction.entities),
             {:ok, _run} <- update_run(run, "complete", repo) do
          # Mark document as ready
          document
          |> Ecto.Changeset.change(%{status: "ready"})
          |> repo.update()

          {:ok, run}
        end

      case result do
        {:ok, _} ->
          result

        {:error, reason} ->
          Logger.error("Mneme.Pipeline: failed for document #{document.id}: #{inspect(reason)}")

          run
          |> PipelineRun.changeset(%{status: "failed", error: inspect(reason)})
          |> repo.update()

          document
          |> Ecto.Changeset.change(%{status: "failed"})
          |> repo.update()

          {:error, reason}
      end
    end)
  end

  @doc "Run the pipeline asynchronously."
  def process_async(document, opts \\ []) do
    Task.Supervisor.start_child(
      Config.task_supervisor(),
      fn -> process(document, opts) end,
      restart: :temporary
    )
  end

  # ── Pipeline Steps ────────────────────────────────────────────────────

  defp do_chunk(document, opts, repo) do
    owner_id = Keyword.fetch!(opts, :owner_id)
    scope_id = Keyword.get(opts, :scope_id)

    # Delete existing chunks (re-processing)
    from(c in Chunk, where: c.document_id == ^document.id) |> repo.delete_all()

    # Chunk the content
    raw_chunks = Chunker.chunk(document.content)

    chunks =
      Enum.map(raw_chunks, fn raw ->
        {:ok, chunk} =
          %Chunk{}
          |> Chunk.changeset(%{
            document_id: document.id,
            sequence: raw.sequence,
            content: raw.content,
            token_count: raw.token_count,
            start_offset: raw.start_offset,
            end_offset: raw.end_offset,
            metadata: %{heading_context: raw.heading_context},
            owner_id: owner_id,
            scope_id: scope_id
          })
          |> repo.insert()

        chunk
      end)

    {:ok, chunks}
  rescue
    e ->
      Logger.error("Mneme.Pipeline: chunking failed: #{Exception.message(e)}")
      {:error, e}
  end

  defp do_embed_chunks(chunks) do
    case Embedder.embed_chunks(chunks) do
      {:ok, _} = result ->
        result

      {:error, reason} ->
        Logger.warning("Mneme.Pipeline: chunk embedding failed, continuing: #{inspect(reason)}")
        {:ok, chunks}
    end
  end

  defp do_extract(chunks, opts) do
    collection_id = Keyword.fetch!(opts, :collection_id)
    owner_id = Keyword.fetch!(opts, :owner_id)
    scope_id = Keyword.get(opts, :scope_id)

    {all_entities, all_relations} =
      Enum.reduce(chunks, {[], []}, fn chunk, {entities_acc, relations_acc} ->
        case Extractor.extract_from_chunk(chunk.content) do
          {:ok, %{entities: entities, relations: relations}} ->
            {:ok, persisted_entities} =
              Extractor.persist_entities(entities,
                collection_id: collection_id,
                owner_id: owner_id,
                scope_id: scope_id
              )

            entity_map =
              persisted_entities
              |> Enum.map(fn e -> {String.downcase(e.name), e.id} end)
              |> Map.new()

            {:ok, persisted_relations} =
              Extractor.persist_relations(relations, entity_map,
                owner_id: owner_id,
                scope_id: scope_id,
                source_chunk_id: chunk.id
              )

            {entities_acc ++ persisted_entities, relations_acc ++ persisted_relations}

          {:error, reason} ->
            Logger.warning(
              "Mneme.Pipeline: extraction failed for chunk #{chunk.id}: #{inspect(reason)}"
            )

            {entities_acc, relations_acc}
        end
      end)

    {:ok, %{entities: all_entities, relations: all_relations}}
  end

  defp do_embed_entities(entities) do
    # Embed entities async — don't block pipeline
    Enum.each(entities, fn entity ->
      Task.Supervisor.start_child(
        Config.task_supervisor(),
        fn -> Embedder.embed_entity(entity) end,
        restart: :temporary
      )
    end)

    {:ok, entities}
  rescue
    _ -> {:ok, entities}
  end

  defp update_run(run, status, repo) do
    update_run(run, status, %{}, repo)
  end

  defp update_run(run, status, step_details, repo) do
    current = run.step_details || %{}
    merged = Map.merge(current, step_details)

    run
    |> PipelineRun.changeset(%{status: status, step_details: merged})
    |> repo.update()
  end
end
