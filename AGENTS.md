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

This library is consumed as a git dependency by Worth and published to [Hex.pm](https://hex.pm/packages/recollect). Follow semantic versioning. Keep the `@version` in `mix.exs`, the git tag, and the Hex publish in sync.

### Release SOP

1. **Bump `@version`** in `mix.exs` (line 4). This also updates `source_ref` in the docs config (line 85).
2. **Run checks**: `mix format`, `mix test`, `mix docs` — verify everything passes.
3. **Commit** the version bump with message `v{VERSION}`.
4. **Tag** the commit: `git tag v{VERSION}`. The tag name must match `mix.exs` exactly (prefixed with `v`).
5. **Push**: `git push origin main --tags`.
6. **Publish to Hex**: `mix hex.publish`. This builds docs and uploads the package. Ensure `HEX_API_KEY` is set.

After publishing, verify at:
- GitHub releases: https://github.com/kittyfromouterspace/recollect/releases
- Hex package: https://hex.pm/packages/recollect

### Version History

| Version | Git Tag | Hex Published | Notes |
|---------|---------|---------------|-------|
| 0.4.5   | `v0.4.5` | Yes | Moved tag to include ex_doc setup |
