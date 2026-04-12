defmodule Mneme.Application do
  @moduledoc false
  use Application

  alias Mneme.Embedding.Local

  require Logger

  @impl true
  def start(_type, _args) do
    init_persistent_term()
    init_ets_tables()

    children = [
      {Task.Supervisor, name: Mneme.TaskSupervisor},
      {Registry, keys: :unique, name: Mneme.WorkingMemory.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Mneme.WorkingMemory.Supervisor},
      Mneme.RetrievalCounter
    ]

    children = maybe_add_local_embedding_serving(children)

    opts = [strategy: :one_for_one, name: Mneme.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_add_local_embedding_serving(children) do
    if Mneme.Config.embedding_provider() == Local do
      case Local.build_serving() do
        {:ok, serving} ->
          child =
            {Nx.Serving, serving: serving, name: Local.serving_name(), batch_timeout: 100}

          [child | children]

        {:error, reason} ->
          Logger.warning("Mneme: local embedding serving could not initialize: #{inspect(reason)}")
          children
      end
    else
      children
    end
  end

  defp init_persistent_term do
    emotional_valence = Application.get_env(:mneme, :emotional_valence, [])

    multipliers =
      Keyword.get(emotional_valence, :multipliers, %{
        "neutral" => 1.0,
        "positive" => 1.3,
        "negative" => 1.5,
        "critical" => 2.0
      })

    :persistent_term.put({:mneme, :emotional_multipliers}, multipliers)
  end

  defp init_ets_tables do
    Mneme.OutcomeTracker.init()
    Mneme.SchemaIndex.init()
  end
end
