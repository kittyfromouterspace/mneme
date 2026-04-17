defmodule Recollect.Embedding.OpenRouter do
  @moduledoc """
  OpenRouter embedding provider.

  Uses OpenRouter's `/api/v1/embeddings` endpoint (OpenAI-compatible).
  Requires `OPENROUTER_API_KEY` environment variable or configured `:api_key`.
  """

  @behaviour Recollect.EmbeddingProvider

  @default_model "openai/text-embedding-3-small"
  @default_dimensions 1536
  @api_url "https://openrouter.ai/api/v1/embeddings"

  @impl true
  def dimensions(opts), do: Keyword.get(opts, :dimensions, @default_dimensions)

  @impl true
  def generate(texts, opts) when is_list(texts) do
    api_key = resolve_api_key(opts)
    model = Keyword.get(opts, :model, @default_model)

    if api_key == nil or api_key == "" do
      {:error, "OPENROUTER_API_KEY not set"}
    else
      body = %{
        model: model,
        input: texts
      }

      headers = [
        {"Authorization", "Bearer #{api_key}"},
        {"Content-Type", "application/json"},
        {"HTTP-Referer", "https://github.com/lenzg/worth"},
        {"X-Title", "worth"}
      ]

      case Req.post(@api_url, json: body, headers: headers, receive_timeout: 30_000) do
        {:ok, %{status: 200, body: %{"data" => data}}} when is_list(data) ->
          embeddings =
            Enum.map(data, fn item ->
              item["embedding"] || item[:embedding]
            end)

          {:ok, embeddings}

        {:ok, %{status: status, body: body}} ->
          {:error, "OpenRouter embeddings API returned HTTP #{status}: #{inspect(body)}"}

        {:error, exception} ->
          {:error, "OpenRouter embeddings request failed: #{Exception.message(exception)}"}
      end
    end
  end

  @impl true
  def embed(text, opts) do
    case generate([text], opts) do
      {:ok, [embedding]} -> {:ok, embedding}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def model_id(opts) do
    Keyword.get(opts, :model, @default_model)
  end

  defp resolve_api_key(opts) do
    case Keyword.get(opts, :api_key) || Keyword.get(opts, :credentials_fn) do
      nil ->
        System.get_env("OPENROUTER_API_KEY")

      {:env, var} ->
        System.get_env(var)

      fun when is_function(fun, 0) ->
        case fun.() do
          %{api_key: key} -> key
          %{"api_key" => key} -> key
          _ -> nil
        end

      key when is_binary(key) ->
        key

      _ ->
        nil
    end
  end
end
