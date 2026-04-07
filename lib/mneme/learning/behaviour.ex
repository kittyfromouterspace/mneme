defmodule Mneme.Learner do
  @moduledoc """
  Behaviour for learning modules that extract knowledge from external sources.

  Each learner implements this behaviour to provide a source of knowledge
  that can be automatically ingested into Mneme's memory.
  """

  @doc """
  Example implementation:

      defmodule MyApp.Learner.CI do
        @behaviour Mneme.Learner
        
        @impl true
        def source, do: :ci
        
        @impl true
        def fetch_since(since, scope_id) do
          # Fetch CI failures since the given date
        end
        
        @impl true
        def extract(event) do
          {:ok, %{
            content: "CI Failure: \#{event.failure_message}",
            entry_type: :observation,
            emotional_valence: :negative,
            tags: ["ci", "failure", event.workflow],
            metadata: %{source: :ci, job_id: event.id}
          }}
        end
      end
  end

  @doc \"""
  Return the source name (e.g., :git, :terminal, :ci).
  """
  @callback source() :: atom()

  @doc """
  Fetch new events/items to learn from since the last check.

  ## Parameters
  - `since` - DateTime or string (e.g., "2024-01-01")
  - `scope_id` - The scope to learn for

  ## Returns
  - `{:ok, [event]}` - List of events to process
  - `{:error, reason}` - If fetching fails
  """
  @callback fetch_since(since :: DateTime.t() | String.t(), scope_id :: binary()) ::
              {:ok, [map()]} | {:error, term()}

  @doc """
  Extract learnable content from an event.

  ## Parameters
  - `event` - An event map from fetch_since

  ## Returns
  - `{:ok, extract}` - Extract map with :content, :entry_type, :emotional_valence, :tags, :metadata
  - `{:skip, reason}` - Skip this event (not learnable)
  - `{:error, term}` - Processing error
  """
  @callback extract(event :: map()) :: {:ok, map()} | {:skip, binary()} | {:error, term()}

  @doc """
  Detect patterns across multiple events (optional).

  Called with a batch of events to find cross-event patterns like migrations.

  ## Returns
  - List of pattern maps with :type, :events, :summary
  """
  @callback detect_patterns([map()]) :: [map()]

  @type extract :: %{
          required(:content) => binary(),
          required(:entry_type) => atom(),
          required(:emotional_valence) => atom(),
          required(:tags) => [binary()],
          required(:metadata) => map()
        }

  @type pattern :: %{
          required(:type) => atom(),
          required(:events) => [map()],
          required(:summary) => binary()
        }
end
