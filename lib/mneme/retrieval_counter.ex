defmodule Mneme.RetrievalCounter do
  @moduledoc """
  GenServer that owns an ETS :counter table for retrieval bumps.

  - bump/1: O(1) :ets.update_counter call
  - Periodic flush: single bulk UPDATE to DB
  - terminate/2: final flush on shutdown

  This replaces the previous pattern of one async UPDATE per search result.
  """

  use GenServer

  alias Mneme.Config

  @table :mneme_retrieval_counters
  @default_flush_interval 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Increment retrieval counter for an entry. O(1) operation."
  def bump(entry_id) do
    :ets.update_counter(@table, entry_id, {2, 1, 1, 1})
  rescue
    _ -> :ok
  end

  @doc "Increment retrieval counters for multiple entries."
  def bump_many(entry_ids) when is_list(entry_ids) do
    for id <- entry_ids, do: bump(id)
  end

  @doc "Get current count for an entry (for debugging)."
  def count(entry_id) do
    case :ets.lookup(@table, entry_id) do
      [{^entry_id, count}] -> count
      [] -> 0
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      {:read_concurrency, true},
      {:write_concurrency, true}
    ])

    interval =
      :mneme
      |> Application.get_env(:retrieval_strengthening, [])
      |> Keyword.get(:flush_interval_ms, @default_flush_interval)

    schedule_flush(interval)
    {:ok, %{flush_interval: interval}}
  end

  @impl true
  def handle_info(:flush, state) do
    do_flush()
    schedule_flush(state.flush_interval)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    do_flush()
  end

  defp do_flush do
    entries = :ets.tab2list(@table)

    if entries != [] do
      now = DateTime.utc_now()

      boost_days =
        :mneme
        |> Application.get_env(:retrieval_strengthening, [])
        |> Keyword.get(:half_life_boost_days, 2)

      ids = Enum.map(entries, fn {id, _count} -> id end)

      try do
        Config.repo().query(
          """
            UPDATE mneme_entries
            SET access_count = access_count + 1,
                half_life_days = half_life_days + $1,
                last_accessed_at = $2,
                updated_at = $2
            WHERE id = ANY($3)
          """,
          [boost_days, now, ids]
        )
      rescue
        _ -> :ok
      end

      :ets.delete_all_objects(@table)
    end
  end

  defp schedule_flush(interval) do
    Process.send_after(self(), :flush, interval)
  end
end
