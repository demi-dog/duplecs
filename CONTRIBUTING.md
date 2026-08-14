# Contributing to duplecs

Development runs standalone under [Lune](https://github.com/lune-org/lune) against the repo layout — no Roblox instance or place file involved. This document covers the setup, the repository layout, the checks a change must keep green, and the changelog and release process.

## Setup

Tools are pinned in `rokit.toml`; [rokit](https://github.com/rojo-rbx/rokit) fetches them (Lune, StyLua, luau-lsp):

```sh
rokit install
lune run tests/setup.luau   # once: fetch the pinned jecs release directly into roblox_packages/
```

`lune run tests/setup.luau` fetches the jecs source directly, whereas a `pesde install` run inside this repo would link a Roblox-only stub in its place (Wally-sourced packages are linked with instance-based requires); re-run `tests/setup.luau` if that happens.

## The jecs dependency

`pesde.toml` declares jecs as a range (`^0.11.0`), so consumers resolve any in-range release — the width is deliberate, since duplecs and the consumer's own jecs dependency must resolve to a single installation (see the foreign-instance warning under `docs/spec.md`'s Construction). Development, CI, and the suite run against exactly one release, though: the tag `tests/setup.luau` fetches, kept in sync with the constraint by the comment above it. Treat the gap between the two as a standing hazard rather than semver's problem: duplecs reaches into jecs beyond its documented surface (`src/hooks.luau` writes hook fields onto component records; the packet passes read archetype storage directly), so a new in-range jecs release is not automatically safe.

When a new in-range jecs version releases: bump `tests/setup.luau`'s tag, run the verification suite and both typechecks against it, and cut a duplecs release recording the outcome — the new tag as the development pin when green, or a narrowed `pesde.toml` constraint when not. Until that release exists, a consumer resolving the new jecs is running a combination nothing has verified.

## Layout

- `src/` — the module, split into a server half, a client half, and the shared per-world component set. Returns `{ server, client, shared }` — three per-world memoized accessors (see `docs/spec.md`'s Construction section). Requires jecs via `require("../roblox_packages/jecs")`, the path pesde links for consumers and `tests/setup.luau` populates for development.
  - `src/init.luau` — the entry point: the three accessors plus re-exports of the public types.
  - `src/shared.luau` — the shared leg: mints the per-world component set and record at a world's first duplecs contact; the record is anchored inside the world itself (luau weak tables have no ephemeron semantics, so nothing module-level may reference a world) and carries the halves' memoized instances.
  - `src/server.luau` — the server half: change tracking, per-client visibility, and packet generation.
  - `src/pools.luau` — the server's recycling pools: scratch tables plus the section draft and run pools the packet passes build with.
  - `src/names.luau` — the server's shared-name store: the announced (id, name) set clients map ids by, plus the announce/retract staging the packet passes drain.
  - `src/client.luau` — the client half: server/client entity mapping, reconciliation overrides, and packet reconciliation.
  - `src/types.luau`, `src/wire.luau`, `src/serdes.luau`, `src/hooks.luau`, `src/diagnostics.luau` — the shared types, the wire format (the layouts and every function that encodes or decodes their bytes), the serdes store, the hook-registration wrappers every `world:added`/`changed`/`removed` in the tree goes through (a workaround for a jecs 0.11.0 bug, removable as cleanup once it is fixed upstream — the file header states the bug and the repair), and the diagnostics helpers (the `[duplecs]` message prefix, id rendering for warn/error messages, and the per-instance injectable warn hook).
- `tests/setup.luau` — fetches the pinned jecs release directly into `roblox_packages/`.
- `tests/verification_suite.luau` — the verification suite. (389 tests)
- `tests/benchmarks/bench_*.luau` — various benchmarks testing duplecs directly.
- `docs/guides/` — the user-facing guides: a getting-started setup guide plus per-feature guides with code examples, indexed from `docs/guides/README.md`.
- `docs/api.md` — the public minimal API listing: every notable export with a short description.
- `docs/spec.md` — the detailed public API and low level behavior specification.
- `CHANGELOG.md` — per-release change history; every entry states whether the wire format changed, so this is how consumers decide when (and how carefully) to upgrade.
- `globals.d.luau` — ambient globals (`warn`) for `luau-lsp analyze`.

## Running the tests

```sh
lune run tests/verification_suite.luau  # the verification suite
lune run tests/benchmarks/bench_generate_packets.luau   # or any other bench
```

The verification suite is the tree's single test entry point: every change is expected to keep it green, and new behavior lands with coverage there. The suite asserts warnings as well as state — each test declares the `[duplecs]` warnings it expects and the runner checks that exactly those fired, in that order, so a test declaring none asserts silence.

## Formatting and comment style

```sh
stylua .   # format (config in stylua.toml; fetched dependencies excluded via .styluaignore)
```

StyLua owns the code layout (tabs, 120 column width). Comments follow two rules it can't enforce:

- Standalone prose comments wrap at 110 columns — narrower than the 120 code width, for a small readability margin.
- Column-aligned layout diagrams (e.g. `wire.luau`'s wire-format tables) stay verbatim; they are exempt from the wrap.

## Typechecking

```sh
luau-lsp analyze --flag:LuauSolverV2=true --platform standard --definitions=globals.d.luau --ignore "roblox_packages/**" src
```

The typecheck runs under the new Luau type solver (`--flag:LuauSolverV2=true`), and `.vscode/settings.json` enables the same solver for the editor's language server. The sources must also stay clean under the old solver (run with `--flag:LuauSolverV2=false`), since consumers analyze them with whatever solver their tooling defaults to; CI enforces both.

## CI

CI (`.github/workflows/ci.yml`) runs the verification suite, `stylua --check .`, and both typechecks on every push and pull request. The repository is normalized to LF line endings via `.gitattributes` so StyLua behaves identically on every platform.

## Documentation

Three public docs layers sit above the sources, and a user-visible change should keep them in sync:

- `docs/spec.md` — the exact contract; update it alongside any behavior change.
- `docs/api.md` — the compact export listing; update it when the public surface changes.
- `docs/guides/` — task-oriented guides; touch them when a workflow they teach changes.

All three layers are user-facing, so they speak plain language: describe behavior in the reader's terms, and keep the source's internal vocabulary — cells, shards, visibility nodes, masks, staging, scatter — out. A technical term is fine where the document itself introduces it for the reader; what must not leak is a name only a source reader would know. The changelog is user-facing too and follows the same rule, from its first entry on.

Two guides carry measured numbers rather than prose alone. The performance guide's tables (`docs/guides/012-performance.md`) are rounded from `tests/benchmarks/bench_overhead.luau`'s output; after a change that could move performance — the packet passes, the hooks, reconciliation — re-run that bench and re-round any table it shifts. The bandwidth guide's tables (`docs/guides/013-bandwidth.md`) restate `tests/benchmarks/bench_bandwidth.luau`'s output byte-exactly; they are deterministic, so only a wire-format change can move them — re-run that bench alongside any change to `src/wire.luau`'s layouts and update every table (and per-entry price in the prose) it shifts.

Two of those layers are checked mechanically by the verification suite, because both drifted from the sources in practice: `docs/api.md` must carry a heading for every key the server and client instances return (underscore-prefixed debug exports aside), and `docs/spec.md`'s warnings-and-errors appendix must quote every message the module's `warn(` / `fail(` calls raise — and no message they don't. So a new diagnostic lands with its appendix entry, and a reworded one with the matching edit there; the suite names the missing or stale text either way.

## Changelog

`CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and version numbers follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Every notable change lands under the `Unreleased` heading in the matching category as it merges. Two conventions on top of the format: breaking API changes lead with **Breaking:**, and every entry states whether the wire format changed — both sides of the wire must run the same duplecs build, so wire changes are what force consumers into lockstep upgrades.

## Releasing

To cut a release: bump `version` in `pesde.toml` and in `wally.toml` (the workflow refuses to release a drifted pair), move the changelog's Unreleased content under a matching `## [x.y.z] - date` heading, and push to `main` — the release workflow (`.github/workflows/release.yml`) re-runs CI's checks, creates and pushes the `v<version>` tag, publishes the release to the pesde and Wally registries, and attaches the Studio `.rbxm` to the tag's GitHub release, refusing to tag a version the changelog doesn't document. A follow-up push that merely fixes a refused or partly failed release gets tagged and published without another version bump: each publish step checks its own registry, so nothing publishes twice. The README's install examples use semver ranges, so they need no per-release edit.
