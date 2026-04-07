defmodule Mneme.OutcomeTracker do
  @moduledoc """
  ETS table for tracking the last-retrieved entry IDs per scope.

  No GenServer needed — this is a simple public ETS table
  that search writes to and outcome feedback reads from.
  """

  @table :mneme_last_retrieved

  @doc "Initialize the ETS table. Call from Application.start/2."
  def init do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      {:read_concurrency, true}
    ])
  end

  @doc "Store the retrieved entry IDs for a scope. Overwrites previous value."
  def set(scope_id, entry_ids) when is_list(entry_ids) do
    :ets.insert(@table, {scope_id, entry_ids})
  end

  @doc "Get the last-retrieved entry IDs for a scope."
  def get(scope_id) do
    case :ets.lookup(@table, scope_id) do
      [{^scope_id, ids}] -> ids
      [] -> []
    end
  end

  @doc "Clear the last-retrieved entries for a scope."
  def clear(scope_id) do
    :ets.delete(@table, scope_id)
  end
end
