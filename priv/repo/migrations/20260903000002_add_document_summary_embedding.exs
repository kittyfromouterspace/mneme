defmodule Recollect.Repo.Migrations.AddDocumentSummaryEmbedding do
  @moduledoc """
  Document summary retrieval tier (B-1366): a short LLM-generated gist per
  document plus its embedding, so a gist-level query can surface the
  document's top chunks even when no individual chunk matches well.

  `summary_embedding` mirrors the existing 1536-dim embedding columns and
  gets the same HNSW index treatment.
  """
  use Ecto.Migration

  def up do
    alter table(:recollect_documents) do
      add(:summary, :text)
      add(:summary_embedding, :vector, size: 1536)
    end

    execute("""
    CREATE INDEX recollect_documents_summary_embedding_idx ON recollect_documents
    USING hnsw (summary_embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS recollect_documents_summary_embedding_idx")

    alter table(:recollect_documents) do
      remove(:summary)
      remove(:summary_embedding)
    end
  end
end
