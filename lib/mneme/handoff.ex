defmodule Mneme.Handoff do
  @moduledoc """
  Session handoff for continuing work across sessions.

  Stores "what I was doing", "what's next", and "artifacts to continue with"
  so that when a session resumes, the context is immediately available.

  ## Usage

      # At end of session
      Mneme.Handoff.create(workspace_id,
        what: "Implementing user auth",
        next: ["Add login controller", "Create session middleware"],
        artifacts: ["lib/auth/user.ex", "lib/auth/token.ex"],
        blockers: ["Waiting on API spec"]
      )
      
      # At start of next session
      {:ok, handoff} = Mneme.Handoff.get(workspace_id)
  """

  alias Mneme.{Config, Telemetry}

  @doc """
  Create a handoff for a scope.

  ## Options
  - `:what` - What you were working on (required)
  - `:next` - List of next steps (optional)
  - `:artifacts` - Files/links to continue with (optional)
  - `:blockers` - What's blocking progress (optional)
  - `:session_id` - Current session ID (optional)
  """
  def create(scope_id, opts \\ []) do
    what = Keyword.fetch!(opts, :what)
    next = Keyword.get(opts, :next, [])
    artifacts = Keyword.get(opts, :artifacts, [])
    blockers = Keyword.get(opts, :blockers, [])
    session_id = Keyword.get(opts, :session_id)

    start_time = System.monotonic_time()

    repo = Config.repo()
    now = DateTime.utc_now()

    result =
      repo.query(
        """
          INSERT INTO mneme_handoffs
            (id, scope_id, session_id, what, next, artifacts, blockers, created_at, updated_at)
          VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        """,
        [
          Ecto.UUID.generate(),
          uuid_to_bin(scope_id),
          session_id && uuid_to_bin(session_id),
          what,
          Jason.encode!(next),
          Jason.encode!(artifacts),
          Jason.encode!(blockers),
          now,
          now
        ]
      )

    duration =
      System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

    Telemetry.event(
      [:mneme, :handoff, :create, :stop],
      %{duration_ms: duration},
      %{scope_id: scope_id, next_count: length(next), artifacts_count: length(artifacts)}
    )

    result
  end

  @doc """
  Get the most recent handoff for a scope.
  """
  def get(scope_id) do
    start_time = System.monotonic_time()

    repo = Config.repo()

    case repo.query(
           """
             SELECT id, what, next, artifacts, blockers, session_id, created_at
             FROM mneme_handoffs
             WHERE scope_id = $1
             ORDER BY created_at DESC
             LIMIT 1
           """,
           [uuid_to_bin(scope_id)]
         ) do
      {:ok,
       %{
         rows: [
           [id, what, next_json, artifacts_json, blockers_json, session_id, created_at] | []
         ]
       }} ->
        handoff = %{
          id: id,
          what: what,
          next: decode_json_or_list(next_json, []),
          artifacts: decode_json_or_list(artifacts_json, []),
          blockers: decode_json_or_list(blockers_json, []),
          session_id: session_id,
          created_at: created_at
        }

        duration =
          System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

        Telemetry.event(
          [:mneme, :handoff, :get, :stop],
          %{duration_ms: duration, found: true},
          %{scope_id: scope_id}
        )

        {:ok, handoff}

      {:ok, %{rows: []}} ->
        duration =
          System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

        Telemetry.event(
          [:mneme, :handoff, :get, :stop],
          %{duration_ms: duration, found: false},
          %{scope_id: scope_id}
        )

        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get handoffs since a date.
  """
  def recent(scope_id, since \\ ~D[2024-01-01]) do
    repo = Config.repo()

    case repo.query(
           """
             SELECT id, what, next, artifacts, blockers, created_at
             FROM mneme_handoffs
             WHERE scope_id = $1 AND created_at >= $2
             ORDER BY created_at DESC
           """,
           [uuid_to_bin(scope_id), since]
         ) do
      {:ok, %{rows: rows}} ->
        handoffs =
          Enum.map(rows, fn [id, what, next_json, artifacts_json, blockers_json, created_at] ->
            %{
              id: id,
              what: what,
              next: decode_json_or_list(next_json, []),
              artifacts: decode_json_or_list(artifacts_json, []),
              blockers: decode_json_or_list(blockers_json, []),
              created_at: created_at
            }
          end)

        {:ok, handoffs}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Delete old handoffs, keeping only the most recent N.
  """
  def cleanup(scope_id, keep: keep_count) do
    repo = Config.repo()

    repo.query(
      """
        DELETE FROM mneme_handoffs
        WHERE scope_id = $1
          AND id NOT IN (
            SELECT id FROM mneme_handoffs
            WHERE scope_id = $1
            ORDER BY created_at DESC
            LIMIT $2
          )
      """,
      [uuid_to_bin(scope_id), keep_count]
    )
  end

  # Private

  defp decode_json_or_list(nil, default), do: default
  defp decode_json_or_list("", _default), do: []

  defp decode_json_or_list(json, default) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> default
    end
  end

  defp decode_json_or_list(other, default), do: other || default

  defp uuid_to_bin(id) when is_binary(id) do
    case Ecto.UUID.dump(id) do
      {:ok, bin} -> bin
      :error -> id
    end
  end
end
