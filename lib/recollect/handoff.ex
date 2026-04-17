defmodule Recollect.Handoff do
  @moduledoc """
  Session handoff for continuing work across sessions.

  Stores "what I was doing", "what's next", and "artifacts to continue with"
  so that when a session resumes, the context is immediately available.

  ## Usage

      # At end of session
      Recollect.Handoff.create(workspace_id,
        what: "Implementing user auth",
        next: ["Add login controller", "Create session middleware"],
        artifacts: ["lib/auth/user.ex", "lib/auth/token.ex"],
        blockers: ["Waiting on API spec"]
      )
      
      # At start of next session
      {:ok, handoff} = Recollect.Handoff.get(workspace_id)
  """

  alias Recollect.Config
  alias Recollect.Telemetry

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

    repo = Config.repo()
    now = DateTime.utc_now()

    {result, _} =
      Telemetry.span(
        [:recollect, :handoff, :create],
        %{scope_id: scope_id, next_count: length(next), artifacts_count: length(artifacts)},
        fn ->
          result =
            repo.query(
              """
                INSERT INTO recollect_handoffs
                  (id, scope_id, session_id, what, next, artifacts, blockers, created_at, updated_at)
                VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
              """,
              [
                Ecto.UUID.generate(),
                Recollect.Util.uuid_to_bin(scope_id),
                session_id && Recollect.Util.uuid_to_bin(session_id),
                what,
                Jason.encode!(next),
                Jason.encode!(artifacts),
                Jason.encode!(blockers),
                now,
                now
              ]
            )

          {%{result: result}, result}
        end
      )

    result
  end

  @doc """
  Get the most recent handoff for a scope.
  """
  def get(scope_id) do
    repo = Config.repo()

    {result, _} =
      Telemetry.span([:recollect, :handoff, :get], %{scope_id: scope_id}, fn ->
        case repo.query(
               """
                 SELECT id, what, next, artifacts, blockers, session_id, created_at
                 FROM recollect_handoffs
                 WHERE scope_id = $1
                 ORDER BY created_at DESC
                 LIMIT 1
               """,
               [Recollect.Util.uuid_to_bin(scope_id)]
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

            {%{result: {:ok, handoff}, found: true}, {:ok, handoff}}

          {:ok, %{rows: []}} ->
            {%{result: {:ok, nil}, found: false}, {:ok, nil}}

          {:error, reason} ->
            {%{result: {:error, reason}}, {:error, reason}}
        end
      end)

    result
  end

  @doc """
  Get handoffs since a date.
  """
  def recent(scope_id, since \\ ~D[2024-01-01]) do
    repo = Config.repo()

    case repo.query(
           """
             SELECT id, what, next, artifacts, blockers, created_at
             FROM recollect_handoffs
             WHERE scope_id = $1 AND created_at >= $2
             ORDER BY created_at DESC
           """,
           [Recollect.Util.uuid_to_bin(scope_id), since]
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
        DELETE FROM recollect_handoffs
        WHERE scope_id = $1
          AND id NOT IN (
            SELECT id FROM recollect_handoffs
            WHERE scope_id = $1
            ORDER BY created_at DESC
            LIMIT $2
          )
      """,
      [Recollect.Util.uuid_to_bin(scope_id), keep_count]
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
end
