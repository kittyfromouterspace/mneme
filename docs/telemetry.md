# Recollect Telemetry

> Guide to observing Recollect's internal operations via Telemetry events.

## Overview

Recollect emits [Telemetry](https://github.com/beam-telemetry/telemetry) events at key points throughout its operation. These events allow you to:
- Monitor memory operations in production
- Debug issues
- Build dashboards for memory health
- Track learning and invalidation patterns

## Quick Setup

In your application, attach a handler to receive events:

```elixir
# In your application.ex
def start(_type, _args) do
  :telemetry.attach("mneme-handler", [:recollect, :*], &handle_event/4, [])
  # ... rest of your supervision tree
end

def handle_event(event_name, measurements, metadata, _config) do
  IO.inspect({event_name, measurements, metadata}, label: "Recollect Telemetry")
end
```

## Event Reference

### Context Detection

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:recollect, :context, :detect, :stop]` | `duration_ms`, `keys_detected` | `keys` |

```elixir
# Example metadata
%{keys: [:repo, :path_prefix, :os]}
```

---

### Learning System

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:recollect, :learning, :start]` | — | `sources` |
| `[:recollect, :learning, :stop]` | `duration_ms`, `total_learned`, `total_fetched` | `scope_id`, `sources`, `dry_run` |
| `[:recollect, :learn, :source, :stop]` | `fetched`, `learned` | `scope_id`, `source` |

```elixir
# Learning complete
%{duration_ms: 234, total_learned: 5, total_fetched: 12}

# Per-source breakdown
%{fetched: 12, learned: 8}
```

---

### Learning: Git

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:recollect, :learn, :git, :fetch, :stop]` | `duration_ms`, `commits_found` | `scope_id`, `since` |
| `[:recollect, :learn, :git, :stop]` | `duration_ms`, `fetched`, `learned`, `skipped` | `scope_id` |

---

### Learning: Claude Code

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:recollect, :learn, :claude_code, :fetch, :stop]` | `duration_ms`, `projects_found` | `scope_id` |
| `[:recollect, :learn, :claude_code, :stop]` | `duration_ms`, `fetched`, `learned`, `skipped` | `scope_id` |

---

### Learning: OpenCode

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:recollect, :learn, :opencode, :fetch, :stop]` | `duration_ms`, `sessions_found` | `scope_id` |
| `[:recollect, :learn, :opencode, :stop]` | `duration_ms`, `fetched`, `learned`, `skipped` | `scope_id` |

---

### Invalidation

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:recollect, :invalidation, :start]` | — | `days` |
| `[:recollect, :invalidation, :stop]` | `duration_ms`, `migrations_detected`, `invalidations` | `scope_id`, `days` |
| `[:recollect, :invalidate, :stop]` | `duration_ms`, `invalidated`, `replacement_created` | `scope_id`, `pattern`, `reason` |

```elixir
# Full invalidation run
%{duration_ms: 156, migrations_detected: 2, invalidations: 5}

# Single pattern invalidation  
%{duration_ms: 23, invalidated: 3, replacement_created: true}
```

---

### Handoffs

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:recollect, :handoff, :create, :stop]` | `duration_ms` | `scope_id`, `next_count`, `artifacts_count` |
| `[:recollect, :handoff, :get, :stop]` | `duration_ms`, `found` | `scope_id` |
| `[:recollect, :handoff, :load, :stop]` | `next_count`, `artifacts_count` | `scope_id` |

```elixir
# Handoff created
%{duration_ms: 12}

# Handoff retrieved (or not found)
%{duration_ms: 8, found: true}
```

---

### Mipmaps

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:recollect, :mipmap, :generate, :stop]` | `duration_ms`, `levels_generated` | `entry_id` |

```elixir
%{duration_ms: 2, levels_generated: 4}
```

---

