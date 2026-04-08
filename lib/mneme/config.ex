defmodule Mneme.Config do
  @moduledoc """
  Runtime configuration resolution for Mneme.

  The host application provides all configuration via `config :mneme`.
  Mneme never starts its own Repo, stores API keys, or makes assumptions
  about the host app's secret management.

  ## Credentials Resolution

  Instead of static API keys, Mneme uses a `:credentials_fn` callback that
  the host app provides. This function is called at runtime to fetch
  credentials from whatever secret system the host app uses.

  ## Example Configuration

      # Homunculus (uses SecretStore)
      config :mneme,
        repo: Homunculus.Repo,
        embedding: [
          provider: Mneme.Embedding.OpenRouter,
          credentials_fn: fn ->
            case Homunculus.SecretStore.get("openrouter", "api_key") do
              {:ok, key} -> %{api_key: key, model: "google/text-embedding-004", dimensions: 768}
              _ -> :disabled
            end
          end
        ]

      # Strategic Change Engine (uses LlmCredential)
      config :mneme,
        repo: StrategicChangeEngine.Repo,
        embedding: [
          provider: Mneme.Embedding.OpenRouter,
          credentials_fn: fn ->
            case StrategicChangeEngine.Admin.LlmCredential.active_for_provider(:openrouter, authorize?: false) do
              {:ok, cred} -> %{api_key: cred.api_key, model: "google/text-embedding-004", dimensions: 768}
              _ -> :disabled
            end
          end
        ]
  """

  @doc "The Ecto Repo module provided by the host app."
  def repo do
    Application.fetch_env!(:mneme, :repo)
  end

  @doc "Table name prefix for all Mneme tables."
  def table_prefix do
    Application.get_env(:mneme, :table_prefix, "mneme_")
  end

  @doc "Embedding provider module (implements Mneme.EmbeddingProvider)."
  def embedding_provider do
    config = Application.get_env(:mneme, :embedding, [])
    Keyword.get(config, :provider)
  end

  @doc """
  Resolve embedding credentials at runtime via the host app's secret system.

  Calls the `:credentials_fn` from config. Returns a map with at minimum
  `:api_key`, plus optional `:model`, `:base_url`, `:dimensions`.

  Returns `:disabled` if no credentials are available.
  """
  def embedding_credentials do
    config = Application.get_env(:mneme, :embedding, [])

    case Keyword.get(config, :credentials_fn) do
      fun when is_function(fun, 0) ->
        fun.()

      nil ->
        static_opts = Keyword.drop(config, [:provider, :credentials_fn])

        cond do
          Keyword.get(static_opts, :api_key) ->
            static_opts |> Map.new() |> Map.put(:api_key, Keyword.get(static_opts, :api_key))

          Keyword.get(static_opts, :mock) == true ->
            Map.new(static_opts)

          true ->
            :disabled
        end
    end
  end

  @doc """
  Build embedding opts by merging resolved credentials with static config.

  This is what gets passed to the embedding provider's generate/2 callback.
  """
  def embedding_opts do
    case embedding_credentials() do
      :disabled ->
        [disabled: true]

      %{} = creds ->
        Map.to_list(creds)
    end
  end

  @doc "Extraction provider module (implements Mneme.ExtractionProvider)."
  def extraction_provider do
    config = Application.get_env(:mneme, :extraction, [])
    Keyword.get(config, :provider, Mneme.Extraction.LlmJson)
  end

  @doc "Extraction provider options (includes llm_fn from host app)."
  def extraction_opts do
    config = Application.get_env(:mneme, :extraction, [])
    Keyword.delete(config, :provider)
  end

  @doc "Embedding vector dimensions (resolved from credentials or static config)."
  def dimensions do
    case embedding_credentials() do
      %{dimensions: d} when is_integer(d) ->
        d

      _ ->
        config = Application.get_env(:mneme, :embedding, [])
        Keyword.get(config, :dimensions, 1536)
    end
  end

  @doc "Check if embedding is available."
  def embedding_enabled? do
    embedding_provider() != nil && embedding_credentials() != :disabled
  end

  @doc "TaskSupervisor name for async operations."
  def task_supervisor do
    Application.get_env(:mneme, :task_supervisor, Mneme.TaskSupervisor)
  end
end
