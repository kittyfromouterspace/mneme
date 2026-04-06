defmodule Mneme.Embedding.Mock do
  @behaviour Mneme.EmbeddingProvider

  @impl true
  def dimensions(_opts), do: 768

  @impl true
  def generate(texts, _opts) when is_list(texts) do
    embeddings = Enum.map(texts, &mock_embedding/1)
    {:ok, embeddings}
  end

  @impl true
  def embed(text, _opts) do
    {:ok, mock_embedding(text)}
  end

  defp mock_embedding(text) when is_binary(text) do
    hash = :crypto.hash(:sha256, text)
    bytes = :binary.bin_to_list(hash)

    Stream.cycle(bytes)
    |> Stream.take(768)
    |> Enum.map(fn b -> b / 255.0 * 2.0 - 1.0 end)
  end
end
