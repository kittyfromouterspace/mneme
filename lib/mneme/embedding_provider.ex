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

  @doc """
  Identifier for the model that will produce embeddings under the
  given opts. Used by the pipeline to record provenance alongside each
  vector. Returns `nil` when the provider can't (or doesn't want to)
  declare a stable id.
  """
  @callback model_id(opts :: keyword()) :: String.t() | nil

  @optional_callbacks [embed: 2, model_id: 1]

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

  @doc """
  Resolve the model id of the currently configured provider, or `nil`
  if the provider doesn't implement `model_id/1`.
  """
  def model_id(opts \\ []) do
    case resolve_provider(opts) do
      {:ok, provider, merged_opts} ->
        if function_exported?(provider, :model_id, 1) do
          provider.model_id(merged_opts)
        else
          nil
        end

      _ ->
        nil
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
