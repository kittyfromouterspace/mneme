defmodule Mneme.Schema.Edge do
  @moduledoc """
  Lightweight knowledge edge between entries (Tier 2).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @relation_types ~w(leads_to supports contradicts derived_from supersedes related_to)

  schema "mneme_edges" do
    field(:relation, :string)
    field(:weight, :float, default: 1.0)
    field(:metadata, :map, default: %{})

    belongs_to(:source_entry, Mneme.Schema.Entry, type: :binary_id)
    belongs_to(:target_entry, Mneme.Schema.Entry, type: :binary_id)

    timestamps()
  end

  def relation_types, do: @relation_types

  def changeset(edge, attrs) do
    edge
    |> cast(attrs, [:relation, :weight, :metadata, :source_entry_id, :target_entry_id])
    |> validate_required([:relation, :source_entry_id, :target_entry_id])
    |> validate_inclusion(:relation, @relation_types)
    |> validate_number(:weight, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> unique_constraint([:source_entry_id, :target_entry_id, :relation])
  end
end
