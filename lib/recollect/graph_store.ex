defmodule Recollect.GraphStore do
  @moduledoc """
  Behaviour for graph storage backends.

  Default implementation uses PostgreSQL recursive CTEs.
  Can be swapped for KuzuDB, Apache AGE, or other graph stores.
  """

  @type entity :: %{
          id: String.t(),
          name: String.t(),
          entity_type: String.t(),
          description: String.t(),
          mention_count: integer()
        }

  @type relation :: %{
          from_id: String.t(),
          to_id: String.t(),
          relation_type: String.t(),
          weight: float()
        }

  @doc "Get entities within N hops of a starting entity."
  @callback get_neighbors(owner_id :: String.t(), entity_id :: String.t(), hops :: pos_integer()) ::
              {:ok, [entity()]} | {:error, term()}

  @doc "Get all relations involving an entity."
  @callback get_relations(owner_id :: String.t(), entity_id :: String.t()) ::
              {:ok, [relation()]} | {:error, term()}

  @doc "Get the configured graph store implementation."
  def impl do
    Application.get_env(:recollect, :graph_store, Recollect.Graph.PostgresGraph)
  end
end
