defmodule Mneme.Learner.CodingAgent.Provider do
  @moduledoc """
  Behaviour for coding agent provider modules.

  Each provider knows how to read the data directory of a specific
  coding agent (Claude Code, Codex, Gemini CLI, etc.) and extract
  learnable events from it.

  Providers receive a `config` map containing at minimum
  `%{data_paths: [String.t()]}`. When no config is supplied,
  providers fall back to their `default_data_paths/0`.

  ## Implementing a new provider

      defmodule Mneme.Learner.CodingAgent.MyAgent do
        @behaviour Mneme.Learner.CodingAgent.Provider

        @impl true
        def agent_name, do: :my_agent

        @impl true
        def default_data_paths, do: ["~/.my_agent"]

        @impl true
        def available?(config) do
          resolve_paths(config)
          |> Enum.any?(fn p -> File.dir?(Path.expand(p)) end)
        end

        @impl true
        def fetch_events(config), do: fetch_events(config, [])

        @impl true
        def fetch_events(config, _opts) do
          base = hd(resolve_paths(config)) |> Path.expand()
          # Read data dirs, return list of event maps
        end

        @impl true
        def extract(event) do
          # Convert event into an extract map
        end

        defp resolve_paths(%{data_paths: [_ | _] = paths}), do: paths
        defp resolve_paths(_), do: default_data_paths()
      end
  """

  @type config :: %{data_paths: [String.t()]}

  @doc "Unique atom name for this agent (e.g. :claude_code, :codex)."
  @callback agent_name() :: atom()

  @doc "Default data directory paths (tilde-expanded). Used when no config is injected."
  @callback default_data_paths() :: [String.t()]

  @doc "Returns true if this agent's data directory exists on disk."
  @callback available?(config()) :: boolean()

  @doc """
  Fetch all learnable events from this agent's data directories.

  Each event must include an `:agent` key set to `agent_name()`.
  """
  @callback fetch_events(config()) :: [map()]

  @doc """
  Fetch events with filtering options.

  ## Options

  - `:projects` — list of project slugs to include. If provided, only
    fetch events for these projects.
  - `:since` — map of `%{project_slug => iso8601_timestamp}` to only
    fetch events newer than the given timestamps.
  """
  @callback fetch_events(config(), opts :: keyword()) :: [map()]

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
