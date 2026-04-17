# Enhancement 05: Emotional Valence

**Priority:** Medium | **Effort:** Low | **Status:** Proposed

## Problem

Recollect treats all entries equally regardless of emotional significance. In human memory (and in Hippo), errors and breakthroughs get priority encoding — your first production incident is burned into memory, your 200th uneventful deploy isn't. The amygdala modulates hippocampal consolidation based on emotional significance.

## Solution

Add `emotional_valence` field to entries with multipliers that affect strength calculation. Store multipliers in `:persistent_term` for O(1) reads without config lookups.

## Schema Changes

Add to `recollect_entries`:

```elixir
add :emotional_valence, :string, default: "neutral", null: false
# Values: "neutral", "positive", "negative", "critical"
```

## Emotional Multipliers

| Valence | Multiplier | Typical Use |
|---------|------------|-------------|
| `neutral` | 1.0 | Default, general knowledge |
| `positive` | 1.3 | Successes, wins, working solutions |
| `negative` | 1.5 | Errors, failures, gotchas |
| `critical` | 2.0 | Production incidents, data loss, security issues |

## :persistent_term for Multipliers

The multipliers map is read on every strength calculation. Using `:persistent_term` avoids repeated `Application.get_env/2` calls:

```elixir
# In Recollect.Application.start/2:
multipliers =
  Application.get_env(:recollect, :emotional_valence, [])
  |> Keyword.get(:multipliers, %{neutral: 1.0, positive: 1.3, negative: 1.5, critical: 2.0})

:persistent_term.put({:recollect, :emotional_multipliers}, multipliers)
```

Then in strength calculation (already shown in Enhancement 01):

```elixir
defp emotional_multiplier(%{emotional_valence: valence}) do
  multipliers = :persistent_term.get({:recollect, :emotional_multipliers}, %{})
  Map.get(multipliers, valence, 1.0)
end
```

## API

### Creation

```elixir
# Default (neutral)
{:ok, entry} = Recollect.remember("Deploy script is at scripts/deploy.sh")

# With valence
{:ok, entry} = Recollect.remember("FRED cache silently dropped tips_10y series",
  emotional_valence: :negative
)

{:ok, entry} = Recollect.remember("Migration must run before app starts",
  emotional_valence: :critical
)
```

### Auto-inference from entry_type or metadata

```elixir
defmodule Recollect.Valence do
  @doc "Infer emotional valence from entry options."
  def infer(opts) do
    cond do
      opts[:emotional_valence] -> opts[:emotional_valence]
      opts[:entry_type] == "outcome" and opts[:metadata][:success] == true -> :positive
      opts[:entry_type] == "outcome" and opts[:metadata][:success] == false -> :negative
      opts[:metadata][:error] == true -> :negative
      opts[:metadata][:critical] == true -> :critical
      true -> :neutral
    end
  end
end
```

### Integration with `Recollect.remember/2`

```elixir
def remember(content, opts \\ []) do
  valence = Recollect.Valence.infer(opts)
  opts = Keyword.put(opts, :emotional_valence, valence)

  # ... existing entry creation ...
end
```

## Configuration

```elixir
config :recollect,
  emotional_valence: [
    enabled: true,
    multipliers: %{
      neutral: 1.0,
      positive: 1.3,
      negative: 1.5,
      critical: 2.0
    }
  ]
```

## Migration

```elixir
defmodule Recollect.Repo.Migrations.AddEmotionalValence do
  use Ecto.Migration

  def change do
    alter table(:recollect_entries) do
      add :emotional_valence, :string, default: "neutral", null: false
    end

    create index(:recollect_entries, [:emotional_valence])
  end
end
```

## Context Formatting

Include valence indicator in context output:

```elixir
def format_entry(entry) do
  indicator = case entry.emotional_valence do
    :negative -> "! "
    :critical -> "!! "
    :positive -> "+ "
    _ -> ""
  end

  "#{indicator}#{entry.content}"
end
```

## Backward Compatibility

- `emotional_valence` defaults to `"neutral"` for all existing entries
- Multiplier of 1.0 for neutral means existing strength calculations are unchanged
- Feature is opt-in via config

## Testing

- Unit test: emotional multiplier values for each valence
- Unit test: strength calculation includes emotional multiplier
- Unit test: auto-inference from entry_type and metadata
- Unit test: :persistent_term is populated at application start
- Integration test: negative-valence entries survive longer in decay pass

## References

- Hippo: `memory.ts:EMOTIONAL_MULTIPLIERS` — multiplier definitions
- Amygdala-hippocampus interaction in emotional memory consolidation
