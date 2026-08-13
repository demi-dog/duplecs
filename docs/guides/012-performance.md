# Performance

What replication costs: ballpark overhead ratios for every kind of operation duplecs touches, measured end-to-end — the server ratios include the frame's `generate_packets`, and the client ratios compare reconciling a packet against applying the same changes directly. Every number comes from one benchmark, [`tests/benchmarks/bench_overhead.luau`](../../tests/benchmarks/bench_overhead.luau), so they can be re-measured on your own hardware in seconds (see [Refreshing the numbers](#refreshing-the-numbers)).

## How to read the ratios

Every ratio compares one workload run twice: on a **plain jecs world with duplecs absent entirely**, and on a duplecs world where the same mutations replicate — with the frame's packet build timed alongside them. A ~6x on a value set means "once this component replicates, each set costs about six times what it would in a game that never networks it, packet generation included."

That framing cuts both ways, so keep four things in view:

- **The baselines are some of the cheapest operations in the engine.** A plain `world:set` measures under 0.1 µs here, so even ~6x leaves a networked set at ~0.5 µs — about half a millisecond of server frame time per *thousand* changed values. The absolute columns below anchor every ratio.
- **Bandwidth usually binds first.** The same operations that cost these microseconds also put bytes on the wire, and a typical game runs into its per-player byte budget well before replication registers in a CPU profile. So treat this guide as a map of the extremes to steer clear of — mass-spawn frames, thousands of entities with bespoke visibility — rather than something to optimize against from day one.
- **The ratios amortize `generate_packets` over the row's batch size** (roughly 0.1–1k ops per frame). The call's fixed per-frame cost is measured separately below and is microscopic, so the ratios barely move with smaller batches — but they are averages, not per-op guarantees.
- **The absolutes are one machine** (an x86-64 cloud container under Lune); ratios travel across machines far better than times do, and both are deliberately rounded — runs on the same machine swing a few percent.

Operations duplecs never touches cost nothing extra, on either side of the wire: components without a tracking tag have no hooks connected at all, and reads — `world:get`, queries, iteration — are untouched jecs.

## Server

The headline rows, at the canonical shape: **32 clients, broadcast visibility** (no `Private` filters), hookless values (no [serdes](008-serdes.md)):

| Operation | vs. plain jecs | Absolute |
| --- | --- | --- |
| `world:set`, `Networked` component | ~6x | ~0.5 µs |
| `world:set`, `NetworkedOnce` component | ~1x — free | ~0.08 µs |
| `world:set`, `NetworkedUnreliable` component, `generate_unreliable_chunks` included | ~3x | ~0.3 µs |
| `world:set`, `Networked` pair | ~6x | ~0.6 µs |
| Component remove + set cycle | ~4x | ~1.5 µs |
| Tag remove + add cycle | ~4x | ~1.5 µs |
| Pair retarget (remove old target, set new) | ~5x | ~2.5 µs |
| `Replicated` entity spawn + despawn (two networked components) | ~6x | ~8 µs |

A few readings worth pulling out:

- **`NetworkedOnce` sets are genuinely free** — no changed hook is connected, exactly as [Replication basics](002-replication.md) promises. The same goes for `world:set` on a `NetworkedUnreliable` component in isolation; that row's ~3x is the cost of `generate_unreliable_chunks` re-encoding every visible value each call (a fixed-size f64 serdes hook included), which is the mode's whole deal.
- **The structural rows (toggles, retargets) show lower ratios than value sets** not because duplecs does less there but because the baseline does more — a plain remove+add cycle already pays two archetype moves.
- **Entity lifecycle is the priciest per op.** Spawning and despawning a replicated entity records the entity's appearance and disappearance for every connected client and reads out its current values for the clients gaining it, on top of the plain world's archetype work. ~8 µs per spawn+despawn cycle still means over a hundred replicated spawns per frame before they cost a millisecond, but mass-spawn frames are where duplecs is most visible in a profile.

### Client count

Per-op cost grows with connected clients — sub-linearly, since content every client sees is encoded once and shared between their packets:

| Operation | 8 clients | 32 clients | 128 clients |
| --- | --- | --- | --- |
| `world:set`, `Networked` component | ~5x | ~6x | ~13x |
| `Replicated` entity spawn + despawn | ~5x | ~6x | ~17x |

The jump from 32 to 128 is mostly per-client packet assembly (and, for spawns, per-client visibility updates) scaling with the number of packets actually built.

### Visibility fragmentation

