defmodule Recollect.DatabaseAdapter.LibSQL do
  @moduledoc """
  libSQL/SQLite database adapter with native vector support.

  This is the recommended adapter for new installations as it requires
  no external database server - everything is stored in a single file.

  ## Features

  - Native F32_BLOB/F64_BLOB vector types (no extensions needed)
  - Built-in vector similarity functions
  - DiskANN-based vector indexing
  - Single-file database (easy backup/restore)
  - Cross-platform support

  ## Requirements

  - ecto_libsql package
  - libSQL library (bundled with ecto_libsql via Rust NIFs)

  ## Configuration

      config :recollect, :database_adapter, Recollect.DatabaseAdapter.LibSQL

  ## Database URL

  Local file:
      database: "/path/to/recollect.db"

  Remote (Turso):
      database: "libsql://..."
      key: "your-auth-token"
  """

  use Recollect.DatabaseAdapter.SQLiteBase

  @impl true
  def vector_type(dimensions) do
    "F32_BLOB(#{dimensions})"
  end

  @impl true
  def vector_index_sql(table, column, _opts \\ []) do
    index_name = "#{table}_#{column}_idx"

    """
    CREATE INDEX #{index_name} ON #{table} (libsql_vector_idx(#{column}))
    """
  end

  @impl true
  def vector_distance_sql(column, query_ref) do
    "vector_distance_cos(#{column}, vector32(#{query_ref}))"
  end

  @impl true
  def vector_similarity_sql(column, query_ref) do
    "(1 - vector_distance_cos(#{column}, vector32(#{query_ref})))"
  end

  @impl true
  def top_k_sql(table, index_name, query_vector, k) do
    """
    SELECT t.*, v.distance
    FROM vector_top_k('#{index_name}', vector32('#{query_vector}'), #{k}) AS v
    JOIN #{table} AS t ON t.rowid = v.id
    """
  end

  @impl true
  def dialect, do: :libsql

  @impl true
  def repo_adapter, do: Ecto.Adapters.LibSQL

  @doc """
  Convert an embedding list to libSQL vector32() SQL expression.

  ## Examples

      iex> LibSQL.vector32_expression([0.1, 0.2, 0.3])
      "vector32('[0.1,0.2,0.3]')"
  """
  def vector32_expression(embedding) when is_list(embedding) do
    "vector32('#{format_embedding(embedding)}')"
  end

  @doc """
  Returns SQL for inserting a row with an embedding column.

  For libSQL, embeddings must be wrapped in vector32() function.
  """
  def insert_embedding_sql(table, columns, embedding_col, _embedding_value) do
    col_names = Enum.join(columns, ", ")
    placeholders = Enum.map_join(1..length(columns), ", ", fn _ -> "?" end)

    if embedding_col in columns do
      idx = Enum.find_index(columns, &(&1 == embedding_col))
      placeholders_list = String.split(placeholders, ", ")

      updated_placeholders =
        placeholders_list
        |> List.update_at(idx, fn _ -> "vector32(?)" end)
        |> Enum.join(", ")

      "INSERT INTO #{table} (#{col_names}) VALUES (#{updated_placeholders})"
    else
      "INSERT INTO #{table} (#{col_names}) VALUES (#{placeholders})"
    end
  end
end
