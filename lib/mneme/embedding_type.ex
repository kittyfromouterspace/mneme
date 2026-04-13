defmodule Mneme.EmbeddingType do
  @moduledoc """
  Ecto type for embedding vectors that works with both PostgreSQL and libSQL.

  For PostgreSQL: Uses Pgvector.Ecto.Vector when available
  For libSQL: Stores as JSON text and converts to list

  This type automatically detects the configured adapter and handles
  serialization/deserialization accordingly.
  """

  use Ecto.Type

  alias Mneme.Config
  alias Pgvector.Ecto.Vector

  @impl true
  def type do
    # Return the underlying database type
    adapter = Config.adapter()

    if adapter.dialect() == :postgres do
      # PostgreSQL uses pgvector's custom type
      :string
    else
      # libSQL stores as text (JSON array)
      :string
    end
  end

  @impl true
  def cast(nil), do: {:ok, nil}

  def cast(data) when is_list(data) do
    {:ok, data}
  end

  def cast(%{__struct__: struct_type} = value) when is_struct(value) do
    case to_string(struct_type) do
      "Elixir.Pgvector.Ecto.Vector" ->
        case Map.get(value, :embedding) do
          embedding when is_list(embedding) -> {:ok, embedding}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  def cast(_), do: :error

  @impl true
  def dump(data) when is_list(data) do
    adapter = Config.adapter()

    if adapter.dialect() == :postgres and Code.ensure_loaded?(Vector) do
      {:ok, struct(Vector, %{embedding: data})}
    else
      {:ok, adapter.format_embedding(data)}
    end
  end

  def dump(nil), do: {:ok, nil}
  def dump(_), do: :error

  @impl true
  def load(data) when is_list(data) do
    {:ok, data}
  end

  def load(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, list} when is_list(list) -> {:ok, list}
      _ -> {:ok, nil}
    end
  end

  def load(nil), do: {:ok, nil}
  def load(_), do: :error

  @doc """
  Format an embedding for SQL insertion.
  Returns the appropriate format for the configured adapter.
  """
  def format_for_sql(embedding) when is_list(embedding) do
    adapter = Config.adapter()
    adapter.format_embedding(embedding)
  end
end
