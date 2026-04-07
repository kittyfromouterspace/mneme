defmodule Mneme.Confidence do
  @moduledoc """
  Confidence lifecycle management.

  Memories that haven't been retrieved in 30+ days are automatically
  marked "stale". If they're recalled again, they wake back up to
  "observed" so they can earn trust again.
  """

  alias Mneme.Config

  @stale_threshold_days 30

  @doc """
  Resolve the effective confidence state for an entry.
  Computed on-read, no DB write.
  """
  def resolve_state(%{confidence_state: "verified"}), do: "verified"

  def resolve_state(%{confidence_state: "stale"} = entry) do
    if recently_retrieved?(entry), do: "observed", else: "stale"
  end

  def resolve_state(entry) do
    if days_since_last_access(entry) > @stale_threshold_days do
      "stale"
    else
      entry.confidence_state || "active"
    end
  end

  @doc """
  Wake up stale entries when retrieved.
  Returns number of entries woken up.
  """
  def wake_up_stale_entries(entry_ids) when is_list(entry_ids) do
    if entry_ids == [] do
      {:ok, 0}
    else
      repo = Config.repo()

      try do
        repo.query(
          """
            UPDATE mneme_entries
            SET confidence_state = 'observed', updated_at = $1
            WHERE id = ANY($2) AND confidence_state = 'stale'
          """,
          [DateTime.utc_now(), entry_ids]
        )
      rescue
        _ -> {:ok, 0}
      end
    end
  end

  @doc """
  Mark an entry as verified (e.g., after positive outcome feedback).
  """
  def verify(entry_id) do
    repo = Config.repo()

    try do
      repo.query(
        "UPDATE mneme_entries SET confidence_state = 'verified', updated_at = $1 WHERE id = $2",
        [DateTime.utc_now(), entry_id]
      )
    rescue
      _ -> {:ok, 0}
    end
  end

  defp days_since_last_access(%{last_accessed_at: nil, inserted_at: inserted_at}) do
    DateTime.diff(DateTime.utc_now(), inserted_at, :day)
  end

  defp days_since_last_access(%{last_accessed_at: at}) do
    DateTime.diff(DateTime.utc_now(), at, :day)
  end

  defp recently_retrieved?(entry) do
    days_since_last_access(entry) < @stale_threshold_days
  end
end
