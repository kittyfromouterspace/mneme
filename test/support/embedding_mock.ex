defmodule Recollect.Embedding.Mock do
  @moduledoc false
  @behaviour Recollect.EmbeddingProvider

  @dimensions 1536
  @model_id "mock-1536"

  @impl true
  def dimensions(_opts), do: @dimensions

  @impl true
  def generate(texts, _opts) when is_list(texts) do
    embeddings = Enum.map(texts, &mock_embedding/1)
    {:ok, embeddings}
  end

  @impl true
  def embed(text, _opts) do
    {:ok, mock_embedding(text)}
  end

  @impl true
  def model_id(_opts), do: @model_id

  defp mock_embedding(text) when is_binary(text) do
    hash = :crypto.hash(:sha256, text)
    bytes = :binary.bin_to_list(hash)

    bytes
    |> Stream.cycle()
    |> Stream.take(@dimensions)
    |> Enum.map(fn b -> b / 255.0 * 2.0 - 1.0 end)
  end
end
