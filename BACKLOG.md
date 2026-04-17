# BACKLOG

## Stack Transition Detection: Beyond Hardcoded Catalogs

**Priority:** Medium | **Complexity:** High | **Added:** 2026-04-10

### Current state

`Recollect.Learner.Git.StackDetector` detects technology transitions using:

1. A hardcoded `@technology_map` (~30 technologies in 10 categories)
2. A hardcoded `@category_transitions` catalog (~25 known migration paths)
3. Regex matching on commit subjects ("migrate from X to Y", "replace X with Y")
4. Config file presence/absence comparison between git revisions

This works for the common, well-known transitions (webpack→vite, jest→vitest, babel→esbuild) but has hard limits.

### Problems

- **Brittle catalog** — new tools or uncommon transitions are invisible. If someone migrates from parcel to farm, or from cypress to playwright, the detector won't catch it unless we add it manually.
- **No package.json diffing** — we check if config files existed at a point in time, but we don't parse the *contents* of `package.json` at two revisions and diff the dependency lists. A webpack→vite migration that doesn't mention "webpack" or "vite" in commit subjects will be missed by commit scanning, and if both config files exist at both time points, the config-presence check won't help either.
- **No lockfile awareness** — `package-lock.json`, `yarn.lock`, `mix.lock` contain exact dependency trees. Comparing these between revisions would be a high-signal detection method.
- **Single-word matching** — `scan_commit_for_transition` uses `String.contains?(subject, "webpack")` which fails for multi-word names like "create-react-app" when the commit says "remove CRA".
- **No cross-category inference** — if we see sass removed and tailwind added, we should infer a CSS transition even though they're in different categories (`:css_preprocessor` vs `:css_framework`). Currently we have to hardcode these in `@category_transitions`.
- **No confidence scoring** — a transition detected from 5 commits mentioning "webpack" and "vite" should be higher confidence than one inferred from a single config file disappearance.

### Improvement directions

1. **Dependency diffing** — parse `package.json` at two git revisions, diff the dependency keys. Added/deleted deps in the same category (test runner, bundler) are strong transition signals. This would catch migrations that don't have explicit commit messages.

2. **Lockfile parsing** — compare `package-lock.json` or `yarn.lock` between revisions for precise dependency tree changes. More reliable than `package.json` because it captures transitive deps.

3. **Semantic technology mapping** — instead of hardcoded technology entries, build a mapping from npm package names to technology categories. `esbuild-loader` → esbuild, `@vitejs/plugin-react` → vite, `@vue/test-utils` → vue testing, etc. This covers the ecosystem around each tool, not just the tool itself.

4. **Fuzzy matching with embeddings** — embed technology names and check similarity. "farm" and "vite" are both bundlers; the embedding would cluster them. This could surface unknown-but-related transitions.

5. **LLM-assisted classification** — for commits that don't match regex patterns, send the commit subject + diff stats to a lightweight LLM to ask "did this commit change the build tool? test runner? css framework?" One call per learning run, not per commit.

6. **Transition confidence scoring** — combine signals: commit message match (0.7), dependency diff (0.9), config file change (0.8), and emit transitions above a threshold. Store the confidence in the deprecation entry metadata.

7. **Community-sourced catalog** — allow the transition catalog to be loaded from a URL or local file, so it can be updated without code changes. Could be part of JourneyKits.

### Related files

- `lib/mneme/learning/git/stack_detector.ex` — the module to evolve
- `lib/mneme/invalidation.ex` — `deprecate/4` would gain a confidence parameter
- `docs/git-learning.md` — the design doc
