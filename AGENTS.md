# Recollect — Agent Instructions

## Dev Commands

- `mix test` — runs `ecto.create` → `ecto.migrate` → tests. A running PostgreSQL instance with pgvector extension is required.
- `mix format` — code formatter; run before committing.
- `mix recollect.gen.migration --dimensions N` — generate the database migration. You must run `mix ecto.migrate` afterward to apply it.

## Architecture

- Single-package Elixir library (not a monorepo). All code lives in `lib/recollect/`.
- Mix tasks are in `lib/mix/tasks/`.
- Test support files under `test/support/` are only compiled in the test environment (`elixirc_paths(:test)` in `mix.exs`).
- Two tiers: **Tier 1** (full pipeline: ingest → chunk → embed → extract → graph) and **Tier 2** (lightweight: remember/forget/connect). They share the search and embedding layers.

## Extension Points (Behaviours)

- `Recollect.EmbeddingProvider` — add a new embedding backend (e.g. local Ollama).
- `Recollect.ExtractionProvider` — customize entity/relation extraction logic.
- `Recollect.GraphStore` — swap the graph backend (default: PostgresGraph using recursive CTEs).

## Key Conventions

- `owner_id` and `scope_id` appear on all schemas. `owner_id` is the user who owns the data; `scope_id` is the workspace/project.
- All API functions return `{:ok, _}` or `{:error, reason}` tuples; never raise on expected error paths.
- Configuration is always via `config :recollect, ...` in the host application. No compile-time credentials; use `credentials_fn` for runtime resolution.

## Versioning

This library is consumed as a git dependency by Worth. When adding new functionality or making breaking changes, you **must** create a new git tag (e.g., `v0.2.0`) so that Worth's `mix.exs` can pin to a specific version. Follow semantic versioning.
