defmodule Mneme.Knowledge do
  @moduledoc """
  Lightweight knowledge API (Tier 2).
  Simple store-embed-search for entries and edges.
  """

  import Ecto.Query
  alias Mneme.Config
  alias Mneme.Schema.{Entry, Edge}
  alias Mneme.Pipeline.Embedder

  require Logger

  @doc """
  Store a knowledge entry with auto-embedding.
  """
  def remember(content, opts \\ []) do
    metadata = %{
      entry_type: Keyword.get(opts, :entry_type, "note"),
      scope_id: Keyword.get(opts, :scope_id),
      owner_id: Keyword.get(opts, :owner_id)
    }

    Mneme.Telemetry.span([:mneme, :remember], metadata, fn ->
      repo = Config.repo()

      attrs = %{
        content: content,
        scope_id: Keyword.get(opts, :scope_id),
        owner_id: Keyword.get(opts, :owner_id),
        entry_type: Keyword.get(opts, :entry_type, "note"),
        summary: Keyword.get(opts, :summary),
        source: Keyword.get(opts, :source, "system"),
        source_id: Keyword.get(opts, :source_id),
        metadata: Keyword.get(opts, :metadata, %{}),
        confidence: Keyword.get(opts, :confidence, 1.0)
      }

      case %Entry{} |> Entry.changeset(attrs) |> repo.insert() do
        {:ok, entry} ->
          Embedder.embed_entry_async(entry)
          {:ok, entry}

        {:error, changeset} ->
          {:error, changeset}
      end
    end)
  end

  @doc "Delete a knowledge entry."
  def forget(entry_id) do
    Mneme.Telemetry.span([:mneme, :forget], %{entry_id: entry_id}, fn ->
      repo = Config.repo()

      case repo.get(Entry, entry_id) do
        nil -> {:error, :not_found}
        entry -> repo.delete(entry)
      end
    end)
  end

  @doc "Create an edge between two entries."
  def connect(source_id, target_id, relation, opts \\ []) do
    Mneme.Telemetry.span([:mneme, :connect], %{relation: relation}, fn ->
      repo = Config.repo()

      attrs = %{
        source_entry_id: source_id,
        target_entry_id: target_id,
        relation: relation,
        weight: Keyword.get(opts, :weight, 1.0),
        metadata: Keyword.get(opts, :metadata, %{})
      }

      %Edge{} |> Edge.changeset(attrs) |> repo.insert()
    end)
  end

  @doc "Get recent entries for a scope."
  def recent(scope_id, opts \\ []) do
    Mneme.Telemetry.span([:mneme, :recent], %{scope_id: scope_id}, fn ->
      repo = Config.repo()
      limit = Keyword.get(opts, :limit, 20)

      from(e in Entry,
        where: e.scope_id == ^scope_id and e.entry_type != "archived",
        order_by: [desc: e.inserted_at],
        limit: ^limit
      )
      |> repo.all()
    end)
  end

  @doc """
  Apply supersession: demote old entries matching entity+relation pattern.
  New entry supersedes old ones by setting their confidence to 0.1.
  """
  def supersede(scope_id, entity, relation, _new_value) do
    Mneme.Telemetry.span(
      [:mneme, :supersede],
      %{scope_id: scope_id, entity: entity, relation: relation},
      fn ->
        repo = Config.repo()

        # Find entries matching the pattern in content
        pattern = "%#{entity}%#{relation}%"

        from(e in Entry,
          where:
            e.scope_id == ^scope_id and
              e.confidence > 0.1 and
              ilike(e.content, ^pattern)
        )
        |> repo.update_all(set: [confidence: 0.1, updated_at: DateTime.utc_now()])
      end
    )
  end
end
