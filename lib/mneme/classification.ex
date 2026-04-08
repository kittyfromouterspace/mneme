defmodule Mneme.Classification do
  @moduledoc """
  LLM-free memory classification using regex-based pattern matching.

  Classifies text into categories inspired by MemPalace's general_extractor:
    - :decision — "we went with X because Y", "decided to use"
    - :preference — "always use X", "never do Y", "I prefer Z"
    - :milestone — "it works", "breakthrough", "finally fixed"
    - :problem — "bug", "error", "doesn't work", "root cause"
    - :emotional — "love", "scared", "proud", "grateful"
    - :note — default for unclassified content

  No LLM required — uses keyword and pattern matching.
  """

  @memory_types [:decision, :preference, :milestone, :problem, :emotional, :note]

  # Pre-compiled regex patterns for performance
  # Decision patterns
  @lets_pattern ~r/\blet'?s (use|go with|try|pick|choose|switch to)\b/i
  @we_decided_pattern ~r/\bwe (should|decided|chose|went with|picked|settled on)\b/i
  @im_going_pattern ~r/\bi'?m going (to|with)\b/i
  @better_pattern ~r/\bbetter (to|than|approach|option|choice)\b/i
  @instead_of_pattern ~r/\binstead of\b/i
  @rather_than_pattern ~r/\brather than\b/i
  @because_pattern ~r/\bbecause\b/i
  @reason_pattern ~r/\bthe reason (is|was|being)\b/i
  @tradeoff_pattern ~r/\btrade-?off\b/i
  @technical_decision_pattern ~r/\b(architecture|approach|strategy|pattern|stack|framework|infrastructure)\b/i
  @configure_pattern ~r/\b(configure|default|set (it |this )?to)\b/i

  # Preference patterns
  @i_prefer_pattern ~r/\bi prefer\b/i
  @always_use_pattern ~r/\balways use\b/i
  @never_use_pattern ~r/\bnever use\b/i
  @i_like_pattern ~r/\bi like (to|when|how)\b/i
  @i_hate_pattern ~r/\bi hate (when|how|it when)\b/i
  @please_pattern ~r/\bplease (always|never|don'?t)\b/i
  @my_rule_pattern ~r/\bmy (rule|preference|style|convention) is\b/i
  @we_always_pattern ~r/\bwe (always|never)\b/i
  @style_pattern ~r/\b(functional|imperative|declarative)\s+(style|programming)\b/i

  # Milestone patterns
  @it_works_pattern ~r/\bit (works?|worked)\b/i
  @breakthrough_pattern ~r/\b(breakthrough|figured (it )?out|nailed it|cracked (it|the))\b/i
  @finally_pattern ~r/\b(finally|first time|first ever|never (done|been|had) before)\b/i
  @discovered_pattern ~r/\b(discovered|realized|found (out|that)|turns out)\b/i
  @key_insight_pattern ~r/\bthe (key (insight|is|was)|trick (is|was))\b/i
  @now_i_understand_pattern ~r/\bnow i (understand|see|get it)\b/i
  @delivery_pattern ~r/\b(built|created|implemented|shipped|launched|deployed|released)\b/i

  # Problem patterns
  @problem_indicator_pattern ~r/\b(bug|error|crash|fail|broke|broken|issue|problem)\b/i
  @not_working_pattern ~r/\b(doesn'?t work|not working|won'?t.?work)\b/i
  @keeps_failing_pattern ~r/\bkeeps? (failing|crashing|breaking|erroring)\b/i
  @root_cause_pattern ~r/\broot cause\b/i
  @the_problem_pattern ~r/\bthe (problem|issue|bug) (is|was)\b/i

  # Emotional patterns
  @strong_emotion_pattern ~r/\b(love|hate|scared|afraid|proud|happy|hurt|sad|angry|worried|lonely)\b/i
  @vulnerability_pattern ~r/\bi feel\b/i
  @appreciation_pattern ~r/\b(grateful|thank|amazing|wonderful|beautiful)\b/i

  @doc """
  Classify a text string into a memory type.

  Returns `{type, confidence}` where:
    - type is one of #{inspect(@memory_types)}
    - confidence is a float 0.0-1.0

  ## Examples

      iex> Mneme.Classification.classify("We decided to use PostgreSQL because it supports JSON")
      {:decision, 0.8}

      iex> Mneme.Classification.classify("I love working with this team")
      {:emotional, 0.6}
  """
  def classify(text) when is_binary(text) do
    start_time = System.monotonic_time()

    result =
      text
      |> extract_prose()
      |> score_types()
      |> determine_type()

    duration = System.monotonic_time() - start_time

    Mneme.Telemetry.event([:mneme, :classification, :stop], %{
      duration: duration,
      type: elem(result, 0),
      confidence: elem(result, 1)
    })

    result
  end

  @doc """
  Classify with additional context for better accuracy.

  Takes context_hints map with :git_repo, :file_path, :os keys.
  """
  def classify(text, context_hints) when is_binary(text) do
    base_result = classify(text)

    case context_hints do
      %{git_repo: _} ->
        boost_type(base_result, :milestone, 0.1)

      %{file_path: path} when is_binary(path) ->
        if String.ends_with?(path, ".md") do
          boost_type(base_result, :note, 0.2)
        else
          base_result
        end

      _ ->
        base_result
    end
  end

  @doc """
  Extract entity claims from text for contradiction detection.

  Returns list of claim maps:
    %{entity: "Kai", predicate: :works_on, object: "auth", temporal: :current}
  """
  def extract_claims(text) when is_binary(text) do
    text
    |> extract_prose()
    |> do_extract_claims()
  end

  @doc """
  Extract memory type from text (returns just the type atom).
  """
  def memory_type(text), do: elem(classify(text), 0)

  @doc """
  Returns all supported memory types.
  """
  def types, do: @memory_types

  # ============================================================================
  # Private: Prose Extraction
  # ============================================================================

  defp extract_prose(text) do
    lines = String.split(text, "\n")
    prose_lines = Enum.reject(lines, &code_line?/1)
    Enum.join(prose_lines, "\n")
  end

  defp code_line?(line) do
    stripped = String.trim(line)

    String.starts_with?(stripped, "```") ||
      Regex.match?(~r/^\s*[\$#]/, stripped) ||
      Regex.match?(~r/^\s*(cd|source|echo|export|pip|npm|git|python|bash|curl)\s/, stripped) ||
      Regex.match?(~r/^\s*(import|from|def|class|function|const|let|var|return)\s/, stripped) ||
      Regex.match?(~r/^\s*[A-Z_]{2,}=/, stripped) ||
      Regex.match?(~r/^\s*\|/, stripped) ||
      Regex.match?(~r/^\s*[-]{3,}/, stripped)
  end

  # ============================================================================
  # Private: Type Scoring
  # ============================================================================

  defp score_types(text) do
    text_lower = String.downcase(text)

    %{
      decision: score_decision(text_lower),
      preference: score_preference(text_lower),
      milestone: score_milestone(text_lower),
      problem: score_problem(text_lower),
      emotional: score_emotional(text_lower)
    }
  end

  defp score_decision(text) do
    score = 0

    score = if Regex.match?(@lets_pattern, text), do: score + 3, else: score
    score = if Regex.match?(@we_decided_pattern, text), do: score + 3, else: score
    score = if Regex.match?(@im_going_pattern, text), do: score + 2, else: score
    score = if Regex.match?(@better_pattern, text), do: score + 2, else: score
    score = if Regex.match?(@instead_of_pattern, text), do: score + 2, else: score
    score = if Regex.match?(@rather_than_pattern, text), do: score + 2, else: score
    score = if Regex.match?(@because_pattern, text), do: score + 1, else: score
    score = if Regex.match?(@reason_pattern, text), do: score + 2, else: score
    score = if Regex.match?(@tradeoff_pattern, text), do: score + 2, else: score
    score = if Regex.match?(@technical_decision_pattern, text), do: score + 1, else: score
    score = if Regex.match?(@configure_pattern, text), do: score + 1, else: score

    score
  end

  defp score_preference(text) do
    score = 0

    score = if Regex.match?(@i_prefer_pattern, text), do: score + 3, else: score
    score = if Regex.match?(@always_use_pattern, text), do: score + 3, else: score
    score = if Regex.match?(@never_use_pattern, text), do: score + 3, else: score
    score = if Regex.match?(@i_like_pattern, text), do: score + 2, else: score
    score = if Regex.match?(@i_hate_pattern, text), do: score + 2, else: score
    score = if Regex.match?(@please_pattern, text), do: score + 2, else: score
    score = if Regex.match?(@my_rule_pattern, text), do: score + 3, else: score
    score = if Regex.match?(@we_always_pattern, text), do: score + 2, else: score

    if Regex.match?(@style_pattern, text), do: score + 2, else: score
  end

  defp score_milestone(text) do
    score = 0

    score = if Regex.match?(@it_works_pattern, text), do: score + 3, else: score
    score = if Regex.match?(~r/\bfixed\b/i, text), do: score + 2, else: score
    score = if Regex.match?(~r/\bsolved\b/i, text), do: score + 2, else: score

    score = if Regex.match?(@breakthrough_pattern, text), do: score + 3, else: score
    score = if Regex.match?(@finally_pattern, text), do: score + 2, else: score
    score = if Regex.match?(@discovered_pattern, text), do: score + 2, else: score
    score = if Regex.match?(@key_insight_pattern, text), do: score + 2, else: score
    score = if Regex.match?(@now_i_understand_pattern, text), do: score + 2, else: score
    score = if Regex.match?(@delivery_pattern, text), do: score + 1, else: score

    score =
      if Regex.match?(~r/\b(prototype|proof of concept|demo)\b/i, text),
        do: score + 2,
        else: score

    score
  end

  defp score_problem(text) do
    score = 0

    score = if Regex.match?(@problem_indicator_pattern, text), do: score + 2, else: score
    score = if Regex.match?(@not_working_pattern, text), do: score + 3, else: score
    score = if Regex.match?(@keeps_failing_pattern, text), do: score + 3, else: score

    score = if Regex.match?(@root_cause_pattern, text), do: score + 3, else: score
    score = if Regex.match?(@the_problem_pattern, text), do: score + 2, else: score

    score
  end

  defp score_emotional(text) do
    score = 0

    score = if Regex.match?(@strong_emotion_pattern, text), do: score + 2, else: score
    score = if Regex.match?(@vulnerability_pattern, text), do: score + 3, else: score

    score = if Regex.match?(@appreciation_pattern, text), do: score + 2, else: score

    score
  end

  # ============================================================================
  # Private: Type Determination
  # ============================================================================

  defp determine_type(scores) do
    {type, base_score} = Enum.max_by(scores, fn {_k, v} -> v end, fn -> {:note, 0} end)

    final_score = if base_score > 0, do: base_score, else: 0
    type = disambiguate(type, final_score)

    confidence =
      if final_score > 0 do
        min(1.0, final_score / 5.0)
      else
        0.0
      end

    {type, confidence}
  end

  defp disambiguate(type, score) do
    if score < 1, do: :note, else: type
  end

  defp boost_type({type, confidence}, boost_type, boost) do
    if type == boost_type do
      {type, min(1.0, confidence + boost)}
    else
      {type, confidence}
    end
  end

  # ============================================================================
  # Private: Claim Extraction
  # ============================================================================

  defp do_extract_claims(text) do
    claims = []

    claims =
      extract_claim(
        text,
        ~r/\b([A-Z][a-z]+)\s+(works on|working on|assigned to)\s+([^\.]+)/i,
        :works_on,
        claims
      )

    claims =
      extract_claim(
        text,
        ~r/\b([A-Z][a-z]+)\s+(is|was)\s+(complete|done|finished|in progress|started)\b/i,
        :status,
        claims
      )

    claims = extract_claim(text, ~r/\b([A-Z][a-z]+)\s+decided\s+to\s+([^\.]+)/i, :decides, claims)

    claims =
      extract_claim(text, ~r/\b([A-Z][a-z]+)\s+(prefers|likes)\s+([^\.]+)/i, :prefers, claims)

    claims =
      extract_claim(
        text,
        ~r/\b([A-Z][a-z]+)\s+(created|built|started)\s+([^\.]+)/i,
        :created,
        claims
      )

    claims
  end

  defp extract_claim(text, regex, predicate, acc) do
    case Regex.run(regex, text) do
      [_, entity, _verb, object] ->
        [
          %{
            entity: String.trim(entity),
            predicate: predicate,
            object: String.trim(object),
            temporal: :current
          }
          | acc
        ]

      _ ->
        acc
    end
  end
end
