defmodule Recollect.SchemaIndex do
  @moduledoc """
  ETS table for schema acceleration data.

  Rebuilt during consolidation pass. Read by schema_fit computation on every entry creation.
  No GenServer owner — public table, written by consolidation, read by everyone.
  """

  @table :recollect_schema_index

  @doc "Initialize the ETS table."
  def init do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      {:read_concurrency, true}
    ])
  end

  @doc "Rebuild the index from all active entries in the DB."
  def rebuild do
    repo = Recollect.Config.repo()

    rows =
      repo.query("""
        SELECT content, tags_json FROM recollect_entries WHERE entry_type != 'archived'
      """)

    entries =
      case rows do
        {:ok, %{rows: rows}} -> rows
        _ -> []
      end

    tag_freq = build_tag_frequency(entries)
    entry_count = length(entries)

    :ets.insert(@table, {:tag_frequency, tag_freq})
    :ets.insert(@table, {:entry_count, entry_count})

    %{tag_clusters: map_size(tag_freq), entry_count: entry_count}
  end

  @doc "Get the tag frequency map. Returns %{} if index is empty."
  def tag_frequency do
    case :ets.lookup(@table, :tag_frequency) do
      [{:tag_frequency, freq}] -> freq
      [] -> %{}
    end
  end

  @doc "Get the total entry count. Returns 0 if index is empty."
  def entry_count do
    case :ets.lookup(@table, :entry_count) do
      [{:entry_count, count}] -> count
      [] -> 0
    end
  end

  defp build_tag_frequency(rows) do
    Enum.reduce(rows, %{}, fn [_content, tags_json], acc ->
      tags =
        case tags_json do
          nil ->
            []

          json when is_binary(json) ->
            case Jason.decode(json) do
              {:ok, list} when is_list(list) -> list
              _ -> []
            end

          list when is_list(list) ->
            list

          _ ->
            []
        end

      Enum.reduce(tags, acc, fn tag, acc ->
        Map.update(acc, tag, 1, &(&1 + 1))
      end)
    end)
  end
end
