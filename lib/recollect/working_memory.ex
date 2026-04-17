defmodule Recollect.WorkingMemory do
  @moduledoc """
  Working memory layer (Tier 0).

  A bounded buffer for current-session notes, separate from long-term
  knowledge. Session-scoped, no embeddings, importance-based eviction.

  Implemented as a GenServer per scope via DynamicSupervisor.
  """

  alias Recollect.WorkingMemory.Server

  @default_max 20

  @doc """
  Push a new entry into working memory for a scope.

  Starts the scope GenServer if not running. If the scope exceeds
  max entries, the lowest-importance entry is evicted.

  ## Options
  - `:importance` - Float 0.0-1.0, default 0.0
  - `:metadata` - Map, default %{}
  """
  def push(scope_id, content, opts \\ []) do
    pid = ensure_scope(scope_id)
    Server.push(pid, content, opts)
  end

  @doc """
  Read working memory entries for a scope, sorted by importance DESC.
  """
  def read(scope_id, opts \\ []) do
    case whereis_scope(scope_id) do
      nil -> {:ok, []}
      pid -> Server.read(pid, opts)
    end
  end

  @doc """
  Clear working memory for a scope and terminate the GenServer.
  """
  def clear(scope_id) do
    case whereis_scope(scope_id) do
      nil ->
        {:ok, 0}

      pid ->
        count = Server.clear(pid)
        DynamicSupervisor.terminate_child(working_memory_supervisor(), pid)
        {:ok, count}
    end
  end

  @doc "Semantic alias for clear, used at session boundaries."
  def flush(scope_id), do: clear(scope_id)

  @doc """
  Load handoff into working memory on session resume.

  Pushes handoff items as high-importance entries so the session
  can immediately continue from where it left off.
  """
  def load_handoff(scope_id) do
    alias Recollect.Telemetry

    case Recollect.Handoff.get(scope_id) do
      {:ok, handoff} when not is_nil(handoff) ->
        # Push handoff items to working memory
        push(scope_id, "Handoff: #{handoff.what}", importance: 0.95)

        Enum.each(handoff.next, fn step ->
          push(scope_id, "Next: #{step}", importance: 0.8)
        end)

        Enum.each(handoff.artifacts, fn artifact ->
          push(scope_id, "Artifact: #{artifact}", importance: 0.7)
        end)

        Telemetry.event(
          [:recollect, :handoff, :load, :stop],
          %{next_count: length(handoff.next), artifacts_count: length(handoff.artifacts)},
          %{scope_id: scope_id}
        )

        {:ok,
         %{
           what: handoff.what,
           next_count: length(handoff.next),
           artifacts_count: length(handoff.artifacts)
         }}

      _ ->
        {:ok, nil}
    end
  end

  @doc "List all active scope IDs."
  def active_scopes do
    working_memory_supervisor()
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_, pid, _, _} ->
      case Server.scope_id(pid) do
        {:ok, scope_id} -> scope_id
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp ensure_scope(scope_id) do
    case whereis_scope(scope_id) do
      nil -> start_scope(scope_id)
      pid -> pid
    end
  end

  defp start_scope(scope_id) do
    max =
      :recollect
      |> Application.get_env(:working_memory, [])
      |> Keyword.get(:max_entries_per_scope, @default_max)

    child_spec = {Server, scope_id: scope_id, max_entries: max}

    case DynamicSupervisor.start_child(working_memory_supervisor(), child_spec) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp whereis_scope(scope_id) do
    working_memory_registry()
    |> Registry.lookup(scope_id)
    |> case do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp working_memory_supervisor, do: Recollect.WorkingMemory.Supervisor
  defp working_memory_registry, do: Recollect.WorkingMemory.Registry
end
