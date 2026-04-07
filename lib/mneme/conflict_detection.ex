defmodule Mneme.ConflictDetection do
  @moduledoc """
  Automatic conflict detection for contradictory memories.

  Uses Task.async_stream for parallel pairwise comparison.
  """

  @conflict_threshold 0.55

  @doc "Detect conflicts among entries in a scope."
  def detect(scope_id) do
    entries = get_active_entries(scope_id)

    if length(entries) < 2 do
      []
    else
      pairs = generate_pairs(entries)

      pairs
      |> Task.async_stream(
        fn {a, b} -> check_conflict(a, b) end,
        max_concurrency: System.schedulers_online(),
        timeout: 30_000
      )
      |> Enum.flat_map(fn
        {:ok, result} -> if result, do: [result], else: []
        {:exit, _reason} -> []
      end)
    end
  end

  defp generate_pairs(entries) do
    n = length(entries)

    for i <- 0..(n - 2),
        j <- (i + 1)..(n - 1) do
      {Enum.at(entries, i), Enum.at(entries, j)}
    end
  end

  defp check_conflict(entry_a, entry_b) do
    stripped_overlap =
      text_overlap(
        strip_polarity(entry_a["content"]),
        strip_polarity(entry_b["content"])
      )

    tag_overlap = jaccard(entry_a["tags"] || [], entry_b["tags"] || [])
    overlap_score = max(stripped_overlap, tag_overlap * 0.75)

    if overlap_score < @conflict_threshold do
      nil
    else
      case classify_conflict(entry_a["content"], entry_b["content"]) do
        nil ->
          nil

        reason ->
          %{
            entry_a_id: entry_a["id"],
            entry_b_id: entry_b["id"],
            reason: reason,
            score: overlap_score
          }
      end
    end
  end

  defp classify_conflict(text_a, text_b) do
    a = String.downcase(text_a)
    b = String.downcase(text_b)

    cond do
      enabled_disabled?(a, b) -> "enabled/disabled mismatch"
      true_false?(a, b) -> "true/false mismatch"
      always_never?(a, b) -> "always/never mismatch"
      true -> nil
    end
  end

  defp enabled_disabled?(a, b) do
    (contains_any?(a, ["enabled", "enable", "on"]) and
       contains_any?(b, ["disabled", "disable", "off"])) or
      (contains_any?(b, ["enabled", "enable", "on"]) and
         contains_any?(a, ["disabled", "disable", "off"]))
  end

  defp true_false?(a, b) do
    (contains_any?(a, ["true", "yes"]) and contains_any?(b, ["false", "no"])) or
      (contains_any?(b, ["true", "yes"]) and contains_any?(a, ["false", "no"]))
  end

  defp always_never?(a, b) do
    (contains_any?(a, ["always", "must"]) and contains_any?(b, ["never", "must not"])) or
      (contains_any?(b, ["always", "must"]) and contains_any?(a, ["never", "must not"]))
  end

  defp strip_polarity(text) do
    text
    |> String.downcase()
    |> String.replace(
      ~r/\b(not|never|no|don't|doesn't|cannot|shouldn't|enabled|enable|disabled|disable|on|off|true|false|always|must|works?|missing|broken|failed|available|present)\b/,
      " "
    )
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp text_overlap(a, b) do
    set_a = tokenize(a)
    set_b = tokenize(b)
    size_a = MapSet.size(set_a)
    size_b = MapSet.size(set_b)

    if size_a == 0 and size_b == 0 do
      1.0
    else
      intersection = MapSet.intersection(set_a, set_b) |> MapSet.size()
      union = MapSet.union(set_a, set_b) |> MapSet.size()

      if union == 0 do
        0.0
      else
        intersection / union
      end
    end
  end

  defp tokenize(text) do
    text
    |> String.replace(~r/[^\w\s]/, " ")
    |> String.split()
    |> Enum.filter(fn t -> String.length(t) > 1 end)
    |> MapSet.new()
  end

  defp jaccard(list_a, list_b) do
    set_a = MapSet.new(list_a)
    set_b = MapSet.new(list_b)
    size_a = MapSet.size(set_a)
    size_b = MapSet.size(set_b)

    if size_a == 0 and size_b == 0 do
      0.0
    else
      intersection = MapSet.intersection(set_a, set_b) |> MapSet.size()
      union = MapSet.union(set_a, set_b) |> MapSet.size()
      intersection / union
    end
  end

  defp contains_any?(text, needles) do
    Enum.any?(needles, fn needle -> String.contains?(text, needle) end)
  end

  defp get_active_entries(scope_id) do
    repo = Mneme.Config.repo()

    case repo.query(
           """
             SELECT id, content, tags_json FROM mneme_entries
             WHERE scope_id = $1 AND entry_type != 'archived'
           """,
           [scope_id]
         ) do
      {:ok, %{rows: rows, columns: columns}} ->
        Enum.map(rows, fn row ->
          map = Enum.zip(columns, row) |> Map.new()

          tags =
            case map["tags_json"] do
              nil ->
                []

              json when is_binary(json) ->
                case Jason.decode(json) do
                  {:ok, list} when is_list(list) -> list
                  _ -> []
                end

              _ ->
                []
            end

          Map.put(map, "tags", tags)
        end)

      _ ->
        []
    end
  end
end
