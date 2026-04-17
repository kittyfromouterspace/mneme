defmodule Recollect.Schema.Collection do
  @moduledoc """
  Groups related memory documents. One per user/workspace/topic.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "recollect_collections" do
    field(:name, :string)
    field(:collection_type, :string, default: "user")
    field(:owner_id, :binary_id)
    field(:scope_id, :binary_id)
    field(:metadata, :map, default: %{})

    has_many(:documents, Recollect.Schema.Document)
    has_many(:entities, Recollect.Schema.Entity)

    timestamps()
  end

  def changeset(collection, attrs) do
    collection
    |> cast(attrs, [:name, :collection_type, :owner_id, :scope_id, :metadata])
    |> validate_required([:name, :owner_id])
    |> validate_inclusion(:collection_type, ~w(user workspace topic))
    |> unique_constraint([:owner_id, :name, :collection_type])
  end
end
