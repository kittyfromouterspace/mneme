defmodule Recollect.Schema.PipelineRun do
  @moduledoc """
  Tracks pipeline execution: status, step details, cost, and timing.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @statuses ~w(pending chunking embedding extracting syncing complete failed)

  schema "recollect_pipeline_runs" do
    field(:status, :string, default: "pending")
    field(:step_details, :map, default: %{})
    field(:error, :string)
    field(:tokens_used, :integer, default: 0)
    field(:cost_usd, :float, default: 0.0)
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)
    field(:owner_id, :binary_id)
    field(:scope_id, :binary_id)

    belongs_to(:document, Recollect.Schema.Document, type: :binary_id)

    timestamps()
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :status,
      :step_details,
      :error,
      :tokens_used,
      :cost_usd,
      :started_at,
      :completed_at,
      :owner_id,
      :scope_id,
      :document_id
    ])
    |> validate_required([:document_id, :owner_id])
    |> validate_inclusion(:status, @statuses)
    |> maybe_set_timestamps()
  end

  defp maybe_set_timestamps(changeset) do
    case get_change(changeset, :status) do
      status when status in ~w(chunking) ->
        put_change(changeset, :started_at, DateTime.utc_now())

      status when status in ~w(complete failed) ->
        put_change(changeset, :completed_at, DateTime.utc_now())

      _ ->
        changeset
    end
  end
end
