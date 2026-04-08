defmodule Mneme.Repo.Migrations.EmbeddingModelIdAnd1536Dim do
  @moduledoc """
  Phase 4 of worth's LLM provider abstraction. Two changes:

  1. Migrate `embedding` columns on `mneme_chunks`, `mneme_entities`, and
     `mneme_entries` from `vector(768)` to `vector(1536)` so we can use
     `text-embedding-3-small` (and any other 1536-dim provider) as the
     default. **This is destructive**: existing embeddings cannot be
     resized in place, so we drop and recreate the column. All previously
     stored embeddings become NULL and must be re-embedded via
     `Mneme.Maintenance.Reembed`.

  2. Add a nullable `embedding_model_id` text column to all three tables
     so the model that produced each embedding is recorded. This lets
     Reembed target only stale-model rows when the configured model
     changes.

  HNSW indexes on the embedding column are dropped and recreated against
  the new 1536-dim column.
  """
  use Ecto.Migration

  def up do
    execute("DROP INDEX IF EXISTS mneme_chunks_embedding_idx")
    execute("DROP INDEX IF EXISTS mneme_entities_embedding_idx")
    execute("DROP INDEX IF EXISTS mneme_entries_embedding_idx")

    alter table(:mneme_chunks) do
      remove(:embedding)
      add(:embedding, :vector, size: 1536)
      add(:embedding_model_id, :string)
    end

    alter table(:mneme_entities) do
      remove(:embedding)
      add(:embedding, :vector, size: 1536)
      add(:embedding_model_id, :string)
    end

    alter table(:mneme_entries) do
      remove(:embedding)
      add(:embedding, :vector, size: 1536)
      add(:embedding_model_id, :string)
    end

    execute("""
    CREATE INDEX mneme_chunks_embedding_idx ON mneme_chunks
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    """)

    execute("""
    CREATE INDEX mneme_entities_embedding_idx ON mneme_entities
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    """)

    execute("""
    CREATE INDEX mneme_entries_embedding_idx ON mneme_entries
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS mneme_chunks_embedding_idx")
    execute("DROP INDEX IF EXISTS mneme_entities_embedding_idx")
    execute("DROP INDEX IF EXISTS mneme_entries_embedding_idx")

    alter table(:mneme_chunks) do
      remove(:embedding)
      remove(:embedding_model_id)
      add(:embedding, :vector, size: 768)
    end

    alter table(:mneme_entities) do
      remove(:embedding)
      remove(:embedding_model_id)
      add(:embedding, :vector, size: 768)
    end

    alter table(:mneme_entries) do
      remove(:embedding)
      remove(:embedding_model_id)
      add(:embedding, :vector, size: 768)
    end

    execute("""
    CREATE INDEX mneme_chunks_embedding_idx ON mneme_chunks
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    """)

    execute("""
    CREATE INDEX mneme_entities_embedding_idx ON mneme_entities
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    """)

    execute("""
    CREATE INDEX mneme_entries_embedding_idx ON mneme_entries
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    """)
  end
end
