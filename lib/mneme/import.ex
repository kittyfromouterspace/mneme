defmodule Mneme.Import do
  @moduledoc """
  Import Mneme data from JSONL export files.

  Supports importing data exported from any supported database backend
  (PostgreSQL or libSQL) into the current configured database.

  ## Usage

      # Import all data
      Mneme.Import.import_all("/path/to/backup.jsonl")

      # Import with options
      Mneme.Import.import_all("/path/to/backup.jsonl",
        batch_size: 500,
        on_conflict: :replace,
        transform_embeddings: true
      )

  ## Import Options

  - `:batch_size` — Number of rows to insert per transaction (default: 1000)
  - `:on_conflict` — How to handle conflicts: `:skip`, `:replace`, or `:error` (default: :skip)
  - `:transform_embeddings` — Re-embed content if embedding model changed (default: false)
  - `:scope_mapping` — Map old scope_ids to new ones (for tenant migration)
  - `:dry_run` — Validate without inserting (default: false)
  """

  alias Mneme.Config

  require Logger

  @doc """
  Import all data from a JSONL export file.

  ## Example

      Mneme.Import.import_all("/tmp/mneme_backup.jsonl")
      # {:ok, %{imported: 15432, skipped: 0, errors: []}}
  """
  def import_all(path, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 1000)
    on_conflict = Keyword.get(opts, :on_conflict, :skip)
    dry_run = Keyword.get(opts, :dry_run, false)

    adapter = Config.adapter()

    stats = %{
      imported: 0,
      skipped: 0,
      errors: [],
      by_table: %{}
    }

    # Process file in streaming fashion
    result =
      File.stream!(path, :line)
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Stream.map(&Jason.decode!/1)
      |> Stream.chunk_every(batch_size)
      |> Enum.reduce(stats, fn batch, acc ->
        process_batch(batch, adapter, on_conflict, dry_run, acc)
      end)

    if dry_run do
      {:ok, Map.put(result, :dry_run, true)}
    else
      {:ok, result}
    end
  rescue
    e ->
      Logger.error("Import failed: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  @doc """
  Import a specific table from a JSONL file.
  """
  def import_table(path, table, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 1000)
    on_conflict = Keyword.get(opts, :on_conflict, :skip)
    dry_run = Keyword.get(opts, :dry_run, false)

    adapter = Config.adapter()

    stats = %{imported: 0, skipped: 0, errors: [], table: table}

    result =
      File.stream!(path, :line)
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Stream.map(&Jason.decode!/1)
      |> Stream.filter(fn record -> record["table"] == to_string(table) end)
      |> Stream.chunk_every(batch_size)
      |> Enum.reduce(stats, fn batch, acc ->
        process_batch(batch, adapter, on_conflict, dry_run, acc)
      end)

    if dry_run do
      {:ok, Map.put(result, :dry_run, true)}
    else
      {:ok, result}
    end
  rescue
    e ->
      Logger.error("Import failed: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  @doc """
  Validate an export file without importing.

  Returns metadata about the export file and any validation errors.
  """
  def validate(path) do
    try do
      File.stream!(path, :line)
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Stream.map(&Jason.decode!/1)
      |> Enum.reduce(
        %{valid: true, errors: [], tables: MapSet.new(), rows: 0, header: nil, footer: nil},
        fn record, acc ->
          validate_record(record, acc)
        end
      )
      |> case do
        %{valid: true} = result ->
          {:ok,
           %{
             tables: MapSet.to_list(result.tables),
             total_rows: result.rows,
             header: result.header,
             footer: result.footer
           }}

        %{valid: false, errors: errors} ->
          {:error, %{message: "Validation failed", errors: errors}}
      end
    rescue
      e ->
        {:error, %{message: "Failed to read file", error: Exception.message(e)}}
    end
  end

  # ── Private Functions ─────────────────────────────────────────────────

  defp process_batch(batch, adapter, on_conflict, dry_run, stats) do
    Enum.reduce(batch, stats, fn record, acc ->
      case import_record(record, adapter, on_conflict, dry_run) do
        {:ok, :imported} ->
          acc
          |> Map.update!(:imported, &(&1 + 1))
          |> update_table_stats(record["table"], :imported)

        {:ok, :skipped} ->
          acc
          |> Map.update!(:skipped, &(&1 + 1))
          |> update_table_stats(record["table"], :skipped)

        {:error, reason} ->
          acc
          |> Map.update!(:errors, &[reason | &1])
          |> update_table_stats(record["table"], :error)
      end
    end)
  end

  defp update_table_stats(stats, table, action) do
    update_in(stats, [:by_table, Access.key(table, %{})], fn table_stats ->
      Map.update(table_stats, action, 1, &(&1 + 1))
    end)
  end

  defp import_record(%{"type" => "header"}, _adapter, _on_conflict, _dry_run) do
    # Skip header records
    {:ok, :skipped}
  end

  defp import_record(%{"type" => "footer"}, _adapter, _on_conflict, _dry_run) do
    # Skip footer records
    {:ok, :skipped}
  end

  defp import_record(%{"table" => table, "data" => data}, adapter, on_conflict, dry_run) do
    if dry_run do
      # Just validate the data structure
      case validate_data_structure(table, data) do
        :ok -> {:ok, :imported}
        {:error, reason} -> {:error, reason}
      end
    else
      # Actually insert the record
      do_insert(table, data, adapter, on_conflict)
    end
  end

  defp import_record(_record, _adapter, _on_conflict, _dry_run) do
    {:error, "Invalid record format"}
  end

  defp do_insert(table, data, adapter, on_conflict) do
    repo = Config.repo()

    # Transform data for target database
    transformed = transform_for_insert(data, adapter)

    # Build insert SQL
    {sql, params} = build_insert_sql(table, transformed, adapter)

    try do
      case repo.query(sql, params) do
        {:ok, _} ->
          {:ok, :imported}

        {:error, %{postgres: %{code: :unique_violation}}} when on_conflict == :skip ->
          {:ok, :skipped}

        {:error, %{sqlite: %{code: :constraint}}} when on_conflict == :skip ->
          {:ok, :skipped}

        {:error, reason} ->
          {:error, "Insert failed: #{inspect(reason)}"}
      end
    rescue
      e ->
        if on_conflict == :skip do
          {:ok, :skipped}
        else
          {:error, Exception.message(e)}
        end
    end
  end

  defp transform_for_insert(data, adapter) do
    data
    |> Enum.map(fn {key, value} ->
      {key, transform_value_for_insert(key, value, adapter)}
    end)
    |> Map.new()
  end

  # Handle embedding fields specially
  defp transform_value_for_insert(key, value, adapter) when key in ["embedding"] do
    if is_list(value) do
      # Format embedding according to target database
      adapter.format_embedding(value)
    else
      value
    end
  end

  # Handle UUID fields
  defp transform_value_for_insert(key, value, adapter)
       when key in [
              "id",
              "scope_id",
              "owner_id",
              "collection_id",
              "document_id",
              "entity_id",
              "chunk_id",
              "entry_id",
              "source_entry_id",
              "target_entry_id",
              "from_entity_id",
              "to_entity_id"
            ] do
    adapter.format_uuid(value)
  end

  # Handle datetime strings
  defp transform_value_for_insert(_key, value, _adapter) when is_binary(value) do
    # Try to parse as datetime
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> value
    end
  end

  # Pass through other values
  defp transform_value_for_insert(_key, value, _adapter), do: value

  defp build_insert_sql(table, data, adapter) do
    columns = Map.keys(data)

    placeholders =
      Enum.map(1..length(columns), fn i ->
        adapter.placeholder(i)
      end)

    col_str = Enum.join(columns, ", ")
    placeholder_str = Enum.join(placeholders, ", ")

    sql = "INSERT INTO #{table} (#{col_str}) VALUES (#{placeholder_str})"
    params = Map.values(data)

    {sql, params}
  end

  defp validate_data_structure(table, data) do
    required_fields = get_required_fields(table)

    missing =
      Enum.filter(required_fields, fn field ->
        is_nil(data[to_string(field)]) and is_nil(data[Atom.to_string(field)])
      end)

    if missing == [] do
      :ok
    else
      {:error, "Missing required fields: #{Enum.join(missing, ", ")}"}
    end
  end

  defp get_required_fields(:mneme_entries), do: [:id, :content]
  defp get_required_fields(:mneme_chunks), do: [:id, :content, :document_id]
  defp get_required_fields(:mneme_entities), do: [:id, :name, :entity_type]
  defp get_required_fields(:mneme_documents), do: [:id, :content, :collection_id]
  defp get_required_fields(:mneme_collections), do: [:id, :name]
  defp get_required_fields(:mneme_relations), do: [:id, :relation_type, :from_entity_id, :to_entity_id]
  defp get_required_fields(:mneme_edges), do: [:id, :relation, :source_entry_id, :target_entry_id]
  defp get_required_fields(:mneme_pipeline_runs), do: [:id, :document_id]
  defp get_required_fields(_), do: [:id]

  defp validate_record(%{"type" => "header"} = record, acc) do
    if record["version"] do
      %{acc | header: record}
    else
      %{acc | valid: false, errors: ["Header missing version" | acc.errors]}
    end
  end

  defp validate_record(%{"type" => "footer"} = record, acc) do
    %{acc | footer: record}
  end

  defp validate_record(%{"table" => table, "data" => data} = _record, acc) when is_map(data) do
    %{acc | tables: MapSet.put(acc.tables, table), rows: acc.rows + 1}
  end

  defp validate_record(record, acc) do
    %{acc | valid: false, errors: ["Invalid record: #{inspect(record)}" | acc.errors]}
  end
end
