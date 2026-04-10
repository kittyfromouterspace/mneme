defmodule Mneme.Learner.CodingAgent.Provider do
  @moduledoc """
  Behaviour for coding agent provider modules.

  Each provider knows how to read the data directory of a specific
  coding agent (Claude Code, Codex, Gemini CLI, etc.) and extract
  learnable events from it.

  ## Implementing a new provider

      defmodule Mneme.Learner.CodingAgent.MyAgent do
        @behaviour Mneme.Learner.CodingAgent.Provider

        @impl true
        def agent_name, do: :my_agent

        @impl true
        def data_paths, do: ["~/.my_agent"]

        @impl true
        def available? do
          data_paths()
          |> Enum.any?(fn p -> File.dir?(Path.expand(p)) end)
        end

        @impl true
        def fetch_events do
          # Read data dirs, return list of event maps
        end

        @impl true
        def extract(event) do
          # Convert event into an extract map
        end
      end
  """

  @doc "Unique atom name for this agent (e.g. :claude_code, :codex)."
  @callback agent_name() :: atom()

  @doc "List of data directory paths to probe (tilde-expanded)."
  @callback data_paths() :: [String.t()]

  @doc "Returns true if this agent's data directory exists on disk."
  @callback available?() :: boolean()

  @doc """
  Fetch all learnable events from this agent's data directories.

  Each event must include an `:agent` key set to `agent_name()`.
  Other keys are provider-specific.
  """
  @callback fetch_events() :: [map()]

  @doc """
  Fetch events with filtering options.

  ## Options

  - `:projects` — list of project slugs to include. If provided, only
    fetch events for these projects.
  - `:since` — map of `%{project_slug => iso8601_timestamp}` to only
    fetch events newer than the given timestamps.

  Providers should implement this for incremental learning support.
  Default falls back to `fetch_events/0` without filtering.
  """
  @callback fetch_events(opts :: keyword()) :: [map()]

  @doc """
  Extract a single event into a memory-ready extract map.

  Must return `{:ok, extract}` or `{:skip, reason}`.
  The extract map must contain: `:content`, `:entry_type`,
  `:emotional_valence`, `:tags`, `:metadata`.
  May also include `:half_life_days`, `:confidence`, `:summary`.
  """
  @callback extract(event :: map()) :: {:ok, map()} | {:skip, String.t()}

  @doc """
  Optional: batch-summarize events into synthesized insights.

  Default implementation in `CodingAgent` groups events by project
  and creates a `development_insight` entry when 2+ events exist.
  """
  @callback summarize(events :: [map()], scope_id :: String.t()) :: [map()]
end