### Existing Events (Pre-existing)

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:recollect, :remember, :start/stop]` | `duration` | `entry_type`, `scope_id` |
| `[:recollect, :search, :start/stop]` | `duration`, `result_count` | `scope_id`, `owner_id`, `tier` |
| `[:recollect, :search, :vector, :stop]` | `duration` | `result_count`, `tier` |
| `[:recollect, :pipeline, :start/stop]` | `duration`, `entries_count`, `chunks_count` | `owner_id` |
| `[:recollect, :embed, :stop]` | `duration` | `entry_id`, `type` |
| `[:recollect, :decay, :stop]` | `archived_count` | `scope_id` |

---

## New Events (MemPalace Features)

### Classification

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:recollect, :classification, :stop]` | `duration` | `type`, `confidence` |

```elixir
# Classification completed
%{duration: 0, type: :decision, confidence: 0.8}
```

### Contradiction Detection

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:recollect, :contradiction_check, :stop]` | `duration` | `claims_count`, `has_conflicts` |

```elixir
# Contradiction check completed
%{duration: 12, claims_count: 2, has_conflicts: true}
```

### Search with Filters

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:recollect, :search, :vector, :stop]` | `duration` | `result_count`, `tier`, `filters_applied`, `has_entry_type_filter`, `has_temporal_filter`, `has_confidence_filter` |

```elixir
# Vector search with filters
%{duration: 45, result_count: 5, tier: :both, filters_applied: true, has_entry_type_filter: true, has_temporal_filter: false, has_confidence_filter: true}
```

---

## Integration with TelemetryMetrics

For Prometheus-style metrics:

```elixir
# In your metrics module
def metrics do
  [
    # Learning metrics
    summary("recollect.learning.duration_ms",
      tags: [:scope_id, :source],
      unit: {:millisecond, :second}
    ),
    
    # Invalidation metrics  
    counter("recollect.invalidation.total",
      tags: [:scope_id],
      measurement: :invalidations
    ),
    
    # Context detection
    summary("recollect.context.detect.duration_ms",
      unit: {:millisecond, :second}
    ),
    
    # Search
    summary("recollect.search.duration_ms",
      tags: [:tier],
      unit: {:millisecond, :second}
    )
  ]
end
```

---

## Integration with PromEx

If using [PromEx](https://github.com/akoutmos/prom_ex):

```elixir
def plugins do
  [
    # Add this to your existing plugins
    {Recollect.PromEx, []}
  ]
end

defmodule Recollect.PromEx do
  use PromEx.Plugin

  def plugins do
    []
  end

  def metrics do
    [
      # Learning
      PromEx.build_summary(
        name: :recollect_learning_duration,
        event: [:recollect, :learning, :stop],
        measurement: :duration_ms,
        tags: [:scope_id]
      ),
      
      # Search
      PromEx.build_counter(
        name: :recollect_search_total,
        event: [:recollect, :search, :stop],
        measurement: :result_count,
        tags: [:tier]
      )
    ]
  end
end
```

---

## Custom Handler Example

A complete handler that logs important events:

```elixir
defmodule MyApp.RecollectTelemetry do
  require Logger

  def attach do
    :telemetry.attach("myapp-mneme", [:recollect, :*], __MODULE__.handle_event, [])
  end

  def handle_event([:recollect, :learning, :stop], measurements, metadata, _config) do
    Logger.info("Recollect learning completed", 
      duration_ms: measurements.duration_ms,
      learned: measurements.total_learned,
      scope_id: metadata[:scope_id]
    )
  end

  def handle_event([:recollect, :invalidation, :stop], measurements, metadata, _config) do
    Logger.info("Recollect invalidation completed",
      duration_ms: measurements.duration_ms,
      invalidations: measurements.invalidations,
      migrations: measurements.migrations_detected
    )
  end

  def handle_event([:recollect, :search, :stop], measurements, metadata, _config) do
    Logger.debug("Recollect search completed",
      duration_ms: measurements.duration,
      results: measurements.result_count
    )
  end

  # Catch-all for unhandled events
  def handle_event(event, measurements, metadata, _config) do
    Logger.debug("Recollect event", event: event, measurements: measurements, metadata: metadata)
  end
end
```

---

## Duration Units

All duration measurements are in **native Elixir time** (typically nanoseconds). To convert:

```elixir
# Native to milliseconds
duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
```

The telemetry module automatically converts some events to milliseconds (`duration_ms`). Always check the event documentation for the specific unit used.