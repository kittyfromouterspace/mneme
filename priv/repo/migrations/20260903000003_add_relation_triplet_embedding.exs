defmodule Recollect.Repo.Migrations.AddRelationTripletEmbedding do
  @moduledoc """
  Adds the triplet embedding columns referenced by
  `Recollect.Schema.Relation` (`triplet_embedding`, `triplet_embedding_model_id`)
  so relation triples ("from —relation_type→ to") can be embedded and
  searched as a unit. Mirrors the 1536-dim columns on chunks/entities/entries.
  """
  use Ecto.Migration

  def up do
    alter table(:recollect_relations) do
      add(:triplet_embedding, :vector, size: 1536)
      add(:triplet_embedding_model_id, :string)
    end

    execute("""
    CREATE INDEX recollect_relations_triplet_embedding_idx ON recollect_relations
    USING hnsw (triplet_embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS recollect_relations_triplet_embedding_idx")

    alter table(:recollect_relations) do
      remove(:triplet_embedding)
      remove(:triplet_embedding_model_id)
    end
  end
end
