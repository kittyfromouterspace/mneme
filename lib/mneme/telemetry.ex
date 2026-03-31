defmodule Mneme.Telemetry do
  @moduledoc """
  Telemetry events emitted by Mneme.

  ## Events

  ### Knowledge Operations
  - `[:mneme, :remember, :start]` — Entry creation started
  - `[:mneme, :remember, :stop]` — Entry created successfully
  - `[:mneme, :remember, :exception]` — Entry creation failed

  ### Search
  - `[:mneme, :search, :start]` — Search started
  - `[:mneme, :search, :stop]` — Search completed
  - `[:mneme, :search, :exception]` — Search failed

  ### Vector Search
  - `[:mneme, :search, :vector, :stop]` — Vector search completed

  ### Pipeline
  - `[:mneme, :pipeline, :start]` — Pipeline started
  - `[:mneme, :pipeline, :stop]` — Pipeline completed
  - `[:mneme, :pipeline, :exception]` — Pipeline failed

  ### Embedding
  - `[:mneme, :embed, :stop]` — Embedding completed

  ### Extraction
  - `[:mneme, :extract, :stop]` — Entity extraction completed

  ### Maintenance
  - `[:mneme, :decay, :stop]` — Decay pass completed

  All `:stop` events include `%{duration: native_time}` in measurements.
  All events include relevant metadata (scope_id, owner_id, tier, etc.).
  """

  @doc """
  Execute a function within a telemetry span.

  Emits `event_prefix ++ [:start]` before and `event_prefix ++ [:stop]` after.
  On exception, emits `event_prefix ++ [:exception]` and re-raises.

  The function result is passed through `extract_measurements/1` to pull
  counts and status into the stop measurements.
  """
  def span(event_prefix, metadata, fun) when is_list(event_prefix) and is_function(fun, 0) do
    start_time = System.monotonic_time()
    :telemetry.execute(event_prefix ++ [:start], %{system_time: System.system_time()}, metadata)

    try do
      result = fun.()
      duration = System.monotonic_time() - start_time

      {measurements, result_metadata} = extract_measurements(result)

      :telemetry.execute(
        event_prefix ++ [:stop],
        Map.merge(%{duration: duration}, measurements),
        Map.merge(metadata, result_metadata)
      )

      result
    rescue
      e ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          event_prefix ++ [:exception],
          %{duration: duration},
          Map.merge(metadata, %{kind: :error, reason: e, stacktrace: __STACKTRACE__})
        )

        reraise e, __STACKTRACE__
    catch
      kind, reason ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          event_prefix ++ [:exception],
          %{duration: duration},
          Map.merge(metadata, %{kind: kind, reason: reason})
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp extract_measurements({:ok, %{entries: entries, chunks: chunks, entities: entities}}) do
    {%{
       result_count: length(entries || []) + length(chunks || []),
       entries_count: length(entries || []),
       chunks_count: length(chunks || []),
       entities_count: length(entities || [])
     }, %{status: :ok}}
  end

  defp extract_measurements({:ok, %Mneme.Schema.Entry{}}), do: {%{}, %{status: :ok}}

  defp extract_measurements({:ok, count}) when is_integer(count),
    do: {%{count: count}, %{status: :ok}}

  defp extract_measurements({:ok, _}), do: {%{}, %{status: :ok}}
  defp extract_measurements({:error, _}), do: {%{}, %{status: :error}}
  defp extract_measurements(_), do: {%{}, %{}}

  @doc "Emit a simple event (no span, just measurements + metadata)."
  def event(name, measurements \\ %{}, metadata \\ %{}) do
    :telemetry.execute(name, measurements, metadata)
  end
end
