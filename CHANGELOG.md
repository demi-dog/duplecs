# Changelog

All notable changes to duplecs are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and version numbers follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Every entry states whether the wire format changed: both sides of the wire must run the same duplecs build, so a wire change means upgrading the server and its clients together — check here before upgrading.

## [Unreleased]

### Fixed

- Adding or removing `Replicated` no longer risks a hidden cost proportional to the world's replicated-entity count: an internal table keyed by full entity ids made Luau rebuild it on nearly every spawn whenever the number of replicated entities sat at (or one below) a power of two while entities churned. Spawn-and-despawn overhead at the benchmark's canonical shape (32 clients, two networked components) drops from ~14x to ~6x the cost of the same lifecycle on a world that isn't networked at all — see the updated tables in the [performance guide](docs/guides/012-performance.md). The wire format is unchanged.

## [1.0.0] - 2026-08-12

The initial public release, published to the pesde registry as `demidog/duplecs` and the Wally registry as `demi-dog/duplecs`. Earlier development versions were never published — no public tags, no registry entries — so this changelog starts here, and later releases document their changes against this one.

duplecs is generalized per-world replication for [jecs](https://github.com/Ukendio/jecs): it listens for changes in the server's jecs world, decides what should replicate to whom, packs the result into one filtered packet per client, and reconciles that data back into each client's world. duplecs does not own transport — sending packets to clients is the caller's responsibility, typically using a `RemoteEvent`.

What this release ships:

- **Opt-in replication** — a component reaches a client only when its definition is marked `Networked`, the entity carrying it is marked `Replicated`, and neither is blocked by a `Private` filter.
- **Visibility filters and inheritance** — `Private` filters assigned per entity or per component (an empty one for server-only state, a client-keyed one for whitelists and blacklists), with multiple entities able to inherit one entity's filter so their visibility is edited from a single place.
- **Relationship support** — networked relations like `jecs.ChildOf`, by tagging the relation itself; a pair is never sent to a client who cannot see its target, and per-component filters also prune pairs using that component as a relation.
- **Nothing sent twice** — a change ships the frame it happens and is never re-sent on the reliable path; a client joining later gets one packet holding everything currently visible to them; `NetworkedOnce` definitions ship values only when the component is added.
- **Mapped entity ids** — the server and each client often hold different ids for the same entity, so duplecs maps them both ways on the client: replicated entities map themselves, shared components map by name so definition order can differ between sides, and methods exist for reading or assigning the mappings yourself.
- **Serdes hooks** — give a component's values a byte encoding and they pack into the packet's buffer, for a fraction of the bandwidth; components without hooks ride a plain side array, so day one needs no byte encodings.
- **An unreliable channel** — every-frame changes (e.g. positions, velocities) can be routed through self-contained chunks sized for unreliable transports.
- **Client-side control** — reconciliation overrides put your code between the wire and the world: id translation, prediction gating, and interpolation buffers.

The wire format starts fresh at this release.
