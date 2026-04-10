defmodule Mneme.DatabaseAdapter.Postgres do
  @moduledoc """
  PostgreSQL database adapter with pgvector support.

  This is the legacy adapter that provides backward compatibility
  for existing Mneme installations using PostgreSQL.

  ## Requirements

  - PostgreSQL 14+
  - pgvector extension installed

  ## Configuration

      config :mneme, :database_adapter, Mneme.DatabaseAdapter.Postgres
  """

  @behaviour Mneme.DatabaseAdapter

  @impl true
  def vector_type(dimensions) do
    "vector(#{dimensions})"
  end

  @impl true
  def vector_ecto_type do
    Pgvector.Ecto.Vector
  end

  @impl true
  def format_embedding(embedding) when is_list(embedding) do
    # PostgreSQL with pgvector accepts the list directly
    # wrapped in Pgvector.Ecto.Vector struct at changeset level
    embedding
  end

  @impl true
  def vector_index_sql(table, column, _opts \\ []) do
    index_name = "#{table}_#{column}_idx"

    """
    CREATE INDEX #{index_name} ON #{table}
    USING hnsw (#{column} vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    """
  end

  @impl true
  def vector_distance_sql(column, query_ref) do
    "#{column} <=> #{query_ref}"
  end

  @impl true
  def vector_similarity_sql(column, query_ref) do
    "(1 - (#{column} <=> #{query_ref}))"
  end

  @impl true
  def create_vector_extension_sql do
    "CREATE EXTENSION IF NOT EXISTS vector"
  end

  @impl true
  def uuid_type do
    :uuid
  end

  @impl true
  def format_uuid(uuid) when is_binary(uuid) do
    # PostgreSQL accepts UUID strings directly
    uuid
  end

  @impl true
  def supports_recursive_ctes? do
    true
  end

  @impl true
  def supports_vector_index? do
    true
  end

  @impl true
  def top_k_sql(_table, _index_name, _query_vector, _k) do
    # PostgreSQL doesn't have a direct top_k function like libSQL
    # Uses ORDER BY with LIMIT instead
    nil
  end

  @impl true
  def dialect do
    :postgres
  end

  @impl true
  def placeholder(position) when is_integer(position) and position > 0 do
    "$#{position}"
  end

  @impl true
  def requires_pgvector? do
    true
  end

  @impl true
  def parse_embedding(%{__struct__: Pgvector.Ecto.Vector, embedding: embedding}) do
    embedding
  end

  def parse_embedding(embedding) when is_list(embedding) do
    embedding
  end

  def parse_embedding(nil), do: nil

  @impl true
  def repo_adapter do
    Ecto.Adapters.Postgres
  end
end
