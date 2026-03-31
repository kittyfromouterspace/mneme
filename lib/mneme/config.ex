defmodule Mneme.Config do
  @moduledoc """
  Runtime configuration resolution for Mneme.

  The host application provides all configuration via `config :mneme`.
  Mneme never starts its own Repo or makes assumptions about the host app.
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

  @doc "Embedding provider options."
  def embedding_opts do
    config = Application.get_env(:mneme, :embedding, [])
    Keyword.drop(config, [:provider])
  end

  @doc "Extraction provider module (implements Mneme.ExtractionProvider)."
  def extraction_provider do
    config = Application.get_env(:mneme, :extraction, [])
    Keyword.get(config, :provider, Mneme.Extraction.LlmJson)
  end

  @doc "Extraction provider options."
  def extraction_opts do
    config = Application.get_env(:mneme, :extraction, [])
    Keyword.drop(config, [:provider])
  end

  @doc "Embedding vector dimensions (must match provider)."
  def dimensions do
    config = Application.get_env(:mneme, :embedding, [])
    Keyword.get(config, :dimensions, 768)
  end

  @doc "TaskSupervisor name for async operations."
  def task_supervisor do
    Application.get_env(:mneme, :task_supervisor, Mneme.TaskSupervisor)
  end
end
