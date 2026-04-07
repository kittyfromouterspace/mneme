defmodule Mneme.Schema.Entry do
  @moduledoc """
  Lightweight knowledge entry (Tier 2).
  Simple store-embed-search with access tracking and decay support.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "mneme_entries" do
    field(:scope_id, :binary_id)
    field(:owner_id, :binary_id)
    field(:entry_type, :string, default: "note")
    field(:content, :string)
    field(:summary, :string)
    field(:source, :string, default: "system")
    field(:source_id, :string)
    field(:embedding, Pgvector.Ecto.Vector)
    field(:metadata, :map, default: %{})
    field(:access_count, :integer, default: 0)
    field(:last_accessed_at, :utc_datetime_usec)
    field(:confidence, :float, default: 1.0)
    field(:half_life_days, :float, default: 7.0)
    field(:pinned, :boolean, default: false)
    field(:emotional_valence, :string, default: "neutral")
    field(:schema_fit, :float, default: 0.5)
    field(:outcome_score, :integer)
    field(:confidence_state, :string, default: "active")

    timestamps()
  end

  @entry_types ~w(outcome event decision observation hypothesis note session_summary conversation_turn archived)

  def entry_types, do: @entry_types

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :scope_id,
      :owner_id,
      :entry_type,
      :content,
      :summary,
      :source,
      :source_id,
      :embedding,
      :metadata,
      :access_count,
      :last_accessed_at,
      :confidence,
      :half_life_days,
      :pinned,
      :emotional_valence,
      :schema_fit,
      :outcome_score,
      :confidence_state
    ])
    |> validate_required([:content])
    |> validate_inclusion(:entry_type, @entry_types)
    |> validate_inclusion(:source, ~w(agent system user))
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_inclusion(:emotional_valence, ~w(neutral positive negative critical))
    |> validate_inclusion(:confidence_state, ~w(active stale verified))
  end

  def bump_access_changeset(entry) do
    entry
    |> change(%{
      access_count: entry.access_count + 1,
      last_accessed_at: DateTime.utc_now()
    })
  end
end
