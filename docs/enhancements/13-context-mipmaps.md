# Enhancement 13: Context Mipmaps

**Priority:** Medium | **Effort:** Medium | **Status:** Proposed

## Problem

When retrieving context for an LLM, more isn't always better. A user asking "what was that error about?" needs different detail than "give me a summary of this project."

Currently, Mneme returns a fixed number of entries with equal weight. There's no way to:
- Get high-level summaries for broad questions
- Get detailed context for specific questions
- Control granularity based on query intent

## Solution

Context Mipmaps — progressive detail levels like image mipmaps. Store entries at multiple detail levels and retrieve appropriate granularity based on query context.

```
┌─────────────────────────────────────────────────────────────┐
│              Context Mipmaps                                │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ Detail Levels                                        │    │
│  │                                                      │    │
│  │ L0: Full entry (all content, all metadata)         │    │
│  │ L1: Summary (first 200 chars + key tags)            │    │
│  │ L2: Abstract (single line + type + tags)            │    │
│  │ L3: Anchor (type + single key term)                │    │
│  └─────────────────────────────────────────────────────┘    │
│                          │                                  │
│                          ▼                                  │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ Retrieval Strategy                                   │    │
│  │                                                      │    │
│  │ - short query → L2/L3 (broad match)                │    │
│  │ - long query → L0/L1 (detailed match)             │    │
│  │ - specific entity → L0 (full detail)               │    │
│  │ - query matches abstract → escalate to L0         │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

## Detail Levels

```elixir
defmodule Mneme.Mipmap do
  @moduledoc """
  Context mipmaps — progressive detail levels for retrieval.
  """

  @levels [:anchor, :abstract, :summary, :full]

  @doc "Generate mipmap entries for a source entry."
  def generate_mipmaps(entry) do
    %{
      entry_id: entry.id,
      levels: %{
        full: entry,
        summary: to_summary(entry),
        abstract: to_abstract(entry),
        anchor: to_anchor(entry)
      }
    }
  end

  defp to_summary(entry) do
    # First 200 chars + key metadata
    %{
      content: String.slice(entry.content, 0, 200),
      tags: entry.tags,
      entry_type: entry.entry_type,
      emotional_valence: entry.emotional_valence
    }
  end

  defp to_abstract(entry) do
    # Single line + type + tags
    first_line = entry.content |> String.split("\n") |> hd() |> String.slice(0, 100)
    
    %{
      content: first_line,
      entry_type: entry.entry_type,
      tags: Enum.take(entry.tags, 3)
    }
  end

  defp to_anchor(entry) do
    # Type + single key term
    key_term = extract_key_term(entry.content)
    
    %{
      type: entry.entry_type,
      term: key_term
    }
  end

  defp extract_key_term(content) do
    # Simple: first significant word or phrase
    content
    |> String.split()
    |> Enum.find(fn w -> String.length(w) > 4 end)
    |> Kernel.||(String.slice(content, 0, 20))
  end
end
```

## Schema

```elixir
# Mipmap entries table (separate from main entries)
create table(:mneme_mipmaps, primary_key: false) do
  add :entry_id, :binary_id, primary_key: true
  add :level, :string, primary_key: true  # :anchor, :abstract, :summary, :full
  add :content, :text
  add :metadata, :map
  add :embedding, :vector(1536)  # Embed each level separately
end

create index(:mneme_mipmaps, [:entry_id])
create index(:mneme_mipmaps, [:level])
```

## Retrieval Strategy

```elixir
defmodule Mneme.Search.MipmapRetriever do
  @moduledoc """
  Retrieve at appropriate detail level based on query characteristics.
  """

  @doc "Determine appropriate mipmap level for a query."
  def determine_level(query) do
    query_length = String.length(query)
    
    cond do
      # Short/broad queries → abstract level
      query_length < 50 -> :abstract
      
      # Medium queries → summary level  
      query_length < 200 -> :summary
      
      # Long/detailed queries → full level
      true -> :full
    end
  end

  @doc "Search with automatic level selection."
  def search(query, scope_id, opts \\ []) do
    level = determine_level(query)
    
    # Search at determined level
    results = search_at_level(query, scope_id, level, opts)
    
    # If results are sparse, try escalating to higher detail
    if length(results) < 3 do
      escalate_search(query, scope_id, results, level)
    else
      results
    end
  end

  defp escalate_search(query, scope_id, results, :abstract) do
    # Try summary level
    results ++ search_at_level(query, scope_id, :summary, [])
  end

  defp escalate_search(query, scope_id, results, :summary) do  
    # Try full level
    results ++ search_at_level(query, scope_id, :full, [])
  end

  defp escalate_search(_, _, results, _), do: results

  defp search_at_level(query, scope_id, level, opts) do
    # Query mipmaps table at specific level
    # ...
  end
end
```

## Integration with Main Search

```elixir
defmodule Mneme.Search do
  def search(query, opts \\ []) do
    # Check if mipmap search is enabled
    if Application.get_env(:mneme, :mipmap_enabled, false) do
      MipmapRetriever.search(query, scope_id, opts)
    else
      Vector.search(query, opts)
    end
  end
end
```

## Usage

```elixir
# Short query → gets abstract-level matches
{:ok, results} = Mneme.search("auth")

# Long query → gets full detail
{:ok, results} = Mneme.search("How do I implement token-based authentication in Elixir?")

# Explicit level request
{:ok, results} = Mneme.search("auth", level: :summary)
```

## Configuration

```elixir
config :mneme,
  mipmap: [
    enabled: true,
    levels: [:anchor, :abstract, :summary, :full],
    escalate_on_sparse: true,
    min_results_before_escalate: 3
  ]
```

## Migration

```elixir
defmodule Mneme.Repo.Migrations.AddMipmaps do
  use Ecto.Migration

  def change do
    create table(:mneme_mipmaps, primary_key: false) do
      add :entry_id, :binary_id, primary_key: true
      add :level, :string, primary_key: true
      add :content, :text
      add :metadata, :map
      add :embedding, :vector(1536)
    end

    create index(:mneme_mipmaps, [:level])
  end
end
```

## References

- Image mipmaps — progressive detail for efficient rendering
- n0tls: "context mipmaps" — HN discussion
- Cognee: summaries as separate retrievable entities