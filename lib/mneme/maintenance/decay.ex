defmodule Mneme.Maintenance.Decay do
  @moduledoc """
  Archives stale entries based on access patterns.
  Entries not accessed in N days with fewer than M accesses are archived.
  """

  import Ecto.Query
  alias Mneme.Config

  require Logger

  @doc """
  Run decay pass. Archives stale entries.

  ## Options
  - `:max_age_days` — Days since last access (default: 90)
  - `:min_access_count` — Minimum accesses to survive (default: 3)
  """
  def run(opts \\ []) do
    start_time = System.monotonic_time()
    max_age_days = Keyword.get(opts, :max_age_days, 90)
    min_access_count = Keyword.get(opts, :min_access_count, 3)
    repo = Config.repo()

    cutoff = DateTime.utc_now() |> DateTime.add(-max_age_days * 86400, :second)

    {count, _} =
      from(e in "mneme_entries",
        where:
          e.entry_type != "archived" and
            (is_nil(e.last_accessed_at) or e.last_accessed_at < ^cutoff) and
            e.access_count < ^min_access_count
      )
      |> repo.update_all(set: [entry_type: "archived", updated_at: DateTime.utc_now()])

    duration = System.monotonic_time() - start_time

    Mneme.Telemetry.event([:mneme, :decay, :stop], %{
      archived_count: count,
      duration: duration
    })

    Logger.info("Mneme.Decay: archived #{count} stale entries")
    {:ok, count}
  end
end
