# duplecs Guides

Task-oriented guides for using duplecs, each built around working code.

The [API reference](../api.md) — a compact listing of every export with a short description — is worth scanning first, to see the whole surface these guides walk through.

Start with [Getting started](001-getting-started.md) if you're new; the rest are per-feature and readable in any order. For the complete contract behind any behavior — exact guarantees, edge cases, performance notes — see the [specification](../spec.md).

## Setup

- **[Getting started](001-getting-started.md)** — from an empty project to entities replicating: the shared component module, server and client wiring around a minimal scheduler, a runnable live-changes demo narrated packet by packet, and the common early mistakes.

## Core replication

- **[Replication basics](002-replication.md)** — the two eligibility gates (`Networked` + `Replicated`), the delta model, and choosing between the three tracking modes (`Networked`, `NetworkedOnce`, `NetworkedUnreliable`).
- **[Replicating relationships](003-pairs.md)** — networking relations like `ChildOf`, what makes a pair target replicable, and target-deletion behavior.
- **[Entities across the network](004-entity-mapping.md)** — server vs. client ids, automatic mapping via shared names, sending entity references in requests, and the prediction flow.

## Controlling who sees what

- **[Visibility filters](005-visibility-filters.md)** — server-only state with a single empty `Private` table, whitelists and blacklists, and editing membership.
- **[Visibility inheritance](006-visibility-inheritance.md)** — one entity's filter followed by many others: multi-entity objects, squads, and combining independent gates.
- **[Visibility queries](007-visibility-queries.md)** — gating side-channel sends by the same rules packets follow, enumerating who sees an entity, and debugging filter setups.

## Values on the wire

- **[Serdes](008-serdes.md)** — serialize/deserialize hooks that pack values into the packet buffer: starting from a third-party library, fixed-width encodings, and the rules hooks must follow.
- **[Unreliable values](009-unreliable.md)** — streaming per-frame values (positions, velocities) through chunks: setup, drop tolerance, and interpolation timestamping.

## Client-side control

- **[Reconciliation overrides](010-overrides.md)** — putting your code between the wire and the world: id translation, prediction gating, and interpolation buffers.

## Lifecycle

- **[Client lifecycle](011-client-lifecycle.md)** — joins, departures, filter pruning on departure, and handing a slot's stream to a new connection with `mark_client_fresh`.

## Performance

- **[Performance](012-performance.md)** — ballpark overhead ratios for every operation duplecs touches, end-to-end and re-measurable in seconds: the server and client cost tables, the client-count and visibility-fragmentation scaling axes, and budgeting for the join spike.
- **[Bandwidth](013-bandwidth.md)** — the byte cost of everything duplecs puts on the wire, exact and machine-independent: per-value and per-entity prices under each encoding, measured packet sizes for representative frames, the join snapshot, and budgeting the unreliable channel.
