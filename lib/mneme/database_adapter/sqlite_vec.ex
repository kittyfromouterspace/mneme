defmodule Mneme.DatabaseAdapter.SQLiteVec do
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

      config :mneme, :database_adapter, Mneme.DatabaseAdapter.SQLiteVec

      config :your_app, YourRepo,
        adapter: Ecto.Adapters.SQLite3,
        load_extensions: [SqliteVec.path()]
  """

  @behaviour Mneme.DatabaseAdapter

  @impl true
  def vector_type(dimensions) do
    # sqlite-vec uses float[N] syntax in vec0 virtual tables
    "float[#{dimensions}]"
  end

  @impl true
  def vector_ecto_type do
    # Embeddings are stored as JSON text in regular tables,
    # sqlite-vec handles the conversion internally
    :string
  end

  @impl true
  def format_embedding(embedding) when is_list(embedding) do
    # Convert list to JSON array string for sqlite-vec
    "[#{Enum.map_join(embedding, ",", &format_float/1)}]"
  end

  defp format_float(f) when is_float(f) do
    :erlang.float_to_binary(f, [:compact, decimals: 6])
  end

  defp format_float(i) when is_integer(i), do: Integer.to_string(i)

  @impl true
  def vector_index_sql(table, column, _opts \\ []) do
    # sqlite-vec uses vec0 virtual tables as the "index"
    # The virtual table holds the vectors and supports KNN queries
    vec_table = "#{table}_#{column}_vec"

    """
    CREATE VIRTUAL TABLE IF NOT EXISTS #{vec_table} USING vec0(
      id TEXT PRIMARY KEY,
      embedding #{vector_type(dimensions_from_opts())}
    )
    """
  end

  @impl true
  def vector_distance_sql(column, query_ref) do
    # sqlite-vec uses vec_distance_cosine() for cosine distance
    "vec_distance_cosine(#{column}, #{query_ref})"
  end

  @impl true
  def vector_similarity_sql(column, query_ref) do
    # Cosine similarity = 1 - cosine distance
    "(1 - vec_distance_cosine(#{column}, #{query_ref}))"
  end

  @impl true
  def create_vector_extension_sql do
    # sqlite-vec is loaded as a runtime extension, no SQL needed
    nil
  end

  @impl true
  def uuid_type do
    # SQLite doesn't have a native UUID type, use TEXT
    :string
  end

  @impl true
  def format_uuid(uuid) when is_binary(uuid) do
    uuid
  end

  @impl true
  def supports_recursive_ctes? do
    true
  end

  @impl true
  def supports_vector_index? do
    # sqlite-vec supports vec0 virtual table indexes
    true
  end

  @impl true
  def top_k_sql(_table, _index_name, _query_vector, _k) do
    # sqlite-vec KNN is done via WHERE embedding MATCH query
    # with ORDER BY distance LIMIT k on the vec0 table.
    # We handle this in the search queries directly.
    nil
  end

  @impl true
  def dialect do
    :sqlite
  end

  @impl true
  def placeholder(_position) do
    # SQLite uses ? for all parameters (not numbered)
    "?"
  end

  @impl true
  def requires_pgvector? do
    false
  end

  @impl true
  def parse_embedding(nil), do: nil

  def parse_embedding(embedding) when is_binary(embedding) do
    case Jason.decode(embedding) do
      {:ok, list} when is_list(list) -> list
      _ -> nil
    end
  end

  def parse_embedding(embedding) when is_list(embedding) do
    embedding
  end

  @impl true
  def repo_adapter do
    Ecto.Adapters.SQLite3
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp dimensions_from_opts do
    Mneme.Config.dimensions()
  end
end
