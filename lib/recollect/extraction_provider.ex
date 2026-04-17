defmodule Recollect.ExtractionProvider do
  @moduledoc """
  Behaviour for LLM-powered entity/relation extraction.

  The host app provides an `llm_fn` that makes the actual LLM call.
  Recollect handles prompting, parsing, and validation.
  """

  @type entity_map :: %{
          name: String.t(),
          entity_type: String.t(),
          description: String.t()
        }

  @type relation_map :: %{
          from: String.t(),
          to: String.t(),
          relation_type: String.t(),
          weight: float()
        }

  @type extraction_result :: %{
          entities: [entity_map()],
          relations: [relation_map()]
        }

  @doc """
  Extract entities and relations from text.

  Returns `{:ok, %{entities: [...], relations: [...]}}` or `{:error, reason}`.
  """
  @callback extract(text :: String.t(), opts :: keyword()) ::
              {:ok, extraction_result()} | {:error, term()}
end
