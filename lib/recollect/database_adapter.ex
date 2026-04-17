defmodule Recollect.DatabaseAdapter do
  @moduledoc """
  Behaviour for database-specific implementations.

  Recollect supports multiple database backends through this adapter pattern.
  Currently supported:
  - PostgreSQL with pgvector extension
  - libSQL (SQLite with native vector support)

  Configure the adapter in your config.exs:

      config :recollect, :database_adapter, Recollect.DatabaseAdapter.LibSQL
      # or
      config :recollect, :database_adapter, Recollect.DatabaseAdapter.Postgres

  The adapter is used internally by Recollect to generate database-specific
  SQL, handle type mappings, and manage vector operations.
  """

  @doc """
  Returns the SQL type definition for a vector column.

  ## Examples

      iex> adapter.vector_type(768)
      "F32_BLOB(768)"  # for libSQL
      "vector(768)"    # for PostgreSQL
  """
  @callback vector_type(dimensions :: pos_integer()) :: String.t()

  @doc """
  Returns the Ecto type atom for embedding fields.

  ## Examples

      iex> adapter.vector_ecto_type()
      :string  # for libSQL (vectors stored as text representation)
      Pgvector.Ecto.Vector  # for PostgreSQL
  """
  @callback vector_ecto_type() :: atom()

  @doc """
  Formats an embedding list for database insertion.

  ## Examples

      iex> adapter.format_embedding([0.1, 0.2, 0.3])
      "[0.1,0.2,0.3]"  # for libSQL
      [0.1, 0.2, 0.3]  # for PostgreSQL (as Pgvector.Ecto.Vector)
  """
  @callback format_embedding(embedding :: [float()]) :: String.t() | [float()]

  @doc """
  Returns SQL for creating a vector index.

  ## Examples

      iex> adapter.vector_index_sql(:recollect_entries, :embedding, dimensions: 768)
      "CREATE INDEX ... USING hnsw ..."  # PostgreSQL
      "CREATE INDEX ... (libsql_vector_idx(embedding))"  # libSQL
  """
  @callback vector_index_sql(table :: atom(), column :: atom(), opts :: keyword()) :: String.t()

  @doc """
  Returns SQL expression for calculating cosine distance.

  ## Examples

      iex> adapter.vector_distance_sql("embedding", "query_vector")
      "embedding <=> query_vector"  # PostgreSQL
      "vector_distance_cos(embedding, query_vector)"  # libSQL
  """
  @callback vector_distance_sql(column :: String.t(), query_ref :: String.t()) :: String.t()

  @doc """
  Returns SQL expression for calculating cosine similarity (1 - distance).
  """
  @callback vector_similarity_sql(column :: String.t(), query_ref :: String.t()) :: String.t()

  @doc """
  Returns SQL for creating the vector extension, or nil if not needed.
  """
  @callback create_vector_extension_sql() :: String.t() | nil

  @doc """
  Returns the Ecto type for UUID fields.

  ## Examples

      iex> adapter.uuid_type()
      :binary_id  # libSQL uses binary IDs by default
      :uuid       # PostgreSQL has native UUID
  """
  @callback uuid_type() :: atom()

  @doc """
  Formats a UUID for database insertion.
  """
  @callback format_uuid(uuid :: String.t() | binary()) :: String.t() | binary()

  @doc """
  Returns true if the database supports recursive CTEs.
  """
  @callback supports_recursive_ctes?() :: boolean()

  @doc """
  Returns true if the database supports vector indexes.
  """
  @callback supports_vector_index?() :: boolean()

  @doc """
  Returns SQL for approximate top-k vector search using index.

  Returns nil if not supported by the database.
  """
  @callback top_k_sql(table :: atom(), index_name :: String.t(), query_vector :: String.t(), k :: pos_integer()) ::
              String.t() | nil

  @doc """
  Returns the SQL dialect name.
  """
  @callback dialect() :: :postgres | :sqlite | :libsql

  @doc """
  Returns SQL placeholder for parameterized queries.

  PostgreSQL uses numbered parameters ($1, $2), while SQLite uses ?.
  """
  @callback placeholder(position :: pos_integer()) :: String.t()

  @doc """
  Returns true if the adapter requires the pgvector package.
  """
  @callback requires_pgvector?() :: boolean()

  @doc """
  Converts an embedding from database format to Elixir list.
  """
  @callback parse_embedding(data :: any()) :: [float()] | nil

  @doc """
  Returns the module name for the Repo adapter.

  ## Examples

      iex> adapter.repo_adapter()
      Ecto.Adapters.LibSQL  # for libSQL
      Ecto.Adapters.Postgres  # for PostgreSQL
  """
  @callback repo_adapter() :: module()

  @optional_callbacks [
    top_k_sql: 4,
    parse_embedding: 1
  ]
end
