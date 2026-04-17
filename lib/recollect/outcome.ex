defmodule Recollect.Outcome do
  @moduledoc """
  Outcome feedback for closing the learning loop.

  After recalling memories, the agent can signal whether they were helpful
  (outcome_good) or irrelevant (outcome_bad), which adjusts half-life.
  """

  alias Recollect.Config
  alias Recollect.OutcomeTracker

  @positive_delta 5
  @negative_delta -3

  @doc "Apply positive outcome to the last-retrieved entries for a scope."
  def good(scope_id) do
    entry_ids = OutcomeTracker.get(scope_id)
    apply_outcome(entry_ids, :good)
  end

  @doc "Apply negative outcome to the last-retrieved entries for a scope."
  def bad(scope_id) do
    entry_ids = OutcomeTracker.get(scope_id)
    apply_outcome(entry_ids, :bad)
  end

  @doc "Apply outcome to specific entry IDs."
  def apply(entry_ids, :good) when is_list(entry_ids) do
    apply_outcome(entry_ids, :good)
  end

  def apply(entry_ids, :bad) when is_list(entry_ids) do
    apply_outcome(entry_ids, :bad)
  end

  defp apply_outcome([], _direction), do: {:ok, 0}

  defp apply_outcome(entry_ids, :good) do
    delta =
      :recollect
      |> Application.get_env(:outcome_feedback, [])
      |> Keyword.get(:positive_half_life_delta, @positive_delta)

    do_update(entry_ids, delta, 1)
  end

  defp apply_outcome(entry_ids, :bad) do
    delta =
      -(:recollect
        |> Application.get_env(:outcome_feedback, [])
        |> Keyword.get(:negative_half_life_delta, abs(@negative_delta)))

    do_update(entry_ids, delta, -1)
  end

  defp do_update(entry_ids, delta, score) do
    repo = Config.repo()
    now = DateTime.utc_now()

    try do
      repo.query(
        """
          UPDATE recollect_entries
          SET half_life_days = GREATEST(1, half_life_days + $1),
              outcome_score = $2,
              confidence_state = CASE WHEN $2 > 0 THEN 'verified' ELSE 'active' END,
              updated_at = $3
          WHERE id = ANY($4)
        """,
        [delta, score, now, entry_ids]
      )

      {:ok, length(entry_ids)}
    rescue
      _ -> {:ok, 0}
    end
  end
end
