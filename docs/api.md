# duplecs API Documentation

This document lists the public API of duplecs — generalized per-world replication for [jecs](https://github.com/Ukendio/jecs) — with a short description of each export. For the complete contract behind every entry (exact guarantees, edge cases, and performance notes), see the specification in [`spec.md`](spec.md); for task-oriented introductions with code examples, the [guides](guides/README.md).

## duplecs

The module root returns three per-world **construct-once accessors** and re-exports every public type: each accessor constructs on its first call for a world and returns that same result ever after, so any system can resolve them from the world alone. The world's first duplecs contact — whichever accessor that is — creates the component set and warns (once per world) if `world` was created by a different jecs instance than the one duplecs resolves; treat that as a misconfiguration and resolve the project to a single jecs installation.

#### `duplecs.server(world: World) -> ServerInstance`
The server half for a world: change tracking, per-client visibility, and packet generation. The first call constructs it — connecting the replication hooks and catching up on anything already tagged through the shared set before construction (pre-existing misuses error here) — and returns the server methods alongside the server-side components (`Networked`, `NetworkedOnce`, `NetworkedUnreliable`, `Replicated`, `Private`, `InheritsPrivacy`, `Serdes`). Tracking is live from construction, with nothing further to call.

#### `duplecs.client(world: World) -> ClientInstance`
The client half for a world: server/client entity mapping, reconciliation overrides, and packet reconciliation. The first call constructs it — connecting the entity-mapping and name-index hooks — and returns the client methods alongside the client-side components (`Imported`, `Serdes`).

#### `duplecs.shared(world: World) -> Components`
The world's full component set — `Networked`, `NetworkedOnce`, `NetworkedUnreliable`, `Replicated`, `Private`, `InheritsPrivacy`, `Serdes`, `Imported` — as one frozen table, created at the world's first duplecs contact. The same ids the instances return, for code that runs on both sides: a shared definitions module can tag definitions `Networked` and register `Serdes` hooks without knowing which half the world will construct; a tag is inert until the half that owns it is constructed, and each half's construction catches up on whatever was tagged before it.

## Server

Returned by `duplecs.server`. Every method is a plain function called with a dot (`server.generate_packets()`), not a method.

#### `server.add_client(client: Client)`
Queues `client` as a pending joiner. The client's slot is allocated and their first (full) packet is produced at the end of the next `generate_packets`. No-op if the client is already tracked or pending. A client is any value — typically a `Player`.

#### `server.remove_client(client: Client)`
Frees the client's slot (or cancels a pending join). The departing client is pruned from every cached privacy filter, so a later rejoin under the same value always starts unlisted.

#### `server.is_client_tracked(client: Client) -> boolean`
Returns whether the client is currently registered with this instance — `true` from `add_client` until `remove_client`, pending joiners included (even though the visibility queries below all answer `false` for a pending joiner until their slot is allocated).

#### `server.generate_packets() -> { [Client]: Packet }`
Builds every client's packet in a single pass and returns them keyed by client — a delta of changes since the last call for existing clients, a full packet for newly-joined (or freshly-marked) ones. Drains all change accumulators, so call it once per replication step; every returned packet shares the packet frame the call advances. Clients with nothing to receive are omitted. Sending each packet to its client is the caller's responsibility.

#### `server.generate_unreliable_chunks(chunk_bytes: number?) -> { [Client]: { buffer } }`
Builds the always-replicate chunks for `NetworkedUnreliable` components: every visible value is re-read and re-sent on every call, packed into self-contained chunk buffers of at most `chunk_bytes` bytes (default 980, sized for Roblox's 1000-byte unreliable remote limit), for the caller to send through an unreliable transport each frame. Drains nothing and can be called at its own rate; visibility follows the last reliable packets sent. Chunk buffers are shared by reference between clients with equal visibility — never mutate them.

#### `server.is_entity_visible(entity: Entity, client: Client) -> boolean`
Returns whether the entity's existence is currently visible to the client — reflecting entity replication and the entity-level privacy filter, including changes made this frame that no packet has carried yet. Always `false` for an untracked client.

#### `server.is_component_visible(entity: Entity, component: Id, client: Client) -> boolean`
Returns whether a component (or pair) on an entity is currently visible to the client — reflecting every gate `generate_packets` applies, including changes made this frame that no packet has carried yet. Exposed so callers can gate side-channel replication (e.g. events sent outside the packet stream) by the same rules. Always `false` for an untracked client.

#### `server.was_entity_visible(entity: Entity, client: Client) -> boolean`
The last-sent counterpart to `is_entity_visible`: whether the entity was visible to the client as of the most recent `generate_packets`, ignoring anything changed since. Use it to reason about what the client actually holds right now.

#### `server.was_component_visible(entity: Entity, component: Id, client: Client) -> boolean`
The last-sent counterpart to `is_component_visible`: whether the component (or pair) on the entity was visible to the client as of the most recent `generate_packets`, ignoring anything changed since.

#### `server.get_clients_seeing(entity: Entity) -> () -> Client?`
Returns an iterator over the clients the entity is currently visible to — exactly the clients `is_entity_visible` answers `true` for, read straight off the visibility masks rather than probing every client (`for client in server.get_clients_seeing(entity) do`). For sight-gated side channels — an event for exactly the clients who can see the source — and for debugging privacy setups. Enumeration order is unspecified, and pending joiners never enumerate.

#### `server.get_clients_last_seeing(entity: Entity) -> () -> Client?`
The last-sent counterpart to `get_clients_seeing`, mirroring `was_entity_visible`: iterates the clients that actually hold the entity as of the most recent `generate_packets`, ignoring anything changed since.

#### `server.edit_entity_privacy(entity: Entity, client: Client, allowed: boolean)`
Edits one client's standing in the entity's entity-level (unpaired `Private`) filter, replacing the frozen filter table with an edited copy and preserving whether it is a whitelist or a blacklist — on a whitelist `true` adds and `false` removes the client, on a blacklist `false` names and `true` un-names them. With no filter configured, `false` starts a blacklist naming just `client`; `true` warns and does nothing (admission needs an existing whitelist). No-op if the client is already in the requested state.

#### `server.edit_component_privacy(entity: Entity, component: Component, client: Client, allowed: boolean)`
Same as `edit_entity_privacy`, but for the entity's `pair(Private, component)` filter — gating that component, and pairs using it as a relation, on the entity.

#### `server.force_replicate(entity: Entity, component: Id)`
Queues the component's current value on the entity for the next `generate_packets` to send, respecting per-client visibility. Intended for `NetworkedOnce` components, whose continuous changes are otherwise not tracked. No-op if the entity lacks the component.

#### `server.mark_client_fresh(client: Client)`
Declares that the client world behind an already-allocated slot has never reconciled a packet from this server world, so the next `generate_packets` returns a full packet for that client in place of their delta, while the slot's privacy filters and visibility state persist. For games that keep a slot allocated across reconnection or substitution. Not a resync knob: a full packet carries no removals, so the receiving world must genuinely be fresh.

#### `server.set_warn_hook(hook: ((message: string) -> ())?)`
Replaces where this instance's warnings go — the global `warn` by default — or restores the global when `nil`. Every duplecs warning and error message is prefixed `[duplecs] `, and the hook receives exactly the string the global would have printed. For test harnesses and telemetry capturing warnings; errors always raise regardless of the hook. Every message duplecs emits is listed, with the condition behind it, in the [spec's warnings-and-errors appendix](spec.md#appendix-warnings-and-errors).

## Server Components

The server-side slice of the world's component set, returned on the server instance (and in `duplecs.shared`'s full set — the same ids).

#### `server.Networked`
Tag added to a **component (or relation) definition** to mark it as eligible for replication — both the unpaired component and every pair using it as the relation. A pair only replicates if its target is replicable (itself `Replicated`, or named via `jecs.Name`). Mutually exclusive with the other two tracking tags and with `Replicated`; misuse removes the offending tag and errors.

#### `server.NetworkedOnce`
Tag added to a **component (or relation) definition** instead of `Networked` to make it replicate-once: adds, removals, visibility changes, and full packets replicate, but value changes are not tracked at all — for values the client simulates itself, e.g. countdown timers. Push an occasional authoritative update with `force_replicate`.

#### `server.NetworkedUnreliable`
Tag added to a **component (or relation) definition** instead of `Networked` to stream its values through the unreliable channel: membership stays on the reliable path (like `NetworkedOnce`, a `world:set` costs nothing on the server), while `generate_unreliable_chunks` re-reads and re-sends every visible value each call — for values that change every frame, e.g. positions. Values must have `Serdes` hooks registered, and tags are refused.

#### `server.Replicated`
Tag added to a **gameplay entity** to mark that its networked components should replicate. Adding it begins tracking every currently-eligible component and pair on the entity (and every networked pair pointing at it); removing it stops replication and unreplicates the entity for clients.

#### `server.Private`
The component backing both privacy filter layers: an unpaired `Private` on an entity gates which clients the whole entity replicates to, and `pair(Private, component)` gates a single component (and its relation pairs) on that entity. Set to an empty `Privacy` table it blocks every client outright — the mechanism for server-only state. Set to a populated `Privacy` table it filters selectively: all-`true` values form a whitelist, all-`false` a blacklist, mixing polarities errors, and an empty table reads as a whitelist blocking everyone. A filter is always a table: a `nil` value (`world:add`, or a `world:set` of `nil`) warns and is rewritten to an empty filter, so it still blocks everyone, while a non-table value or a client mapped to a non-boolean is reverted and errors. Values are frozen once set — edit membership through `edit_entity_privacy`/`edit_component_privacy` or wholesale `world:set` replacement.

#### `server.InheritsPrivacy`
Relation added to a **gameplay entity** as `pair(InheritsPrivacy, group)` to make its entity-level visibility inherit `group`'s unpaired `Private` filter on top of the entity's own — a client must pass both — so one filter edit on the group updates every entity inheriting from it (a squad's shared visibility, or vehicle parts following their hull). An entity may inherit from several groups at once and must pass every one of them; inheritance can branch, and can reach through groups that inherit from further groups, but it can never loop (cycles error). Only the entity-level gate inherits; per-component filters stay local. Deleting a group deletes every entity inheriting from it — remove the pair first when an inheritor should outlive its group.

## Client

Returned by `duplecs.client`. Every method is a plain function called with a dot, like the server's.

#### `client.reconcile_packet(packet: Packet)`
Applies a received reliable packet to the local world: deletes newly-unreplicated entities, creates newly-replicated ones, registers the packet's shared-name announcements, and applies each section's value changes and removals.

#### `client.reconcile_chunk(chunk: buffer)`
Applies one received unreliable chunk to the local world. Drop- and reorder-tolerant by construction: stale chunks are dropped whole, chunks of one frame apply in any order, and ids that don't resolve locally yet skip harmlessly. The unreliable stream only updates existing state — with no override registered, a value applies only where the client entity currently has the component, so it can never resurrect a reliably-removed one.

#### `client.get_packet_frame(packet: Packet) -> number`
Returns the packet frame a packet carries — shared by every packet of one `generate_packets` call — without reconciling it, so a caller splitting packets across channels can group, dedupe, or order them (see the spec for the exact comparison rule) before applying. Validates the wire version first, like `reconcile_packet`.

#### `client.get_chunk_frame(chunk: buffer) -> number`
Returns the chunk frame a chunk carries — shared by every chunk of one `generate_unreliable_chunks` call, and independent of the packet frame — without reconciling it. Validates the chunk version first, like `reconcile_chunk`. Read it before reconciling to timestamp the values your changed overrides capture (reconcile is synchronous, so an upvalue carries it into the overrides).

#### `client.set_client_entity(server_entity: number, client_entity: Entity)`
Registers a mapping between a server id and a client entity and tags the client entity `Imported`. Primarily for prediction — a client creates a stand-in entity immediately, learns the server id through a side channel (typically echoed back off the triggering request alongside the stand-in's own id), and maps it so the server's creation adopts the stand-in — and for startup mapping of definitions that shared names don't cover. Mapping does not claim the entity as client-owned; it will be deleted if the server entity is deleted. Errors if the server id is already mapped to a live client entity, so a predicting caller should check `get_client_entity` first, and on losing that race adopt the server's entity and discard the now-duplicate stand-in.

#### `client.get_client_entity(server_entity: number) -> Entity?`
Returns the client entity mapped to a server id, or `nil` if unmapped. Pass the full gen-qualified id as learned from `get_server_entity` or a creation/names entry — a stale generation resolves to `nil` rather than to the slot's current tenant.

#### `client.get_server_entity(client_entity: Entity) -> number?`
Returns the server id for a client entity, or `nil` if it has no mapping. This is the id to send to the server when referencing an entity in a request.

#### `client.set_changed_override<T>(component: Id<T>, on_changed: ChangedOverride<T>?)`
Registers (or clears, when `nil`) the handler invoked during reconciliation for the component's set and `nulled` entries, replacing the default `world:set`/`world:add`. A pair with a wildcard target registers per-relation; concrete pairs without their own override fall back to their relation's. Typical uses: client-side prediction, and translating server ids embedded in payloads.

#### `client.set_removed_override(component: Id, on_removed: RemovedOverride?)`
Registers (or clears, when `nil`) the handler invoked during reconciliation for the component's `removed` entries, replacing the default `world:remove`. Same per-relation fallback as changed overrides.

#### `client.get_changed_override<T>(component: Id<T>) -> ChangedOverride<T>?`
Returns the changed override registered for exactly the key you pass — a pair with a wildcard target reading as its relation, as at registration — or `nil`. Never the relation fallback. Useful for caching and wrapping an existing override.

#### `client.get_removed_override(component: Id) -> RemovedOverride?`
Returns the removed override registered for exactly the key you pass — a pair with a wildcard target reading as its relation, as at registration — or `nil`. Never the relation fallback. Useful for caching and wrapping an existing override.

#### `client.set_warn_hook(hook: ((message: string) -> ())?)`
Same as the server's `set_warn_hook`: replaces where this instance's warnings go (the global `warn` by default), or restores the global when `nil`.

## Client Components

#### `client.Imported`
Tag automatically applied to any client entity registered in the server↔client mapping — through `set_client_entity`, a creation entry, or a shared-name announcement. Managed internally; adding it to a non-imported entity is rejected, and removing it tears down the entity's mapping.

## Serdes (server & client)

#### `Serdes`
Component set on a **component (or relation) definition entity** to register serdes — serialize/deserialize — hooks for it: the byte encoding its values pack inline into packets with. Exists on both instances (`server.Serdes` / `client.Serdes`) and in the shared set, and must be registered symmetrically on both sides — the shared definitions module is the natural place. A component without hooks still replicates on the reliable path — its values travel in the packet's `values` side array instead — but `NetworkedUnreliable` values require hooks. A registration on a relation covers every pair using it as the relation; `pair(Serdes, target)` registers hooks for one concrete pair, taking precedence. Tags cannot carry hooks.

```lua
world:set(Loadout, net.Serdes, {
    encode = function(value) return SomeLib.serialize(value) end,
    decode = function(data) return SomeLib.deserialize(data) end,
})
```

The hooks match the one-buffer-per-value signatures third-party serdes libraries expose: `encode` returns a buffer holding exactly one value's bytes, `decode` receives one such buffer. An optional static `size` declares a fixed byte length every value encodes to, omitting the per-value length prefix — both sides must agree on it, since it changes the framing. A serdes hook erroring is contained (see the spec's Serdes section for the exact containment rules): exactly the failing values are dropped with a warning and everything else still ships — a value dropped from a reliable packet replicates again when it next changes, one dropped from the unreliable channel re-sends next call.

## Types

All public types are exported from the module root, regardless of which half defines them. jecs's own types are deliberately not among them — every consumer requires jecs anyway, so take them from there. The `World`, `Entity`, `Component`, and `Id` names in this document's signatures are plain jecs aliases: `jecs.World`, `jecs.Entity<nil>`, `jecs.Entity<T>` (an entity used as a component), and `jecs.Id<T>` (an id that may be a pair). `Client` is notation the same way, not an export: a client is whatever value the caller registers (typically a `Player`), so signatures write `Client` for plain `any`.

#### `ServerInstance` & `ClientInstance`
The types of the instances `duplecs.server` and `duplecs.client` return. Direct accessor calls already carry them through inference; the exports exist for the annotations inference can't reach — a typed field holding an instance, or a parameter at a module boundary.

#### `Components`
The full per-world component set `duplecs.shared` returns — one frozen table per world, shared by all three accessors.

#### `Privacy`
`{ [Client]: boolean }` — the value type for both privacy filter levels. All-`true` values form a whitelist, all-`false` a blacklist; mixed values error, and an empty table reads as a whitelist blocking everyone.

#### `Packet`
`{ data: buffer, values: { { any } }? }` — the per-client unit of replication. `data` is the wire-ready packet buffer; `values` holds the hookless sections' value arrays in section order, shared by reference between clients — never mutate them.

#### `Serdes<T = any>`
`{ size: number?, encode: (value: T) -> buffer, decode: (buf: buffer) -> T }` — the value type of the `Serdes` component. Values passed to the hooks are never `nil`; nulled entries travel in their own list.

#### `ChangedOverride<T = any>`
`(Entity, T) -> ()` — signature of a changed override handler. `nulled` entries invoke the handler with no value, so when nulls are possible for the component (a tag, or a data component set to `nil`), declaring `T` nillable is the caller's responsibility.

#### `RemovedOverride`
`(Entity) -> ()` — signature of a removed override handler.
