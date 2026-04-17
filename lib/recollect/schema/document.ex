defmodule Recollect.Schema.Document do
  @moduledoc """
  Source content record. Tracks original artifacts/conversations being indexed.
  Content hash enables deduplication — unchanged documents skip re-processing.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "recollect_documents" do
    field(:title, :string)
    field(:content, :string)
    field(:content_hash, :string)
    field(:source_type, :string, default: "manual")
    field(:source_id, :string)
    field(:source_version, :string)
    field(:status, :string, default: "pending")
    field(:token_count, :integer, default: 0)
    field(:metadata, :map, default: %{})
    field(:owner_id, :binary_id)
    field(:scope_id, :binary_id)

    belongs_to(:collection, Recollect.Schema.Collection, type: :binary_id)

    has_many(:chunks, Recollect.Schema.Chunk)

    timestamps()
  end

  def changeset(document, attrs) do
    document
    |> cast(attrs, [
      :title,
      :content,
      :content_hash,
      :source_type,
      :source_id,
      :source_version,
      :status,
      :token_count,
      :metadata,
      :owner_id,
      :scope_id,
      :collection_id
    ])
    |> validate_required([:content, :content_hash, :owner_id, :collection_id])
    |> validate_inclusion(:source_type, ~w(artifact conversation manual))
    |> validate_inclusion(:status, ~w(pending processing ready failed))
    |> unique_constraint([:collection_id, :source_type, :source_id])
  end
end
