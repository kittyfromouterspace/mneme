defmodule Mneme.Schema.Chunk do
  @moduledoc """
  Text fragment with vector embedding, created by the Chunker.
  Preserves section hierarchy and paragraph boundaries.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "mneme_chunks" do
    field(:sequence, :integer)
    field(:content, :string)
    field(:embedding, Pgvector.Ecto.Vector)
    field(:token_count, :integer, default: 0)
    field(:start_offset, :integer, default: 0)
    field(:end_offset, :integer, default: 0)
    field(:metadata, :map, default: %{})
    field(:owner_id, :binary_id)
    field(:scope_id, :binary_id)

    belongs_to(:document, Mneme.Schema.Document, type: :binary_id)

    timestamps(updated_at: false)
  end

  def changeset(chunk, attrs) do
    chunk
    |> cast(attrs, [
      :sequence,
      :content,
      :embedding,
      :token_count,
      :start_offset,
      :end_offset,
      :metadata,
      :owner_id,
      :scope_id,
      :document_id
    ])
    |> validate_required([:content, :document_id, :owner_id])
  end
end
