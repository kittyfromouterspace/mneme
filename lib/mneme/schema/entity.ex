defmodule Mneme.Schema.Entity do
  @moduledoc """
  Named entity extracted from chunks via LLM.
  10 entity types with mention counting and prominence tracking.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @entity_types ~w(concept person goal obstacle domain strategy emotion place event tool)

  schema "mneme_entities" do
    field(:name, :string)
    field(:entity_type, :string)
    field(:description, :string)
    field(:properties, :map, default: %{})
    field(:mention_count, :integer, default: 1)
    field(:first_seen_at, :utc_datetime_usec)
    field(:last_seen_at, :utc_datetime_usec)
    field(:embedding, Pgvector.Ecto.Vector)
    field(:owner_id, :binary_id)
    field(:scope_id, :binary_id)

    belongs_to(:collection, Mneme.Schema.Collection, type: :binary_id)

    timestamps()
  end

  def entity_types, do: @entity_types

  def changeset(entity, attrs) do
    entity
    |> cast(attrs, [
      :name,
      :entity_type,
      :description,
      :properties,
      :mention_count,
      :first_seen_at,
      :last_seen_at,
      :embedding,
      :owner_id,
      :scope_id,
      :collection_id
    ])
    |> validate_required([:name, :entity_type, :owner_id, :collection_id])
    |> validate_inclusion(:entity_type, @entity_types)
    |> unique_constraint([:collection_id, :name, :entity_type])
  end

  def increment_mentions_changeset(entity) do
    change(entity, %{mention_count: entity.mention_count + 1, last_seen_at: DateTime.utc_now()})
  end
end
