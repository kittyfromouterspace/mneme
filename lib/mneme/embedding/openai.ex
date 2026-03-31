defmodule Mneme.Embedding.OpenAI do
  @moduledoc """
  Embedding provider using OpenAI API directly.
  Default model: text-embedding-3-large (3072 dimensions).
  """
  @behaviour Mneme.EmbeddingProvider

  require Logger

  @default_model "text-embedding-3-large"
  @default_dimensions 3072
  @batch_size 100

  @impl true
  def dimensions(opts) do
    Keyword.get(opts, :dimensions, @default_dimensions)
  end

  @impl true
  def generate(texts, opts) when is_list(texts) do
    api_key = Keyword.fetch!(opts, :api_key)
    model = Keyword.get(opts, :model, @default_model)

    texts
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc} ->
      case generate_batch(batch, api_key, model) do
        {:ok, embeddings} -> {:cont, {:ok, acc ++ embeddings}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @impl true
  def embed(text, opts) when is_binary(text) do
    case generate([text], opts) do
      {:ok, [embedding]} -> {:ok, embedding}
      {:ok, []} -> {:error, :no_embedding_returned}
      {:error, reason} -> {:error, reason}
    end
  end

  defp generate_batch(texts, api_key, model) do
    headers = [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"}
    ]

    body = %{"input" => texts, "model" => model}

    case Req.post("https://api.openai.com/v1/embeddings",
           json: body,
           headers: headers,
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: %{"data" => data}}} ->
        embeddings =
          data
          |> Enum.sort_by(& &1["index"])
          |> Enum.map(& &1["embedding"])

        {:ok, embeddings}

      {:ok, %{status: status, body: body}} ->
        Logger.error("OpenAI embedding error (#{status}): #{inspect(body)}")
        {:error, "OpenAI API returned status #{status}"}

      {:error, reason} ->
        Logger.error("OpenAI embedding request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
