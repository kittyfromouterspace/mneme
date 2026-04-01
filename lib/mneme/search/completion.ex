defmodule Mneme.Search.Completion do
  @moduledoc """
  LLM-augmented retrieval that combines hybrid search with LLM reasoning.

  Uses memory search results as context to generate answers with citations.
  Requires an `llm_fn` callback — Mneme never calls LLMs directly for completion.

  ## Usage

      Mneme.complete("What was decided about auth?",
        owner_id: user_id,
        llm_fn: fn messages -> MyApp.LLM.chat(messages) end
      )
  """

  alias Mneme.Search
  alias Mneme.Search.ContextFormatter

  require Logger

  @default_system_prompt """
  You are a knowledgeable assistant with access to the user's personal memory system.
  Below you will find relevant memory chunks, entities, and relationships from the user's
  knowledge graph.

  Use this context to answer the user's question accurately and helpfully.
  When referencing specific information, mention which chunk or entity it came from.
  If the memory context doesn't contain enough information to answer, say so honestly.
  Do not hallucinate information that isn't in the provided context.
  """

  @doc """
  Answer a question using the memory system as context.

  Returns `{:ok, %{answer: answer, context: context_pack}}` or `{:error, reason}`.

  ## Options
  - `:llm_fn` (required) — `fn messages -> {:ok, answer_string} | {:error, reason} end`
  - `:system_prompt` — Override the default system prompt
  - `:owner_id` — Owner UUID for scoping search
  - `:scope_id` — Scope UUID for scoping search
  - `:limit` — Max chunks to retrieve (default: 10)
  - `:hops` — Graph expansion depth (default: 2)
  """
  def complete(question, opts \\ []) do
    llm_fn = Keyword.fetch!(opts, :llm_fn)
    system_prompt = Keyword.get(opts, :system_prompt, @default_system_prompt)

    search_opts =
      opts
      |> Keyword.take([:owner_id, :scope_id, :limit, :hops, :tier, :min_score])
      |> Keyword.put_new(:hops, 2)

    metadata = %{
      owner_id: Keyword.get(opts, :owner_id),
      scope_id: Keyword.get(opts, :scope_id)
    }

    Mneme.Telemetry.span([:mneme, :completion], metadata, fn ->
      with {:ok, context_pack} <- Search.search(question, search_opts) do
        context_text = ContextFormatter.format(context_pack)

        messages = [
          %{role: :system, content: system_prompt <> "\n\n" <> context_text},
          %{role: :user, content: question}
        ]

        case llm_fn.(messages) do
          {:ok, answer} ->
            {:ok, %{answer: answer, context: context_pack}}

          {:error, reason} ->
            Logger.error("Mneme.Completion: LLM call failed: #{inspect(reason)}")
            {:error, reason}
        end
      end
    end)
  end
end
