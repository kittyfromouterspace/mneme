defmodule Recollect.DatabaseAdapter.SQLiteVec do
  @moduledoc """
  SQLite database adapter with sqlite-vec extension for vector support.

  This adapter uses standard SQLite via `ecto_sqlite3` combined with the
  `sqlite_vec` extension for vector similarity search. Unlike libSQL, this
  works on all platforms including Windows.

  ## Features

  - sqlite-vec extension for vector search (vec0 virtual tables)
  - Single-file database (easy backup/restore)
  - Cross-platform support (macOS, Linux, Windows)
  - Brute-force cosine distance search (DiskANN ANN in alpha)

  ## Requirements

  - ecto_sqlite3 package
  - sqlite_vec package (bundles precompiled extension binaries)

  ## Configuration

      config :recollect, :database_adapter, Recollect.DatabaseAdapter.SQLiteVec

      config :your_app, YourRepo,
        adapter: Ecto.Adapters.SQLite3,
        load_extensions: [SqliteVec.path()]
  """

  use Recollect.DatabaseAdapter.SQLiteBase

  @impl true
  def vector_type(dimensions) do
    "float[#{dimensions}]"
  end

  @impl true
  def vector_index_sql(table, column, _opts \\ []) do
    vec_table = "#{table}_#{column}_vec"

    """
    CREATE VIRTUAL TABLE IF NOT EXISTS #{vec_table} USING vec0(
      id TEXT PRIMARY KEY,
      embedding #{vector_type(Recollect.Config.dimensions())}
    )
    """
  end

  @impl true
  def vector_distance_sql(column, query_ref) do
    "vec_distance_cosine(#{column}, #{query_ref})"
  end

  @impl true
  def vector_similarity_sql(column, query_ref) do
    "(1 - vec_distance_cosine(#{column}, #{query_ref}))"
  end

  @impl true
  def top_k_sql(_table, _index_name, _query_vector, _k), do: nil

  @impl true
  def dialect, do: :sqlite

  @impl true
  def repo_adapter, do: Ecto.Adapters.SQLite3
end
