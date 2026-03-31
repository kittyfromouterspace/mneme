defmodule Mneme.EmbeddingProvider do
  @moduledoc """
  Behaviour for embedding providers.

  Implementations generate vector embeddings for text.
  The host app configures which provider to use and provides
  credentials via a `:credentials_fn` callback.
  """

  @doc "Number of dimensions in the embedding vectors."
  @callback dimensions(opts :: keyword()) :: pos_integer()

  @doc """
  Generate embeddings for a list of texts.

  Returns `{:ok, [[float()]]}` where each inner list is a vector,
  or `{:error, reason}`.
  """
  @callback generate(texts :: [String.t()], opts :: keyword()) ::
              {:ok, [[float()]]} | {:error, term()}

  @doc """
  Generate a single embedding for a text string.

  Convenience wrapper — delegates to `generate/2` by default.
  """
  @callback embed(text :: String.t(), opts :: keyword()) ::
              {:ok, [float()]} | {:error, term()}

  @optional_callbacks [embed: 2]

  @doc "Generate embedding for a single text using the configured provider."
  def embed(text, opts \\ []) do
    with {:ok, provider, merged_opts} <- resolve_provider(opts) do
      if function_exported?(provider, :embed, 2) do
        provider.embed(text, merged_opts)
      else
        case provider.generate([text], merged_opts) do
          {:ok, [embedding]} -> {:ok, embedding}
          {:ok, []} -> {:error, :no_embedding_returned}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  @doc "Generate embeddings for multiple texts using the configured provider."
  def generate(texts, opts \\ []) do
    with {:ok, provider, merged_opts} <- resolve_provider(opts) do
      provider.generate(texts, merged_opts)
    end
  end

  defp resolve_provider(opts) do
    provider = Mneme.Config.embedding_provider()

    if provider == nil do
      {:error, :no_embedding_provider}
    else
      config_opts = Mneme.Config.embedding_opts()

      case config_opts do
        [disabled: true] ->
          {:error, :embedding_disabled}

        _ ->
          {:ok, provider, Keyword.merge(config_opts, opts)}
      end
    end
  end
end
