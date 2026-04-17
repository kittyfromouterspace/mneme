defmodule Recollect.Schema.Relation do
  @moduledoc """
  Graph edge between entities. 8 typed relations with confidence weights.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Recollect.Schema.Entity

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @relation_types ~w(supports blocks causes relates_to part_of depends_on precedes contradicts)

  schema "recollect_relations" do
    field(:relation_type, :string)
    field(:weight, :float, default: 1.0)
    field(:properties, :map, default: %{})
    field(:owner_id, :binary_id)
    field(:scope_id, :binary_id)

    belongs_to(:from_entity, Entity, type: :binary_id)
    belongs_to(:to_entity, Entity, type: :binary_id)
    belongs_to(:source_chunk, Recollect.Schema.Chunk, type: :binary_id)

    timestamps()
  end

  def relation_types, do: @relation_types

  def changeset(relation, attrs) do
    relation
    |> cast(attrs, [
      :relation_type,
      :weight,
      :properties,
      :owner_id,
      :scope_id,
      :from_entity_id,
      :to_entity_id,
      :source_chunk_id
    ])
    |> validate_required([:relation_type, :from_entity_id, :to_entity_id, :owner_id])
    |> validate_inclusion(:relation_type, @relation_types)
    |> validate_number(:weight, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> check_constraint(:no_self_relation, name: :no_self_relation)
    |> unique_constraint([:from_entity_id, :to_entity_id, :relation_type])
  end
end