Fragmentation — how many **distinct viewer sets** exist among the changed values — moves `generate_packets` more than raw client count does. Values whose viewers are the same set are encoded once, with every viewer's packet referencing the shared bytes; each additional distinct set is another batch to encode and route. The sweep below churns values on 1024 entities at 64 clients, with each entity's component whitelisted to one of F distinct 16-client filters:

| Distinct filters (F) | 1 | 4 | 16 | 64 | 256 |
| --- | --- | --- | --- | --- | --- |
| `world:set`, `Networked` component | ~7x | ~8x | ~9x | ~12x | ~21x |

Filter *size* — how many clients each set actually contains — matters far less: sweeping the whitelist size from 2 to 48 clients at a fixed 16 distinct filters only moves the same row from ~8x to ~10x.

The design lever this hands you: overhead follows how many *different* visibility situations your world contains, not how strictly it filters. A world where thousands of entities share a handful of filters (teams, regions, [inherited filters](006-visibility-inheritance.md)) stays near the broadcast numbers; per-entity bespoke visibility (per-player loot, tight per-entity proximity sets) is what pushes toward the right column. Filters with equal membership count as the same viewer set even when they are different tables — though sharing one filter via inheritance also makes membership *edits* cheaper, one propagation instead of many.

### The per-frame floor

`generate_packets` on a settled world — everything visible, nothing changed since the last call — costs ~1 µs at 8–32 clients and ~5 µs at 128. Calling it every frame regardless of activity is the intended usage and effectively free; quiet frames return no packets at all.

### Joiners

A newly-added client's first packet is a snapshot of everything currently visible to them, built in one pass. From a world of 1024 replicated entities (1536 visible components across them, an ~11 KB packet), the `add_client` + `generate_packets` pair costs **~0.8 ms** — roughly 0.5 µs per visible component, scaling with what the joiner can see. The join is a genuine spike on both ends (the client's half is below), so worlds holding tens of thousands of visible components should expect multi-millisecond joins.

## Client

The client ratios compare `reconcile_packet` (or `reconcile_chunk`) against applying the same changes to a plain jecs world directly with `world:set` and friends. Reconciliation is a stream-parse plus those same world writes, so the ratios stay low — and a client only ever pays for what is in *its* packet, never for the server's total workload:

| Packet shape | vs. direct application | Absolute |
| --- | --- | --- |
| Component values | ~2x | ~0.15 µs per value |
| Component adds/removes | ~1.5x | ~0.3 µs per op |
| Entity creation/deletion churn | ~3.5x | ~1.8 µs per op |
| Pair values (distinct targets) | ~4x | ~0.5 µs per value |
| Unreliable chunk values (f64 serdes decode included) | ~4x | ~0.3 µs per value |
| Full packet (join snapshot) | ~1.4x | ~2 µs per component |

Entity churn and pair values carry the biggest multipliers because each op does more than a world write: churn maintains the server↔client entity mapping through creations and deletions, and each pair value resolves its target through that mapping as it applies.

The join snapshot is the number to budget for: the same 1536-component packet the server built in ~0.8 ms takes **~3.4 ms** to reconcile into a fresh client world. Most of that is unavoidable world-building (the ~1.4x ratio says direct construction costs ~2.4 ms of it), and it lands on a single frame at exactly the moment a player joins.

## Serdes

Every reliable-path row above is hookless — values ride the packet's side array, the day-one default. Registering [serdes hooks](008-serdes.md) moves a component's values into the packet buffer for a fraction of the bandwidth, at the price of running your `encode`/`decode` per shipped value inside the generate and reconcile calls; the unreliable rows above include a minimal fixed-size hook and show the shape of that cost. Encode cost does not scale with player count: duplecs never encodes a value more than once per generate call, however many clients receive it — the encoded bytes are shared between their packets — and each client decodes only its own packet, on its own machine. The trade is bandwidth against CPU, and the hooks' own speed is part of it — `tests/benchmarks/bench_serdes.luau` isolates the hooked paths if you want to measure a specific encoding.

## Refreshing the numbers

```sh
lune run tests/benchmarks/bench_overhead.luau
```

Every table in this guide is a rounded reading of that benchmark's output — each row prints the plain time, the duplecs time, and the ratio. Absolute times are machine-specific; the ratios above were measured on an x86-64 cloud container under Lune and rounded from runs that agree within a few percent. The workload shapes (batch sizes, client counts, filter pools) are constants at the top of the benchmark and are restated by its output header, so a reading is always interpretable on its own.
