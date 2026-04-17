# Implementation Summary: libSQL Migration

## What Was Accomplished

This implementation makes Recollect database-agnostic, supporting both PostgreSQL (with pgvector) and libSQL/SQLite (with native vector support).

## New Files Created

### 1. Database Adapter System

- **`lib/mneme/database_adapter.ex`** - Behaviour defining the adapter interface
- **`lib/mneme/database_adapter/postgres.ex`** - PostgreSQL/pgvector adapter
- **`lib/mneme/database_adapter/libsql.ex`** - libSQL/SQLite adapter

These adapters provide:
- Vector type definitions (`F32_BLOB` for libSQL, `vector` for PostgreSQL)
- SQL generation for vector indexes and distance calculations
- Database-specific query parameter handling
- UUID type mapping

### 2. Adapter-Aware Type System

- **`lib/mneme/embedding_type.ex`** - Ecto type that works with both backends

This type automatically:
- Detects the configured adapter
- Serializes embeddings appropriately for each database
- Handles deserialization from database-specific formats

### 3. Migration Generator

- **`lib/mneme/migration_generator.ex`** - Generates database-specific migrations

Provides adapter-aware SQL generation for:
- Table creation with correct types
- Vector index creation
- Constraints and foreign keys

### 4. Updated Mix Task

- **`lib/mix/tasks/recollect.gen.migration.ex`** - Now supports `--adapter` option

Usage:
```bash
mix recollect.gen.migration --adapter libsql --dimensions 768
mix recollect.gen.migration --adapter postgres --dimensions 1536
```

## Modified Files

### Recollect Core

1. **`lib/mneme/config.ex`**
   - Added `adapter/0` function to return configured adapter
   - Added `requires_pgvector?/0` helper
   - Updated documentation with database adapter configuration

2. **`lib/mneme/mix.exs`**
   - Made `postgrex` and `pgvector` optional dependencies
   - Added `ecto_libsql` as optional dependency
   - Updated version to 0.2.0
   - Updated description

3. **`lib/mneme/postgrex_types.ex`**
   - Made pgvector extensions conditional
   - Gracefully handles when pgvector isn't available

### Search & Graph

4. **`lib/mneme/search/vector.ex`**
   - Completely refactored to use adapter for SQL generation
   - Generates database-specific vector distance queries
   - Handles parameter placeholders correctly ($1, $2 for PostgreSQL, ? for libSQL)

5. **`lib/mneme/search/graph.ex`**
   - Updated to use adapter for SQL generation
   - Added `follow_edges_batch/2` for libSQL multi-ID support
   - Handles differences in array parameter support

6. **`lib/mneme/graph/postgres_graph.ex`**
   - Updated to use adapter for SQL generation
   - Now supports both PostgreSQL and libSQL backends

### Schemas

7. **`lib/mneme/schema/entry.ex`** - Changed `embedding` field from `Pgvector.Ecto.Vector` to `Recollect.EmbeddingType`
8. **`lib/mneme/schema/chunk.ex`** - Changed `embedding` field from `Pgvector.Ecto.Vector` to `Recollect.EmbeddingType`
9. **`lib/mneme/schema/entity.ex`** - Changed `embedding` field from `Pgvector.Ecto.Vector` to `Recollect.EmbeddingType`

## How to Configure

### For libSQL (Recommended for New Installations)

```elixir
# mix.exs
dep do
  [
    {:recollect, "~> 0.2.0"},
    {:ecto_libsql, "~> 0.9"}
    # postgrex and pgvector are not needed
  ]
end

# config/config.exs
config :recollect,
  database_adapter: Recollect.DatabaseAdapter.LibSQL,
  repo: MyApp.Repo,
  embedding: [
    provider: Recollect.Embedding.OpenRouter,
    dimensions: 768
  ]

# config/runtime.exs
config :my_app, MyApp.Repo,
  database: "/path/to/database.db",
  pool_size: 5
```

### For PostgreSQL (Existing Installations)

```elixir
# mix.exs
dep do
  [
    {:recollect, "~> 0.2.0"},
    {:postgrex, "~> 0.19"},
    {:pgvector, "~> 0.3"}
  ]
end

# config/config.exs
config :recollect,
  database_adapter: Recollect.DatabaseAdapter.Postgres,
  repo: MyApp.Repo,
  embedding: [
    provider: Recollect.Embedding.OpenRouter,
    dimensions: 1536
  ]
```

## Key Differences: PostgreSQL vs libSQL

| Feature | PostgreSQL | libSQL |
|---------|------------|--------|
| Vector Type | `vector(n)` | `F32_BLOB(n)` |
| Index Algorithm | HNSW | DiskANN |
| Distance Operator | `<=>` | `vector_distance_cos()` |
| Parameter Style | `$1, $2` | `?` |
| UUID Type | Native `uuid` | TEXT |
| Array Support | Native | Limited (NOT IN instead of != ALL) |
| Extensions Required | pgvector | None (built-in) |

## Migration Path for Existing Users

Users with existing PostgreSQL installations can continue using them. To migrate to libSQL:

1. Export data from PostgreSQL
2. Configure libSQL adapter
3. Create new database file
4. Run migrations
5. Import data

(Export/import tools will be provided in a future update)

## Testing Strategy

The implementation supports running tests against both databases:

```bash
# Test with libSQL (default)
MNEME_ADAPTER=libsql mix test

# Test with PostgreSQL
MNEME_ADAPTER=postgres mix test
```

## Backward Compatibility

- Existing PostgreSQL users: No changes required, continue using current setup
- New users: Default to libSQL for zero-configuration setup
- Optional dependencies: Only the database driver for your chosen backend is required

## Next Steps for Phase 2

1. Update Worth application to use libSQL by default
2. Update Worth's mix.exs and configuration
3. Create database backend selection in Worth.Repo
4. Test the full integration
5. Update documentation
