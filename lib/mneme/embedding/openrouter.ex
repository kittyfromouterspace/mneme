defmodule Mneme.Embedding.OpenRouter do
  @moduledoc """
  Embedding provider using OpenRouter API.

  Supports Google, OpenAI, and other models available via OpenRouter.
  Default model: google/text-embedding-004 (768 dimensions).
  """
  @behaviour Mneme.EmbeddingProvider

  require Logger

  @default_model "google/text-embedding-004"
  @default_dimensions 768
  @batch_size 100
  @base_url "https://openrouter.ai/api/v1"

  @impl true
  def dimensions(opts) do
    Keyword.get(opts, :dimensions, @default_dimensions)
  end

  @impl true
  def generate(texts, opts) when is_list(texts) do
    api_key = Keyword.fetch!(opts, :api_key)
    model = Keyword.get(opts, :model, @default_model)
    base_url = Keyword.get(opts, :base_url, @base_url)

    texts
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce_while({:ok, [], %{tokens_used: 0}}, fn batch, {:ok, acc, usage_acc} ->
      case generate_batch(batch, api_key, model, base_url) do
        {:ok, embeddings, usage} ->
          merged_usage = %{tokens_used: usage_acc.tokens_used + (usage[:tokens_used] || 0)}
          {:cont, {:ok, acc ++ embeddings, merged_usage}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, embeddings, usage} ->
        # Store usage in process dict for pipeline to pick up
        Process.put(:mneme_last_embedding_usage, usage)
        {:ok, embeddings}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def embed(text, opts) when is_binary(text) do
    case generate([text], opts) do
      {:ok, [embedding]} -> {:ok, embedding}
      {:ok, []} -> {:error, :no_embedding_returned}
      {:error, reason} -> {:error, reason}
    end
  end

  defp generate_batch(texts, api_key, model, base_url) do
    url = "#{base_url}/embeddings"

    headers = [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"}
    ]

    body = %{"input" => texts, "model" => model}

    case Req.post(url, json: body, headers: headers, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: %{"data" => data} = resp_body}} ->
        embeddings =
          data
          |> Enum.sort_by(& &1["index"])
          |> Enum.map(& &1["embedding"])

        usage = extract_usage(resp_body)
        {:ok, embeddings, usage}

      {:ok, %{status: status, body: body}} ->
        Logger.error("OpenRouter embedding error (#{status}): #{inspect(body)}")
        {:error, "OpenRouter API returned status #{status}"}

      {:error, reason} ->
        Logger.error("OpenRouter embedding request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp extract_usage(%{"usage" => %{"total_tokens" => tokens}}) when is_integer(tokens), do: %{tokens_used: tokens}

  defp extract_usage(%{"usage" => %{"prompt_tokens" => tokens}}) when is_integer(tokens), do: %{tokens_used: tokens}

  defp extract_usage(_), do: %{tokens_used: 0}
end
