defmodule Mneme.Embedding.Ollama do
  @moduledoc """
  Embedding provider using local Ollama instance.
  Default model: nomic-embed-text (768 dimensions).
  """
  @behaviour Mneme.EmbeddingProvider

  require Logger

  @default_model "nomic-embed-text"
  @default_dimensions 768
  @default_base_url "http://localhost:11434"

  @impl true
  def dimensions(opts) do
    Keyword.get(opts, :dimensions, @default_dimensions)
  end

  @impl true
  def generate(texts, opts) when is_list(texts) do
    base_url = Keyword.get(opts, :base_url, @default_base_url)
    model = Keyword.get(opts, :model, @default_model)

    # Ollama doesn't support batch — process one at a time
    Enum.reduce_while(texts, {:ok, []}, fn text, {:ok, acc} ->
      case do_embed(text, base_url, model) do
        {:ok, embedding} -> {:cont, {:ok, acc ++ [embedding]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @impl true
  def embed(text, opts) when is_binary(text) do
    base_url = Keyword.get(opts, :base_url, @default_base_url)
    model = Keyword.get(opts, :model, @default_model)
    do_embed(text, base_url, model)
  end

  defp do_embed(text, base_url, model) do
    url = "#{base_url}/api/embed"
    body = %{model: model, input: text}

    case Req.post(url, json: body, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: %{"embeddings" => [embedding | _]}}} ->
        {:ok, embedding}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Ollama embedding error (#{status}): #{inspect(body)}")
        {:error, "Ollama returned status #{status}"}

      {:error, reason} ->
        Logger.error("Ollama embedding request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
