defmodule Mneme.Embedding.Local do
  @moduledoc """
  Local embedding provider using Bumblebee with sentence-transformers/all-MiniLM-L6-v2.

  This is the default embedding provider for Mneme. It runs entirely
  locally — no API keys or external services required. Model weights are
  downloaded from HuggingFace Hub on first use and cached on disk.

  ## Requirements

  Add to your `mix.exs` dependencies:

      {:bumblebee, "~> 0.6.0"},
      {:exla, ">= 0.0.0"}

  And configure Nx to use EXLA as the default backend in your
  `config/config.exs`:

      config :nx, default_backend: EXLA.Backend

  ## Configuration

  The local provider is used by default when no other provider is
  configured. You can explicitly select it:

      config :mneme,
        embedding: [
          provider: Mneme.Embedding.Local
        ]

  Options can be passed via `:local_embedding`:

      config :mneme, :local_embedding,
        model: "sentence-transformers/all-MiniLM-L6-v2",
        compile: [batch_size: 32, sequence_length: 128]

  ## Overriding with another provider

  To use a different embedding provider (e.g. an API-based one), set
  the `:provider` key:

      config :mneme,
        embedding: [
          provider: Mneme.Embedding.OpenRouter,
          credentials_fn: fn ->
            %{api_key: "...", model: "google/text-embedding-004", dimensions: 768}
          end
        ]
  """

  @behaviour Mneme.EmbeddingProvider

  @default_model "sentence-transformers/all-MiniLM-L6-v2"
  @dimensions 384
  @model_id "all-MiniLM-L6-v2"

  @doc "The registered name of the Nx.Serving process."
  def serving_name, do: {__MODULE__, :serving}

  @doc "Returns the embedding dimensions for the configured model."
  def dimensions, do: @dimensions

  @doc """
  Build the Nx.Serving for the embedding model.

  Called by `Mneme.Application` during startup. Downloads model weights
  from HuggingFace Hub on first call (cached afterward).

  Returns `{:ok, serving}` or `{:error, reason}`.
  """
  def build_serving do
    if deps_available?() do
      do_build_serving()
    else
      {:error,
       ":bumblebee and :exla are not installed. Add them to your mix.exs dependencies to use Mneme.Embedding.Local."}
    end
  end

  defp do_build_serving do
    config = Application.get_env(:mneme, :local_embedding, [])
    model_id = Keyword.get(config, :model, @default_model)
    compile = Keyword.get(config, :compile, batch_size: 32, sequence_length: 128)
    defn_options = Keyword.get(config, :defn_options, default_defn_options())

    with {:ok, model_info} <- Bumblebee.load_model({:hf, model_id}),
         {:ok, tokenizer} <- Bumblebee.load_tokenizer({:hf, model_id}) do
      serving =
        Bumblebee.Text.text_embedding(model_info, tokenizer,
          output_pool: :mean_pooling,
          embedding_processor: :l2_norm,
          compile: compile,
          defn_options: defn_options
        )

      {:ok, serving}
    end
  end

  defp default_defn_options do
    if Code.ensure_loaded?(EXLA) do
      [compiler: EXLA]
    else
      []
    end
  end

  @impl true
  def dimensions(_opts), do: @dimensions

  @impl true
  def generate(texts, _opts) when is_list(texts) do
    if serving_running?() do
      %{embedding: tensor} = Nx.Serving.batched_run(serving_name(), texts)
      n = elem(Nx.shape(tensor), 0)
      embeddings = for i <- 0..(n - 1), do: Nx.to_flat_list(tensor[i])
      {:ok, embeddings}
    else
      {:error, "Local embedding serving is not running. Ensure :bumblebee and :exla are in your dependencies."}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @impl true
  def embed(text, opts) do
    case generate([text], opts) do
      {:ok, [embedding]} -> {:ok, embedding}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def model_id(_opts), do: @model_id

  defp serving_running? do
    case GenServer.whereis(serving_name()) do
      nil -> false
      _pid -> true
    end
  end

  defp deps_available? do
    Code.ensure_loaded?(Bumblebee) and Code.ensure_loaded?(Nx) and
      Code.ensure_loaded?(Bumblebee.Text)
  end
end
