defmodule Mneme.DatabaseAdapter.LibSQL do
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

      config :mneme, :database_adapter, Mneme.DatabaseAdapter.LibSQL

  ## Database URL

  Local file:
      database: "/path/to/mneme.db"

  Remote (Turso):
      database: "libsql://..."
      key: "your-auth-token"
  """

  @behaviour Mneme.DatabaseAdapter

  @impl true
  def vector_type(dimensions) do
    "F32_BLOB(#{dimensions})"
  end

  @impl true
  def vector_ecto_type do
    # libSQL stores vectors as binary blobs
    # We use :string for JSON representation in Ecto, then convert
    :string
  end

  @impl true
  def format_embedding(embedding) when is_list(embedding) do
    # Convert list to JSON array string for libSQL vector32() function
    "[#{Enum.map_join(embedding, ",", &format_float/1)}]"
  end

  defp format_float(f) when is_float(f) do
    # Ensure consistent float formatting
    :erlang.float_to_binary(f, [:compact, decimals: 6])
  end

  defp format_float(i) when is_integer(i), do: Integer.to_string(i)

  @impl true
  def vector_index_sql(table, column, _opts \\ []) do
    index_name = "#{table}_#{column}_idx"
    # libSQL uses libsql_vector_idx() function for vector indexing
    # Optional parameters: metric=cosine (default), metric=l2, metric=dot
    """
    CREATE INDEX #{index_name} ON #{table} (libsql_vector_idx(#{column}))
    """
  end

  @impl true
  def vector_distance_sql(column, query_ref) do
    # query_ref should be wrapped in vector32() or vector64()
    "vector_distance_cos(#{column}, vector32(#{query_ref}))"
  end

  @impl true
  def vector_similarity_sql(column, query_ref) do
    # Cosine similarity = 1 - cosine distance
    "(1 - vector_distance_cos(#{column}, vector32(#{query_ref})))"
  end

  @impl true
  def create_vector_extension_sql do
    # libSQL has native vector support, no extension needed
    nil
  end

  @impl true
  def uuid_type do
    # libSQL doesn't have a native UUID type, use TEXT
    :string
  end

  @impl true
  def format_uuid(uuid) when is_binary(uuid) do
    # Store UUIDs as text in libSQL
    uuid
  end

  @impl true
  def supports_recursive_ctes? do
    # SQLite/libSQL supports recursive CTEs
    true
  end

  @impl true
  def supports_vector_index? do
    true
  end

  @impl true
  def top_k_sql(table, index_name, query_vector, k) do
    # libSQL supports efficient top-k via vector_top_k() table-valued function
    """
    SELECT t.*, v.distance
    FROM vector_top_k('#{index_name}', vector32('#{query_vector}'), #{k}) AS v
    JOIN #{table} AS t ON t.rowid = v.id
    """
  end

  @impl true
  def dialect do
    :libsql
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
    # Try to parse JSON string representation
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
    # Use EctoLibSql adapter
    Ecto.Adapters.LibSQL
  end

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

    # Handle embedding column specially
    if embedding_col in columns do
      # Replace placeholder for embedding column with vector32(?)
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
