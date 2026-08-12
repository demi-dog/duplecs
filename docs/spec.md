# duplecs Specification

This document is the specification of `duplecs` — the complete, exact description of its observable behavior: every export, its contract, and the guarantees behind it. It favors precision over approachability, and it includes advisory notes on performance characteristics where they shape correct usage. For task-oriented introductions with code examples, see the [guides](guides/README.md) instead.

`duplecs` is per-world generalized replication for jecs. It tracks component and pair changes via hooks, resolves per-client visibility at change time, generates one filtered packet per client in a single pass — a delta for existing clients, a full packet for newly-joined ones — and reconciles those packets back into ECS state on the client. It is the layer beneath the caller's networking systems: it decides *what* data replicates to *whom* and how to apply it, but it owns no transport. Each returned packet is a wire-ready flat buffer, plus a side array of values for components without serdes hooks (see Serdes); sending them over the wire is the caller's responsibility. Reliable packets from `generate_packets` are applied on the client with `reconcile_packet`; the chunks from `generate_unreliable_chunks` (see Unreliable values under Concepts) are sent through an unreliable transport and applied with `reconcile_chunk`.

The module is agnostic about what a "client" is: a client is any value the caller hands to `add_client` (typically a `Player`). The `Client` name this document's signatures use is notation for exactly that `any`, not an exported type (see Types).

## Construction

`duplecs` is a per-world module split into a server half and a client half, sharing one component set. The module returns three **per-world memoized accessors** — `server`, `client`, and `shared` — each of which constructs on its first call for a given world and returns that same result on every later call, so any system can resolve them from the world alone rather than threading an instance around:

```lua
local duplecs = require("./roblox_packages/duplecs")

-- anywhere on the server
local net = duplecs.server(world)

-- anywhere on a client
local net = duplecs.client(world)

-- anywhere on either side (e.g. a side-agnostic schema module)
local net = duplecs.shared(world)
```

### `duplecs.shared(world: World) -> Components`

Returns the world's full duplecs component set — `Networked`, `NetworkedOnce`, `NetworkedUnreliable`, `Replicated`, `Private`, `InheritsPrivacy`, `Serdes`, and `Imported` — minting it (as one frozen table) at the world's **first duplecs contact**, whichever accessor that is. All three accessors draw on the one set per world, so `duplecs.server(world).Networked == duplecs.shared(world).Networked` always holds.

The set exists so *side-agnostic* code can express schema without knowing which half the world will construct: one shared component-definitions module can define components, name them, tag them `Networked`, and register their `Serdes` hooks (which must be symmetric across sides anyway — see Serdes), and run unchanged against server and client worlds. Every entry is **inert until the half that owns it is constructed** — the tags carry no hooks before then — and each half's construction **catches up** on whatever was tagged before it, replaying pre-existing state through the same handlers the hooks run, so tagging before or after construction behaves identically. On a side that never constructs the owning half the tags simply stay inert: `Replicated` on a client world does nothing, so shared gameplay code may tag it unconditionally. Two entries are live from minting rather than from a half's construction. `Serdes` validates and stores registrations immediately — which is why it alone needs no catch-up: the store predates every possible registration, so an invalid one errors at its own call site even before either half exists. And `InheritsPrivacy` carries `pair(jecs.OnDeleteTarget, jecs.Delete)` from minting, so deleting a group deletes every entity holding a `pair(InheritsPrivacy, group)` on *any* world — including one where the delegation that pair expresses, and the guards around it, are inert.

Two consequences of the catch-up to know:

- **Misuse guards fire from the construction call for pre-existing misuses** — a paired tracking tag, `Networked` and `Replicated` on one entity, an unpaired `InheritsPrivacy`, a delegation cycle, a mixed-polarity `Private`, `NetworkedUnreliable` on a tag, a pre-construction `Imported` — with the same removal-then-error behavior a live add gets. A construction that errors this way is a programming bug surfaced at startup: nothing is memoized and the world's hook state is left partly connected, so don't catch the error and retry on the same world — fix the schema. A valueless `Private` is caught the same way but *warns* rather than erroring (see `Private`): it is rewritten to an empty filter at construction, so the entity goes on blocking everyone.
- **A `Private` filter set before construction sanitizes at construction** like any filter set: filters only carry tracked clients (see `Private` and Client Lifecycle), and no client can be tracked before construction, so every client a pre-construction filter names is pruned, with the value rewritten in place like any sanitizing set (see `Private`) — a pre-construction whitelist degrades to blocking everyone, and a pre-construction blacklist is removed outright, every client it named having been pruned. Each pruned filter **warns** from the construction call (see the prune warnings under `Private`): a populated pre-construction filter can never mean what it says, so the degradation is loud rather than silent — construct first, `add_client` the clients, then set the filters that name them. An empty filter — the common pre-construction case, marking server-only state — carries nobody to prune and works exactly as always.

### `duplecs.server(world: World) -> ServerInstance` / `duplecs.client(world: World) -> ClientInstance`

The first `server` call on a world constructs the server half: it connects the replication hooks (the tracking tags, `Replicated`, `Private`, `InheritsPrivacy`, and `jecs.Name` — per-component change tracking connects as definitions are tagged), runs the catch-up above over any schema state that predates the instance, and returns the server methods together with the server-side slice of the component set (`Networked`, `NetworkedOnce`, `NetworkedUnreliable`, `Replicated`, `Private`, `InheritsPrivacy`, `Serdes`). Tracking is live from construction, with nothing further to call before the first `generate_packets`, and every misuse guard errors at the offending call site — or from the construction call, when the catch-up finds the misuse pre-existing. The first `client` call constructs the client half: it connects the entity-mapping and name-index hooks (the latter resolve shared-name announcements) and returns the client methods plus the client-side slice (`Imported`, `Serdes`). Later calls return the same instance; construct the half matching the world's side and call the accessor from as many systems as needed.

The `world` handed to any accessor must resolve to the **same jecs instance** `duplecs` itself resolves. `duplecs` pulls jecs transitively as its own dependency, while the caller constructs the world with theirs, so a consumer whose project resolves a *different* jecs installation ends up with two separate jecs instances operating on one world. The world's first duplecs contact detects this and **warns** once per world, naming the fix (resolving the project's dependencies to a single jecs installation). Detection is identity-based — a fresh query's metatable is its creator module's exported `Query` table — so a warning always means a genuinely foreign world, never a false positive. It is a warning rather than an error because a duplicate of the *same* jecs version currently functions; treat it as a misconfiguration regardless: nothing keeps two installations' versions aligned, and once they differ, component ids, internal records, and built-ins no longer line up and behavior is undefined. Keeping the project resolved to a single jecs installation is the consumer's responsibility.

## Concepts

The API is specified in terms of the following model. One term recurs throughout: a **cell** is one component (or pair) on one entity — the unit replication tracks, filters, and ships.

### Networked vs. Replicated

Replication is gated by *two* independent eligibility checks — one on the component, one on the entity:

- **`Networked`** is added to a **component (or relation) definition entity** to mark that data of that kind is *allowed* to replicate. Marking a component networks both the unpaired component *and* every pair that uses it as the relation.
- **`Replicated`** is added to **data-holding gameplay entities** to mark that *this entity's* networked components should replicate.

A component instance only replicates when the entity carries `Replicated` **and** the component (or the pair's relation) carries `Networked`. The two roles are mutually exclusive: adding `Networked` to a `Replicated` entity (or vice versa) is rejected — the guard removes the offending tag and errors. The exclusivity is structural, not stylistic: the two roles imply contradictory client-side mappings for the same id. A networked definition must resolve on every client to that client's *own* definition entity — name-mapped (or mapped via `set_client_entity`) regardless of privacy, client-owned, never deleted — while a `Replicated` entity maps through its creation entry to a server-driven client entity, visible per client and deleted on unreplication. One id cannot carry both contracts: becoming `Replicated` withdraws a name announcement (see Shared names), which is exactly the mapping a definition needs to resolve, and entity-level privacy would gate schema — clients could receive sections referencing a component id they were never given the means to map.

A networked pair additionally requires a *replicable* target: the target entity must itself be `Replicated` or carry a `jecs.Name` (the latter covers well-known/definition entities). `duplecs` does not network any relation on its own — to replicate parent-child relationships, add `Networked` to `jecs.ChildOf` yourself (jecs built-ins are named out of the box, so it then maps automatically across sides). A pair is also never sent to a client who cannot see its target entity, so a pair cell's visibility is always a subset of its target's.

### Privacy filters and visibility

By default a `Replicated` entity and its networked components are visible to every connected client. Two optional filter layers narrow that further, both expressed through the same `Private` component:

- An **entity-level filter** — an unpaired `Private` on an entity — gates which clients the *entire* entity replicates to. It is the outer gate: a client excluded here receives nothing about the entity.
- A **per-component filter** — `pair(Private, component)` — gates a single component (and pairs using it as a relation) on that entity, inside the entity-level gate.

At either level, a `Private` filter naming no client admits none. Set **empty** (`world:set(entity, Private, {})`), it blocks every client outright — the simplest use: one set marks an entity, or a single component on it, as **private to the server**, with no membership to build or maintain. Set with a populated `Privacy` table value, it filters selectively instead, and the value chooses its polarity: all-`true` values form a **whitelist** (only the named clients are admitted), all-`false` values a **blacklist** (every client *except* the named ones is admitted). Mixing polarities in one table is an error, and an empty table always reads as a whitelist, blocking everyone.

The entity-level gate can additionally be **delegated**: `pair(InheritsPrivacy, group)` makes an entity inherit the group entity's own entity-level filter, intersected with the entity's own, so one filter edit on the group updates every delegating entity at once — a squad's shared visibility, or the part entities of a vehicle following its hull (see the `InheritsPrivacy` component). An entity may delegate to several groups at once, intersecting every inherited gate. Only the entity-level gate inherits — per-component filters always stay local to their entity.

### Server vs. Client entities

Entity ids are not shared across the network — the same gameplay entity has a different id in the server world than in a client world. `duplecs` maintains a bidirectional mapping:

- A **server entity** is an id as it exists in the server world — the ids packets carry.
- A **client entity** is the corresponding id in *this* world.

Per-entity gameplay mappings are created automatically during reconciliation as `Replicated` entities arrive. Well-known **definition entities** that exist on both sides — component and relation definitions, and unreplicated pair targets — map automatically too, as long as both sides give them the same `jecs.Name` (see Shared names below). Definitions without a name must instead be mapped once at startup via `set_client_entity`.

The two mechanisms carry different ownership semantics. A `set_client_entity` mapping does **not** claim the client entity as client-owned — a manually mapped entity is server-driven like any other server entity (its primary purpose is prediction; see the method below). Giving an entity a `jecs.Name` is what effectively claims it: a name-mapped entity belongs to the client world, and reconciliation never deletes it.

When sending a request from client to server, always translate client ids to server ids with `get_server_entity` and send those, never the client id.

### Shared names

The server **announces** the `jecs.Name` of every replication-relevant named id — a `Networked` component (or relation) definition, or a named unreplicated pair target — as `(id, name)` entries carried in packets. A newly announced name rides the next delta to every *allocated* client, and every full packet carries the whole announced set, ahead of any section that references it — so a pending joiner learns the live set from their full packet rather than from the frame's announcements. During reconciliation the client resolves each announced name against its own world's `jecs.Name` index and registers the mapping, so a definition named identically on both sides replicates with no `set_client_entity` call at all — jecs built-ins like `ChildOf` included, since they are named out of the box.

A name must be a non-empty string of at most 255 bytes — empty and over-long names warn and are not announced (a zero length on the wire means retraction, below) — and should be unique within each world; on a client-side collision the latest named entity wins the index. Resolution defers to what the client already holds: a server id already mapped *with the announced generation* is left alone (a manual `set_client_entity` always wins), while a mapping holding a different generation belongs to an older tenant of the recycled id and is superseded. An announced name with no live client match is skipped *silently*: announcements reach every client regardless of privacy, so a client legitimately lacks entities for definitions whose data never reaches it (server-only components among them). The mapping is still the caller's to establish before the id's data first arrives — announcements are one-shot and never retried, so naming the entity later does not form the mapping — and data arriving for a still-unmapped id is what warns, at reconcile (see Reconciliation). An announced name resolving to a client entity that is already mapped to a *different* server id warns and is skipped — a naming collision worth surfacing.

Announcements follow relevance. Un-networking a definition, dropping the last tracked pair to a named target, removing the name, or replicating a previously name-shared target all withdraw the announcement (a `Replicated` entity always maps through its creation entry instead, never by name), and renames re-announce. Names are schema, not data: announcements are sent to every client regardless of privacy filters.

A withdrawal reaches clients as a **retraction** — a zero-length names entry carrying the withdrawn id — and clients end the mapping the announcement established; otherwise a recycled server id could misbind against the stale mapping forever. Retractions apply only after the packet's sections, which may still reference the id (e.g. the explicit pair removals a named target's death stages). A retraction only ends a mapping that a name announcement established and that still holds the retracted generation: mappings created manually or through a creation entry never end through a retraction — including a name mapping *adopted* by a creation entry, which is how a name-shared target that becomes `Replicated` keeps its mapping wherever the entity is visible. A creation entry only adopts a name-established mapping whose generation *matches* its own — a mismatch means the mapping belongs to an older tenant of a recycled dense id, so the stale mapping is torn down (and swept, below) and a fresh client entity minted instead; manual mappings adopt regardless of generation (the prediction flow — the creation is authoritative). Either way the client entity itself, its name, and its data are untouched; only the mapping ends.

Ending a name-established mapping additionally **sweeps** the client entity's cells: every cell on an *imported* subject that references the unmapping client entity through otherwise-imported halves — a pair targeting it whose relation is imported, a pair using it as the relation whose target is imported (or is the unmapping entity itself), or an unpaired cell using it as the component — is removed, dispatching through the removed overrides exactly like a section's `removed` entries. The sweep runs at each of the three moments a mapping ends without its client entity dying — a retraction, a superseding announcement (a different generation arriving for the mapped dense id), and a creation entry tearing down a stale name mapping — and exists because a named id dying with its dense id recycled into another replication-relevant id *within one `generate_packets` interval* makes the server's explicit removals unshippable: sections name components, relations, and pair targets by dense id, which the recycle frame's announcement (or creation) rebinds before sections apply, so the server drops those removals and the client owns the cleanup. This covers named unreplicated pair targets and named *definitions* (tracked components and relations) alike. On a plain death or withdrawal with no recycle the explicit removals still ship and apply first, and the retraction-time sweep finds nothing left. The semantic consequence: *client-created* cells whose other halves are imported — a pair aimed at the named entity through an imported relation, a pair using the withdrawn definition as its relation on an imported target, or an unpaired cell of the withdrawn definition — are swept from imported subjects along with the server's cells whenever the server withdraws the name, un-networking a definition included. Cells riding client-only ids, or on client-only subjects, are never touched — and the swept state is stale by definition (the server-side id it referenced no longer exists or no longer replicates), while a `Replicated` target is already more destructive: its deletion deletes the client entity outright, removing every pair targeting it, local relations included.

`jecs.Name` is also tracked live for pair-target replicability: naming a previously unnamed (and unreplicated) target makes pairs aimed at it visible from the next packet, and removing the name removes them again. Deleting a named unreplicated target likewise replicates the removal of the pairs aimed at it — viewers receive explicit `removed` entries for those cells, since a name-mapped client entity belongs to the client world and is never deleted by reconciliation. Only the pairs pointing at the target are removed; the client entity and its name stay, while the id's mapping ends through the death's retraction once those removals have applied (the retraction's sweep, above, covers the removals a same-frame dense-id recycle keeps the server from shipping).

### Client slots and visibility

The server resolves visibility *as changes happen* rather than at packet time. Each tracked client is assigned a single-bit slot within a **shard** of 32: the first 32 clients occupy shard 1, the next 32 shard 2, and so on, with no limit on the number of shards — there is **no cap on concurrent clients**. Visibility of a given (component, entity) cell is stored as one 32-bit mask word per occupied shard, so every mask stays a single word regardless of client count. Slots are allocated lowest-first and freed slots are reused, so a stable population stays packed into the fewest shards; per-frame cost grows with the number of occupied shards that can see the changed cells.

Client slots are driven by the caller (see Client Lifecycle): `add_client` queues a joiner, whose slot is allocated and full packet built at the tail of the next `generate_packets`; `remove_client` frees a slot. Visibility math intersects every cell mask with the set of live slots, so a departed client's lingering bits are never sent to.

### Packets

A **`Packet`** is the per-client unit of replication: a single flat buffer (`data`) packing the wire format version byte, the packet frame, that client's newly unreplicated/replicated entity lists, the shared-name announcements (see Shared names), and a run of **sections**. Because entity visibility is itself per-client (the entity-level filter gates it), the unreplicated/replicated lists are computed per client: each client receives only the entities that became visible or invisible *to that client* this interval.

A section carries one component's changes for the cells that resolved to one visibility mask — set entries (ids with values), `nulled` (present but valueless), and `removed`. The values of a component with serdes hooks encode inline in the buffer; a hookless component's values travel in the packet's `values` side array instead (one value array per hookless section, in section order). Sections are encoded once per (visibility mask, component) — the mask being the cell's full cross-shard client set — and stamped into the packet buffer of every client in the mask with a single copy, shard boundaries included, so a cell visible to everyone encodes exactly one section no matter how many shards are occupied. The hookless value arrays are *shared by reference* between those clients' packets and must never be mutated downstream. Sections are independent — no cell reaches a client through more than one — so their apply order does not matter, and the same component may appear in multiple sections of one packet.

`generate_packets` returns one packet per client that has something to receive in that pass. It advances a **packet frame** (a `u32` cycling `0..2^32-1`, readable on the client through `get_packet_frame`, or as the four bytes following `data`'s leading version byte) once per call, and every packet it returns carries that same frame, so a caller sending packet parts over several channels can recombine them on the client by matching frames — or order packets across channels by comparing frames wrap-aware (see `get_chunk_frame` for the exact rule). The packet frame and the unreliable channel's chunk frame are **independent counters**: each advances only on its own generate call, so a packet frame is never comparable to a chunk frame.

### Change tracking

Once a component is `Networked` (or `NetworkedOnce`, which skips the `changed` hook entirely), `duplecs` connects `added`/`changed`/`removed` hooks that stage two kinds of change per touched (component, entity) cell:

- a **visibility change** — the cell's current client mask, recorded only when it differs from the mask last sent;
- a **value change** — the cell's new value, recorded only when the cell was visible to someone last pass (newly-visible slots read the live value during packet generation instead).

`generate_packets` drains both accumulators and turns them into per-client packets, so only cells that actually changed since the last call appear in a delta, and each change is delivered exactly once.

### Unreliable (always-replicate) values

Components whose values change every frame — positions, velocities — fit the delta model badly: every `world:set` would fire a changed hook and every change would ride the reliable stream. `NetworkedUnreliable` is the third tracking mode for exactly these: **membership stays reliable, values go unreliable**.

On the reliable path an unreliable component tracks exactly like `NetworkedOnce` — the add replicates with its initial value, removals and visibility shifts replicate, full packets carry current values, and *no changed hook is connected*, so a `world:set` costs nothing on the server. Values instead flow through a second, parallel channel: `generate_unreliable_chunks` re-reads every visible cell's current value each call and packs the values into **chunks** — self-contained buffers of at most a configurable byte budget (default 980, sized for Roblox's 1000-byte unreliable remote limit) — for the caller to send through an unreliable transport every frame.

Because every value re-sends every frame, the channel is drop- and reorder-tolerant by construction: a lost chunk costs one frame of staleness (the next frame resends everything), a stale chunk is dropped by the client's **chunk frame** counter (a `u32` every chunk of one call shares, readable through `get_chunk_frame`; independent of the reliable stream's packet frame) so values never snap backward, and a chunk that outruns the reliable packet creating its entities skips harmlessly until the mapping exists. Visibility is read from the last-*sent* masks — what each client's reliable stream currently holds — so privacy and membership changes take effect on the unreliable channel at the next `generate_packets`, the two channels always agree about what a client legitimately holds, and the two calls may run at independent cadences. Serialization is shared like the reliable path's sections: cells with equal visibility are encoded once and their chunk buffers handed by reference to every client that can see them.

Unreliable values must have serdes hooks (see Serdes) — chunking requires byte-exact sizing, so there is no side-array fallback — and tags cannot be `NetworkedUnreliable` (an always-streamed tag carries nothing).

## Components

These are minted per world at its first duplecs contact and returned as one frozen set by `duplecs.shared(world)` (see Construction). Each half's instance additionally returns the slice that is *meaningful* on its side — `Networked`, `NetworkedOnce`, `NetworkedUnreliable`, `Replicated`, `Private`, and `InheritsPrivacy` on a server instance, `Imported` on a client instance, and `Serdes` on both — the same ids as the shared set's, so use whichever is at hand: side-specific code reads them off its instance, side-agnostic code off `shared`. A tag whose owning half is not constructed on the world is inert, with the two minting-time exceptions noted under Construction (`Serdes`, and `InheritsPrivacy`'s delete policy).

### `Networked`
Tag added to a **component (or relation) definition** to mark it as eligible for replication. It networks both instances of the unpaired component and every pair using the component as the relation. A pair only replicates if its target is *replicable* — the target entity is itself `Replicated` or has a `jecs.Name`. A networked definition carrying a `jecs.Name` is announced for automatic client mapping (see Shared names). Like the other two tracking tags, it must not itself be used as a pair relation. Cannot coexist with `Replicated` on the same entity, and the three tracking tags are mutually exclusive — any of these misuses removes the newly added tag and errors.

### `NetworkedOnce`
Tag added to a **component (or relation) definition** *instead of* `Networked` to make it **replicate-once**: the component (and pairs using it as the relation) tracks and replicates exactly like a `Networked` one — initial values, removals, visibility changes, and full packets — but value `changed` events are *not* tracked (no changed hook is connected at all), for values the client is expected to simulate itself, e.g. countdown timers. Use `force_replicate` to push an unexpected change for such a component into the next packet. Exclusive with the other tracking tags (see `Networked`), and likewise cannot coexist with `Replicated`.

### `NetworkedUnreliable`
Tag added to a **component (or relation) definition** *instead of* `Networked` to make it **always-replicate** through the unreliable channel (see Unreliable values under Concepts): on the reliable path it tracks exactly like `NetworkedOnce` — membership adds with their initial value, removals, visibility changes, and full packets, with no changed hook connected — while current values are re-read and re-sent by every `generate_unreliable_chunks` call, for values that change every frame (positions, velocities). Pairs using the component as the relation stream too. The component's values must have serdes hooks assigned before chunks generate, and tags are refused — adding the tag to a tag definition removes it and errors. Exclusive with the other tracking tags (see `Networked`), and cannot coexist with `Replicated`.

### `Replicated`
Tag added to a **gameplay entity** to mark that its networked components should replicate. Adding it begins tracking every currently-eligible component and pair on the entity (and every networked pair pointing *at* the entity, since it has become a replicable target); removing it stops replication and marks the entity unreplicated for clients. Must not be used as a pair, and cannot coexist with any of the three tracking tags (the error names whichever one owns the definition's tracking); either misuse removes the offending add and errors.

### `Private`
The relation/component backing both filter layers, with two distinct uses keyed by whether its filter names anyone:

- **Empty — private to the server.** A filter naming no client admits none, so `world:set(entity, Private, {})` blocks every client outright. This is the whole mechanism for server-only state — no membership to build, no editing call to make: `world:set(entity, pair(Private, component), {})` keeps one networked component server-side on an otherwise-replicated entity (server-only bookkeeping riding on a replicated gameplay entity), and an unpaired `world:set(entity, Private, {})` keeps the whole entity dark. An empty filter still edits like a whitelist, so clients can later be admitted through `edit_entity_privacy`/`edit_component_privacy` — which is also how Privacy Editing prescribes starting a whitelist from blocking everyone.
- **Populated — a per-client filter.** Filter values are `Privacy` tables (`{ [Client]: boolean }`): all-`true` values form a whitelist admitting exactly the named clients, all-`false` values a blacklist admitting everyone except the named clients, and mixing polarities in one table errors — with the offending value reverted before the error unwinds through the triggering `world:set` (back to the entity's previous filter, or removed outright when the set was a fresh add), so the world never holds a filter that isn't in effect. Values are frozen once set — change membership through `edit_entity_privacy`/`edit_component_privacy` or by wholesale `world:set` replacement (see Privacy Editing), never by in-place mutation.

A filter is **always a table**. `Private` carrying a `nil` value — `world:add(entity, Private)`, or `world:set(entity, Private, nil)`, at either level — **warns and is rewritten to an empty filter** (in place, firing no `Private` hooks, like the sanitizing rewrites below), so it goes on blocking every client. Absence already means "no filter, visible to everyone", so a present `nil` names no third state, and the rewrite resolves it the only way a filter system safely can: toward blocking, never toward revealing. The resulting state is what the call meant; the warning is about the spelling, and about a sibling case it *cannot* catch — jecs's `add` returns early when the entity already has the component, without firing the hooks duplecs listens on, so `world:add(entity, Private)` on an entity that already carries a whitelist silently leaves that whitelist in place, admitting exactly the clients it names. Write `world:set(entity, Private, {})` and neither case arises.

Every other malformed value **errors**, reverted first like a mixed-polarity table (below): a value that is not a table at all, and a table mapping a client to anything but `true` or `false` — the latter because a truthy non-boolean would otherwise pass the polarity check and *admit* the client it names.

The component's name reads both ways: an empty cell is private *to the server*, a populated one private *to exactly the admitted clients*. Either use applies at both filter levels:

- **Per-component**: `pair(Private, component)` filters that specific component on that entity. The same pair also filters every pair using `component` as a *relation* on that entity, so one filter key gates both the unpaired component cell and its relation pairs. Absent the pair, a networked component on a replicated entity is visible to everyone the entity is.
- **Entity-level**: an unpaired `Private` set directly on an entity filters which clients the *whole* entity replicates to — the outer gate above the per-component filters. Absent it, a replicated entity is visible to every connected client.

Blacklists follow the population: a client who joins after a blacklist was set is admitted by it unless named. A blacklist blocking nobody restricts nothing, so it is removed rather than kept: allowing the last named client through `edit_entity_privacy`/`edit_component_privacy` removes the `Private` value outright, `world:set`ting a blacklist naming only departed clients removes the value the same way (from inside the triggering set, warning as a set-driven prune — see below), and `remove_client` removes it when the departing client was the last named one. An empty *table* is different — it always reads as a whitelist, blocking everyone.

Filters never outlive their clients: a filter only ever names *tracked* clients (allocated or pending — see Client Lifecycle). Both halves of that guarantee rewrite the `Private` value itself, so `world:get` always returns the filter actually in effect: `world:set`ting a filter naming untracked clients replaces the value with a pruned copy from inside the triggering set (a pre-construction filter sanitizes the same way at construction — see Construction), and `remove_client` prunes the departing client from every filter, caches and values alike, so a whitelist membership or blacklist naming does not survive a departure — a rejoining client starts unlisted. The rewrites themselves fire no `Private` hooks (no admitted client changes), and the pruned copies are frozen like every filter value.

A set-driven prune additionally **warns**, once per pruned filter set (see the two prune warnings in the appendix): naming an untracked client is an ordering bug — the client was never handed to `add_client`, already departed, or the filter predates construction — and the pruned filter fails silently otherwise, in a direction that depends on its polarity: a pruned whitelist goes on blocking the clients it meant to admit, and a blacklist pruned empty is removed outright (see above), admitting its named clients if they ever join. A pending joiner already counts as tracked, so `add_client` immediately followed by filter sets naming the joiner never warns. `remove_client`'s own departure prune is duplecs's bookkeeping rather than a caller naming an untracked client, and stays silent.

### `InheritsPrivacy`
Relation added to a **gameplay entity** as `pair(InheritsPrivacy, group)` to delegate the entity's **entity-level** visibility to `group`'s ordinary entity-level filter (its unpaired `Private`), so a single filter edit on the group updates every delegating entity. Three shapes come up constantly:

- **A shared filter for many independent entities** — a squad entity whitelisting its members once for hundreds of entities that should be visible to exactly them, instead of hundreds of parallel filters to keep in sync.
- **Objects composed of multiple entities** — a vehicle whose turret and wheels are entities of their own next to the hull. Pointing each part at the object's root (`pair(InheritsPrivacy, hull)`) makes the parts follow the root's entity-level filter automatically: hide the vehicle from a client and every part of it hides with it, with nothing per-part to remember when the filter changes — and the delete cleanup below tears the parts down with the root, completing the one-object illusion.
- **Orthogonal gates composed on one entity** — an entity may hold several `InheritsPrivacy` pairs at once, and every inherited gate intersects: a unit delegating to both its team's fog-of-war group and its region's interest group is visible only to clients both groups admit, with each membership living (and edited) in exactly one place.

The group is an ordinary world-visible entity (it does not need to be `Replicated`, or to carry a filter at all — the vehicle root above is simply also `Replicated`), inspected and edited through the same APIs as any entity, and editing the group's filter vs a member's own filter are structurally distinct operations, so a blind per-entity edit can never silently affect siblings.

The delegation **intersects** with everything else: a delegating entity's own unpaired `Private` still applies (a client must pass every gate — everything narrows), blacklists compose with whitelists across the delegation (see polarity under `Private`), and **only the entity-level gate inherits** — `pair(Private, component)` filters always stay local to their entity. With no filter anywhere among an entity's own and inherited gates it stays open to every client, and an *empty* unpaired `Private` filter on any group above it blocks every entity below.

Delegation forms a **DAG**: a group may itself delegate to wider groups, an entity may delegate to several groups, and an add that would close a cycle removes the pair and errors, as does adding `InheritsPrivacy` unpaired. The relation carries `pair(jecs.OnDeleteTarget, jecs.Delete)`: deleting a group **deletes** every entity delegating to it, recursively down the DAG — an entity is deleted when **any** group it delegates to is deleted, however many others it also inherits from — so a group deletion never silently widens anyone's visibility. When inheritors should outlive a group, manually remove their `(InheritsPrivacy, group)` pairs *before* deleting it; removing a pair re-derives the survivor's gate from its remaining filters, a pure widening. For a multi-entity object the default is the desired teardown: deleting the root deletes its parts.

### `Imported`
Tag automatically applied to any client entity that has been registered in the server↔client mapping — whether through `set_client_entity`, a creation entry, or a shared-name announcement. It is managed internally; adding it to a non-imported entity is rejected — the guard removes it and errors — as is using it as a pair relation, and its removal tears down the entity's mapping. The shared set mints it before the client half constructs, so it can technically be added earlier; no mapping can exist by then, so the construction catch-up rejects any pre-existing `Imported` with the same error.

### `Serdes`
Component set on a **component (or relation) definition entity** to register the serdes hooks (a `Serdes` value — see Types) its values encode with. Exists on both instances and in the shared set — hooks must be registered symmetrically on both sides, so the shared schema module is the natural place. A registration on a relation also covers every pair using it as the relation, and `pair(Serdes, target)` registers hooks for one concrete pair, taking precedence over the relation's own. Tags cannot carry serdes hooks (they have no values), a registration must provide `encode` and `decode` functions, and `size` must be a plain number when present; any such misuse removes the component again and errors. See Serdes below for usage.

## Packet Generation (server)

### `generate_packets() -> { [Client]: Packet }`
Builds every client's packet in a single pass and returns them keyed by client:

- **Existing (allocated) clients** receive a delta: only the cells whose visibility or value changed since the last call, bucketed into sections keyed (mask, component) — pair cells grouped one level higher, keyed (mask, relation) with each target's cells framed as a run inside the section — according to each cell's resolved cross-shard masks; clients sharing a mask have the same encoded sections stamped into their buffers, even across shards, plus that client's own lists of entities that became visible/invisible this interval.
- **Pending (newly-joined) clients** receive a full packet — every cell and entity currently visible to them — with their slot allocated at the tail of the same pass, so a joiner never receives a delta diffed against a mask it lacked.

An allocated client marked fresh via `mark_client_fresh` (see Client Lifecycle) receives a full packet *in place of* their delta. Advances the packet frame once; every returned packet shares it. **Drains** all change accumulators, so each change is delivered exactly once and `generate_packets` must be called once per replication step. A client with no changes and no entity create/delete this frame is simply omitted from the returned map — unless the frame carries shared-name announcements, which go to every allocated client. A serdes `encode` hook that fails during generation is contained: the offending values are pruned with a warning and the rest of the frame ships — see Serdes.

### `generate_unreliable_chunks(chunk_bytes: number?) -> { [Client]: { buffer } }`
Builds the always-replicate chunks (see Unreliable values under Concepts) in a single pass and returns them as one array of chunk buffers per client, for the caller to send through an unreliable transport — on Roblox, each buffer through an `UnreliableRemoteEvent`. Every visible `NetworkedUnreliable` cell's current value is re-read live and re-sent on every call, so call it once per frame (or at whatever rate the streamed values should refresh); it drains nothing and is independent of `generate_packets`, though visibility follows the last reliable packets sent — membership and privacy changes take effect on this channel after the next `generate_packets`.

`chunk_bytes` caps each returned buffer's size and must be an integer in `[19, 65535]` — both bounds are what the wire layout allows rather than round numbers: 19 bytes is the smallest budget an empty chunk can fit one cell of any section into (a pair section's header is the widest), and a chunk section's length field is a `u16`. It defaults to 980, sized for Roblox's 1000-byte unreliable remote limit with headroom for the event's own envelope. Chunk buffers are **shared by reference** between clients with equal visibility and must never be mutated. Clients with nothing visible are omitted from the returned map, and generating with no `NetworkedUnreliable` definitions returns an empty map. A serdes `encode` failure during generation is contained like `generate_packets`' — the offending values are pruned with a warning and the rest of the call's chunks ship — and values without resolvable serdes hooks, or too large to fit even an empty chunk, are dropped the same way; the always-replicate cadence re-sends (and re-reports) the dropped values each call until the hook or value is fixed — see Serdes.

## Client Lifecycle (server)

Client slots must be driven by the caller — on Roblox, typically from `Players.PlayerAdded`/`PlayerRemoving` in the same system that calls `generate_packets`. Drive both before calling `generate_packets`.

### `add_client(client: Client)`
Queues `client` as a pending joiner. The slot is allocated and the client's first (full) packet is produced at the tail of the next `generate_packets`, after that frame's delta has been resolved against the existing slots. No-op if the client is already tracked or already pending.

### `remove_client(client: Client)`
Frees the client's slot (or cancels their pending join if they leave before being allocated). Subsequent packets ignore the freed slot until a later joiner reuses it.

Either way, the departing client is pruned from every privacy filter — the caches and the `Private` component values alike, each affected value replaced with a pruned frozen copy without firing `Private` hooks (no remaining client's admission changes) — so nothing duplecs manages pins a departed client value (typically a `Player`), `world:get` keeps returning the filter in effect, and a later rejoin under the same value always starts unlisted — re-admit (or re-name) them after the rejoin if they should keep their standing. A blacklist whose last named client departs is removed from its entity outright — it restricts nobody once they are gone (see `Private`).

The prune walks the whole cached filter store, so departure cost scales with the total number of cached filters — roughly 60-80ns per filter scanned, plus, for each filter that actually names the departing client, a copy-on-write clone written back over the component's value (see `bench_remove_client`). That stays negligible at typical filter counts; the one shape to avoid is whitelists naming nearly every client on very many entities, where each departure clones them all. If that describes your filters, prefer a blacklist (admits everyone unnamed) or one `InheritsPrivacy` group filter shared by the objects.

### `is_client_tracked(client: Client) -> boolean`
Returns whether `client` is currently registered with this instance: `true` from the `add_client` call until the matching `remove_client`, **pending joiners included** — a pending client is already registered (their join is committed, and privacy filters may already name them) even though their slot, and with it every visibility query, only arrives at the tail of the next `generate_packets` (the point queries under Visibility answer `false` and the client enumerators skip them until then). A client removed while still pending reads `false` again, exactly like an allocated one, and a rejoin after either kind of departure reads `true`.

### `mark_client_fresh(client: Client)`
Declares that the client world behind an already-allocated slot is **fresh** — it has never reconciled a packet from this server world — so the next `generate_packets` returns a **full packet** for that client (every cell and entity currently visible to them, exactly what a joiner receives) *in place of* their delta. The slot itself is untouched: its privacy filters, visibility masks, and delta baseline all persist, and the full is built after that frame's delta has resolved (and contains everything the delta would have carried), so subsequent deltas continue seamlessly from it.

This exists for games that keep a slot allocated after its underlying connection goes away, preserving the slot's privacy state for whoever takes it over — e.g. a fog-of-war RTS representing clients as slot numbers, where a departed player's slot must keep exactly what it could see for a reconnecting or substituting player to resume. The flow: hand slot values (not connections) to `add_client` and the privacy filters, discard the packets generated while a slot has no connection behind it, and call `mark_client_fresh(slot)` when a new connection is assigned — then send that full packet, and every delta after it, to the new connection.

Freshness is a *precondition being declared*, not a resync knob: a full packet carries **no removals or deletes**, so a client world that has already reconciled state from this server world — one that previously followed another slot's stream, say — would keep whatever the full doesn't name (tear that world down instead of marking its slot fresh). Two more things to know. A vacant-but-allocated slot keeps costing what a live client costs — visibility staging, section resolution, and per-frame packet assembly — so don't hold slots that will never be filled again. And while a slot is vacant, `was_entity_visible`/`was_component_visible` describe what the slot's packet stream has been sent (exactly what the next occupant's deltas will diff against), not what any connected client holds.

Marking a **pending** joiner is a no-op — their join already produces a full packet — and marking an **untracked** client warns and does nothing. `remove_client` clears the mark.

## Reconciliation (client)

### `reconcile_packet(packet: Packet)`
Applies a received packet to the local world by stream-parsing its buffer. The buffer's leading wire format version byte is validated before anything else — a packet encoded by an incompatible duplecs build is refused with an error rather than misparsed, as is an unreliable chunk fed here (see `reconcile_chunk`).

Application order is fixed. Unreplicated entities are processed first (deleting their client entities), then replicated entities (creating client entities — or, for a server id pre-mapped via `set_client_entity`, silently adopting the prepared client entity: the prediction flow; a *name-established* mapping adopts only when its generation matches the creation's — see Shared names), so that recycled server ids resolve correctly. The packet's shared-name announcements are registered next (see Shared names), so freshly announced definitions resolve for the sections that follow. Then each section's set, `nulled`, and `removed` entries apply by mapping server ids to client entities, and finally any shared-name retractions apply — after the sections, whose entries may still reference the retracted id.

Sections reference entities by the dense half of their server id (the creation and names entries an id first arrives through are where the client learns its generation). A section whose component, relation, or (single-target pair) target is unmapped is skipped whole — via its length prefix when it carries inline values or grouped runs, otherwise by its counts, which size everything else — and within a grouped pair section (several targets of one relation framed as runs) an unmapped target skips just its own run. Every such skip **warns, once per id**: the server only references ids the client was given the means to map — pair cells never ship to a client that lacks the target, and mapping definitions and named targets before their data arrives is the caller's responsibility (shared names or `set_client_entity`) — so an unmapped component, relation, or run target reaching reconcile is a setup bug, and the skipped cells only re-arrive when they next change server-side. An id that later maps re-arms its warning. The unreliable path never warns — a chunk outrunning the reliable packet that maps its ids is routine (see `reconcile_chunk`).

Set entries default to `world:set`; `nulled` entries to `world:add` for tags, or `world:set` with `nil` for data components (`world:add` is a no-op when the component is already present and would leave a stale value behind); and `removed` entries to `world:remove` — unless a changed/removed override is registered for the component, in which case the override is invoked instead.

A serdes `decode` hook that throws is contained rather than unwinding the call: the offending values are skipped with a warning and everything else in the packet applies — see Serdes.

Client entity deletion follows `(OnDeleteTarget, Delete)` relations: imported dependents of a deleted entity are detached (rather than cascade-deleted) so they survive if the entity is later re-replicated, while purely-local dependents are deleted with it.

### `reconcile_chunk(chunk: buffer)`
Applies one received unreliable chunk (see Unreliable values under Concepts) to the local world. Chunks are self-contained and every value re-sends every frame, so this is drop- and reorder-tolerant by construction: a chunk older than the newest reconciled (per the chunk frame, compared wrap-aware — readable through `get_chunk_frame`) is dropped whole — the next frame resends everything, so values never snap backward — chunks of one frame apply in any order, and ids that don't resolve locally yet (a chunk outrunning the reliable packet that creates its entities) skip harmlessly. Feeding a reliable packet buffer here errors loudly, as does feeding a chunk to `reconcile_packet` — and, like the reliable path, a chunk encoded by an incompatible duplecs wire version is refused with an error.

The unreliable stream only *updates* cells — membership is authoritative on the reliable path — so with no override registered, a value (or nulled entry) applies only where the client entity currently has the component: a chunk arriving after the reliable removal of a cell can never resurrect it. A registered changed override is invoked unguarded instead (it owns application, and cannot resurrect anything), with the same relation fallback for pair sections as `reconcile_packet`; removed overrides never fire on this path, since chunks carry no removals. Receiving values for a component with no local serdes hooks errors, like the reliable path's inline values; a `decode` hook that throws is contained instead, skipping exactly its own value with a warning that re-fires each call until the hook or value is fixed (see Serdes).

### `get_packet_frame(packet: Packet) -> number`
Returns the packet frame a packet carries — the `u32` every packet of one `generate_packets` call shares (see Packets). Validates the wire format version first (erroring on a mismatch or a chunk, like `reconcile_packet`), then reads only the packet's leading fields without reconciling it, so a caller splitting a call's packets across several channels can group or dedupe them by matching frames — or order them, comparing wrap-aware exactly like chunk frames (see `get_chunk_frame` below) — before applying them with `reconcile_packet`. The packet frame is independent of the chunk frame: the two counters advance on their own generate calls and are never comparable to each other.

### `get_chunk_frame(chunk: buffer) -> number`
The chunk-side counterpart to `get_packet_frame`: returns the chunk frame a chunk carries — the `u32` every chunk of one `generate_unreliable_chunks` call shares, and the counter `reconcile_chunk`'s staleness gate compares — without reconciling the chunk. Validates the version byte first (erroring on a reliable packet or a chunk from an incompatible wire version, like `reconcile_chunk`), then reads only the chunk's header.

It exists so values captured through changed overrides can be timestamped — an interpolation or snapshot buffer receiving a position stream needs to order what it captures, and the overrides themselves are not handed the frame. `reconcile_chunk` is synchronous, so the pattern is: read the frame, store it where the overrides can see it (an upvalue), then reconcile — every value the chunk applies is captured under that frame. A stale chunk is dropped whole before any override fires, so a stored frame never stamps values older than ones already captured.

The counter wraps (it cycles `0..2^32-1`), so callers ordering frames themselves must compare wrap-aware, the way the staleness gate does: frame `b` is newer than frame `a` exactly when `(b - a) % 2^32` lies in `[1, 2^31)` — zero means the same call's chunks, and anything at or past `2^31` means `b` is older. A plain `b > a` misorders every pair that straddles the wrap.

## Entity Mapping (client)

### `set_client_entity(server_entity: number, client_entity: Entity)`
Registers a mapping between a server id and a client entity and tags the client entity `Imported`. Its primary purpose is **prediction**: a client acting ahead of replication creates a local stand-in entity immediately, learns the entity's server id through whatever side channel the caller runs (typically the triggering request, which carries the stand-in's id as a token the server echoes back beside the authoritative entity's), and maps the two, so the server's creation and data land on the prepared entity instead of a fresh one. It also covers startup mapping of well-known definitions that automatic shared-name mapping doesn't reach — definitions without a `jecs.Name`, or whose names differ across sides (a manual mapping always wins over a name announcement carrying the same generation). Mapping an id does **not** claim the client entity as client-owned: a mapped entity is server-driven like any other server entity — unreplication deletes it — unlike a `jecs.Name` shared definition, which the client world owns. Errors if the server id is already mapped to a live client entity — which includes the entity's creation beating the side channel and arriving first, so a predicting caller should check `get_client_entity` before mapping, and on losing that race adopt the server's entity and discard the now-duplicate stand-in.

Mappings key by the server id's dense (index) half, matching what sections carry on the wire. A mapping made with a stale generation therefore binds the dense id's *next tenant* instead of never matching; when the server's creation arrives and adopts the mapping, the stored generation is refreshed from it, so `get_server_entity` always returns the generation the server last taught. A manual mapping is never ended by a shared-name retraction, but a name announcement arriving for the same dense id with a *different* generation supersedes it (see Shared names).

### `get_client_entity(server_entity: number) -> Entity?`
Returns the client entity mapped to a server id, or `nil` if unmapped. The lookup resolves through the id's dense (index) half — all a wire id carries — but the full gen-qualified id you pass must match the generation the mapping was established with: a stale generation names an older or newer tenant of the same server slot, not the entity you asked for, so it resolves to `nil` rather than returning the slot's current (different) mapping. Pass the full gen-qualified id — as returned by `get_server_entity` or learned from a creation or names entry — for a round-trip to match exactly.

### `get_server_entity(client_entity: Entity) -> number?`
Returns the server id for a client entity, or `nil` if it has no mapping. This is the id a client must send to the server when referencing an entity in a request — always the full gen-qualified id, as learned from the entity's creation or names entry (or as handed to `set_client_entity`), even though sections on the wire carry only dense halves.

## Visibility (server)

### `is_entity_visible(entity: Entity, client: Client) -> boolean`
Returns whether the entity's existence is currently visible to a given client — i.e. whether the client has (or is about to have) the entity replicated to it. An untracked client (no allocated slot) always returns `false`; otherwise it tests the client's bit against the entity's current existence mask (staged this frame if touched, else last-sent), which already reflects entity replication and the entity-level privacy filter. Component visibility is always a subset of this, so a `false` result implies `is_component_visible` is `false` for every component on the entity.

### `is_component_visible(entity: Entity, component: Id, client: Client) -> boolean`
Returns whether a given component (or pair) on a given entity is currently visible to a given client. An untracked client (no allocated slot) always returns `false`; otherwise it tests the client's bit against the cell's current mask — the mask staged this frame if the cell was touched, else the last-sent mask — which already reflects entity replication, the entity-level and per-component privacy filters, pair-target visibility, and the `Networked` eligibility check applied at staging time. Exposed so callers can gate side-channel replication (e.g. events sent outside the packet stream) by the same rules `generate_packets` uses.

### `was_entity_visible(entity: Entity, client: Client) -> boolean`
The last-sent counterpart to `is_entity_visible`: returns whether the entity's existence was visible to the client as of the most recent `generate_packets`, ignoring any change staged this frame. An untracked client always returns `false`. Use this to reason about what the client actually holds right now — before the next `generate_packets` flushes the staged delta — rather than what it is about to receive.

### `was_component_visible(entity: Entity, component: Id, client: Client) -> boolean`
The last-sent counterpart to `is_component_visible`: returns whether the component (or pair) on the entity was visible to the client as of the most recent `generate_packets`, tested against only the last-sent mask and ignoring any change staged this frame. An untracked client always returns `false`. As with the current-mask pair, `was_entity_visible` returning `false` implies this is `false` for every component on the entity.

### `get_clients_seeing(entity: Entity) -> () -> Client?`
Returns an iterator over the clients the entity's existence is currently visible to — exactly the clients for whom `is_entity_visible(entity, client)` returns `true`, read straight off the per-shard visibility words (each occupied shard costs one mask lookup and the set bits resolve directly to clients) rather than probing every tracked client. Use it as a plain for-in iterator:

```lua
for client in server.get_clients_seeing(source) do
    sightRemote:FireClient(client, ...)
end
```

It exists for sight-gated side channels — sending an event to exactly the clients who can currently see the source entity, the enumeration counterpart to gating a single send with `is_entity_visible` — and for debugging privacy setups. Three caveats. Enumeration order is slot order, an internal detail: treat it as unspecified and not stable across departures. Pending joiners never enumerate — they have no slot until their join resolves, and they see nothing until their full packet. And the visibility words are read live as the iteration advances, so stage visibility changes (privacy edits, `Replicated` changes, `remove_client`) only after the loop finishes — or collect the clients into a table first. An entity that is not replicated (or not visible to anyone) yields nothing.

### `get_clients_last_seeing(entity: Entity) -> () -> Client?`
The last-sent counterpart to `get_clients_seeing`, mirroring `was_entity_visible`: iterates the clients whose bit is set in the entity's last-sent existence mask — the clients that actually hold the entity right now, before the next `generate_packets` flushes the staged delta — ignoring any change staged this frame. Same caveats as `get_clients_seeing`; a client removed since the last `generate_packets` never enumerates (their slot's lingering bits are ignored, as everywhere else).

## Forced Replication (server)

### `force_replicate(entity: Entity, component: Id)`
Stages the component's current value so it is included in the next `generate_packets`, respecting per-client visibility. Intended for `NetworkedOnce` components whose continuous changes are otherwise not tracked, allowing systems to push an occasional authoritative update. A no-op if the entity lacks the component — removals always replicate through normal tracking, so there is nothing to force.

## Privacy Editing (server)

Filter values are frozen by the module as they are added or changed, so they cannot be mutated in place (out-of-band mutation errors loudly, and callers may safely snapshot filter tables by reference). Membership is changed either through the editing API below or by replacing the whole value with `world:set`.

Both paths update the affected filter's cached visibility mask and restage the visibility of every cell that filter governs — for a per-component filter, the unpaired component cell and every pair using the key as a relation; for an entity-level filter, the entity's existence, its own cells, and pairs targeting it, plus every `InheritsPrivacy` descendant whose inherited gate actually changed (an unchanged member prunes its whole branch, so an edit already subsumed by the rest of the chain costs only the word comparison). The per-cell visibility diff inside `generate_packets` then turns each mask change into the right per-client traffic on its own: a client newly admitted receives the cell's current value (or the entity's creation), and a client newly excluded receives a removal (or the entity's deletion). There is no separate corrections path; the same visibility-diff machinery that handles ordinary changes handles filter edits.

### `edit_entity_privacy(entity: Entity, client: Client, allowed: boolean)`
### `edit_component_privacy(entity: Entity, component: Component, client: Client, allowed: boolean)`
Edit one client's standing in a filter on `entity` via copy-on-write (clone → mutate → freeze → `world:set`). `edit_entity_privacy` edits the entity-level (unpaired `Private`) filter; `edit_component_privacy` edits the `pair(Private, component)` filter for that component (or relation, gating that relation's pairs on the entity). Either direction is a no-op if `client` is already in the requested state. Edits preserve the filter's polarity — a whitelist can never become a blacklist through this API, nor vice versa:
- On a **whitelist**, `allowed = true` adds the client and `false` removes them. A whitelist emptied this way keeps blocking everyone.
- On a **blacklist**, `allowed = false` names the client and `true` un-names them. Allowing the last named client removes the `Private` value from the entity outright — a blacklist blocking nobody restricts nothing.
- With **no filter configured**, `allowed = false` starts a blacklist naming just `client` (the starting point is unambiguous: no filter admits everyone). `allowed = true` warns and does nothing — admission needs an existing whitelist; `world:set` an empty `Private`/`pair(Private, key)` filter to start from blocking everyone, or set a populated table.

## Overrides (client)

Overrides let the client replace the default reconciliation behavior for a specific component, instead of the built-in `world:set`/`world:add`/`world:remove`. A pair whose target is the wildcard is normalized to its relation, so an override may be registered per-relation: during reconciliation a concrete pair without an override of its own falls back to its relation's. The getters return only what was registered for the exact (normalized) key, never the relation fallback. Typical uses include client-side prediction (ignoring server changes for entities awaiting corrections) and components whose values embed entity ids (translating server ids inside the payload into client ids).

### `set_changed_override<T>(component: Id<T>, on_changed: ChangedOverride<T>?)`
Registers (or clears, when `nil`) the handler invoked during reconciliation for the component's set and `nulled` entries. The handler receives `(entity, value)`; `value` is `nil` for `nulled` entries.

### `set_removed_override(component: Id, on_removed: RemovedOverride?)`
Registers (or clears, when `nil`) the handler invoked during reconciliation for the component's `removed` entries. The handler receives `(entity)`.

### `get_changed_override<T>(component: Id<T>) -> ChangedOverride<T>?`
Returns the currently registered changed override for the component, or `nil`. Useful for caching and wrapping an existing override.

### `get_removed_override(component: Id) -> RemovedOverride?`
Returns the currently registered removed override for the component, or `nil`.

## Serdes (server & client)

Serdes hooks give a component's values a byte encoding so they pack inline into the packet buffer. A component without hooks still replicates — its values travel out-of-band in the packet's `values` side array — so hooks are how a caller moves a component's values onto the wire buffer itself. The one exception is `NetworkedUnreliable` components: their values must have hooks (chunking requires byte-exact sizing, so there is no side-array fallback). Generating chunks for a visible value whose hooks don't resolve drops that value with a warning rather than erroring (see the containment rules below), while *reconciling* a chunk that carries values for a component with no local hooks errors — the receiver has no way to size what it was handed.

Hooks are registered by setting the `Serdes` component on the component definition entity itself; `world:remove` clears a registration and `world:get` reads it back. Registration tables are frozen as they are set (like `Private` values), so they cannot be mutated in place. A registration must provide `encode` and `decode` functions, and its `size` must be a plain number when present; anything else removes the `Serdes` component again and errors.

The hooks match the one-buffer-per-value signatures third-party serdes libraries expose, at the cost of a per-value buffer allocation on both sides:

```lua
world:set(Loadout, net.Serdes, {
    encode = function(value) return SomeLib.serialize(value) end,
    decode = function(data) return SomeLib.deserialize(data) end,
})
```

`encode` returns a buffer holding exactly one value's bytes, and `decode` receives one such buffer (always freshly created, never a view into the packet). There is no size call and no double serialization — `encode` runs once per sent value at packet generation and the encoded bytes are copied into the packet behind a `u16` length prefix, so a value encoding to 2^16 bytes or more is refused at generation (pruned with a warning — see the containment rules below). Values addressed to entities the client cannot map are skipped by hopping the prefix, without decoding.

`size` optionally declares a static byte length every value encodes to, omitting the per-value prefix entirely — declare it whenever the encoding is fixed-width (e.g. `size = 8` for an `f64`). Sizing then multiplies by it without encoding anything where possible, and every value must encode to exactly that many bytes (a mismatch is refused at generation, like the prefix limit).

A registration on a relation covers every pair using it as the relation; `world:set(relation, pair(net.Serdes, target), hooks)` registers hooks for one concrete pair, which take precedence over the relation's own. Tags cannot carry serdes hooks (they have no values); assigning one removes the `Serdes` component again and errors. Registrations follow their ids' lifetimes — deleting the definition entity (or a concrete pair's target) clears them.

Hooks must be assigned symmetrically on the server and the client before any packets flow — receiving inline values for a component with no local hooks errors during reconciliation. Both sides must also agree on whether a static `size` is declared (the prefix is part of the value stream's encoding, so a declared `size` changes the framing).

`encode` hooks should never throw — but a throw is contained, not catastrophic. `generate_packets` (joiner full packets included) prunes exactly the values whose `encode` threw, returned a non-buffer, or violated its size contract (the static-size and prefix-limit refusals above) from that frame's sections, warns naming the component and the first error, and ships everything else — surviving values, removals, `nulled` entries, and entity creates/deletes — unchanged. A pruned value simply never reaches clients: the server still counts the cell as sent, so it replicates again when a change is next staged for it (for `Networked` components the next `world:set`; a `NetworkedOnce` component's reliable stream stages no changes, so push it with `force_replicate` once the hook is fixed). Because the containment re-encodes a failed section's surviving values, `encode` can run more than once per value on such frames — hooks must be pure. `generate_unreliable_chunks` contains the same failures the same way — one warning per affected visibility group naming the component and the first error — plus two of its own: a visible value with no resolvable serdes hooks, and a value too large to fit even an empty chunk (both previously errors that failed the whole call). Its pruned values need no re-staging: every value re-sends each call, so they simply return — and fail, and warn — every call until the hook or value is fixed, and the channel resumes whole on its own.

`decode` hooks are contained on the client the same way, and for the same reason. Every inline value's length precedes its bytes (the `u16` prefix, or the declared static `size`), so a throwing `decode` skips exactly its own value without losing stream alignment: the rest of the packet (or chunk) — the list's surviving values, `nulled`/`removed` entries, entity creates/deletes, names, and every other section — applies unchanged, with one warning per affected list naming the component and the first error. Both entry points contain it. A value skipped by `reconcile_packet` leaves its cell holding whatever it held before, and does not arrive again until the server next sends it (its next staged change, or a full packet). A value skipped by `reconcile_chunk` is stale for one frame, since every unreliable value re-sends every call — so that warning re-fires each call until the hook or value is fixed, exactly like the encode side's. The containment is a correctness requirement, not a convenience: unwinding mid-reconcile would leave the world partially applied with no safe way to finish, since changed/removed overrides are not idempotent and deltas are exactly-once. Unlike `encode`, `decode` is never re-run — the receive side has no re-encoding pass — so it sees each received value exactly once.

## Diagnostics (server & client)

Every warning and error message duplecs emits carries the `[duplecs] ` prefix, so callers can grep their output for the module's diagnostics, and every one of them is listed with its condition in the Warnings and Errors appendix at the end of this document. Ids embedded in messages follow one convention: `$` prefixes an id verified alive in the instance's world at message time, `?` one that could not be verified — a dead id, or an id from a namespace the emitting world cannot check (wire and server ids). A pair id decomposes into its halves as `pair(relation, target)` — gen-qualified live halves where the world resolves them, dense halves behind `?` otherwise — instead of printing as one packed number.

### `set_warn_hook(hook: ((message: string) -> ())?)`
Exists on both instances. Replaces the sink the instance's *warnings* emit through — the global `warn` by default — or restores the global when `nil`. The hook receives exactly the string the global would have printed, prefix included, and applies only to this instance's warnings: errors always raise regardless of the hook, and other instances (the other half included) are unaffected. It exists for test harnesses asserting that a warning actually fired (or that a silent path stayed silent) and for routing warnings into telemetry. Note the world's first duplecs contact can warn (the foreign-jecs-instance check) before any instance — and so any hook — can exist; that warning always goes to the global `warn`.

## Debug Introspection (server)

### `_client_shard(client: Client) -> number?`
Returns the 1-based shard an allocated client currently occupies, or `nil` for a pending or untracked client. Shard placement is otherwise invisible — sections are shared across shards and compaction moves are pure server-side bookkeeping — so this exists for tests and diagnostics (it is what the verification suite uses to observe the compaction schedule). Underscore-prefixed because placement is an internal detail with no stability guarantee: do not build gameplay logic on it.

## Types

All public types are exported from the module root (`duplecs/init.luau`), regardless of which half defines them. jecs's own types are deliberately not among them — every consumer requires jecs anyway (the world and the component definitions are theirs to create), so take them from there. The `World`, `Entity`, `Component`, and `Id` names in this document's signatures are plain jecs aliases, interchangeable without type errors when `T` matches or is `any`: `World` is `jecs.World`, `Entity` is `jecs.Entity<nil>` (an entity id with no associated data), `Component<T>` is `jecs.Entity<T>` (an entity used as a component), and `Id<T>` is `jecs.Id<T>` (an id that might be a pair; pairs are not entities and cannot themselves hold components). `Client` is signature notation the same way rather than an export: a client is whatever value the caller registers (typically a `Player`), so `Client` stands for plain `any` — an alias would check nothing, and callers who want a name for their client values have their actual type.

### `ServerInstance` & `ClientInstance`
The types of the instances `duplecs.server` and `duplecs.client` return (see Construction). Direct accessor calls already carry them through inference; the exports exist for the annotations inference cannot reach — a typed field holding an instance, or a parameter at a module boundary.

### `Components`
The full per-world component set `duplecs.shared` returns (see Construction): `Networked`, `NetworkedOnce`, `NetworkedUnreliable`, `Replicated`, `Private`, `InheritsPrivacy`, `Serdes`, and `Imported`. One frozen table per world, shared by all three accessors.

### `Privacy`
`{ [Client]: boolean }` — the value type for both per-component and entity-level filters. All-`true` values form a whitelist, all-`false` values a blacklist; mixed values error, and an empty table reads as a whitelist blocking everyone.

### `Packet`
```lua
{
    data: buffer;           -- the wire-ready packet: version byte, packet frame, entity create/delete lists, name entries, and sections
    values: { { any } }?;   -- hookless sections' value arrays in section order; shared by reference between clients — never mutate
}
```
The buffer layouts are documented in `duplecs/wire.luau`; callers normally treat `data` as opaque, except its packet frame (read through the client's `get_packet_frame`). `values` holds one array per section carrying hookless values (a grouped pair section's array concatenates its runs' values in run order).

### `Serdes<T = any>`
```lua
{
    size: number?;                 -- optional static byte length every value encodes to; omits the per-value length prefix
    encode: (value: T) -> buffer;  -- one value's bytes as a fresh buffer
    decode: (buf: buffer) -> T;    -- decodes a buffer holding exactly one value's bytes
}
```
The value type of the `Serdes` component (see Serdes above). Values passed to the hooks are never `nil` — nulled cells travel in their own list.

### `ChangedOverride<T = any>`
`(Entity, T) -> ()` — signature of a changed override handler. `nulled` entries invoke the handler with no value, so when nulls are possible for the component (a tag, or a data component set to `nil`) declaring `T` nillable is the caller's responsibility.

### `RemovedOverride`
`(Entity) -> ()` — signature of a removed override handler.

## Appendix: Warnings and Errors

Every warning and error `duplecs` emits is listed below, grouped by the surface that raises it — so a message a caller reads has exactly one entry to look up, and so the documented set stays checkable against the sources themselves. The verification suite reads this appendix and diffs it against the module's own `warn(` / `fail(` calls in both directions: a diagnostic added, reworded, or removed without the matching edit here fails the suite. Each entry quotes the message as it prints, with `<...>` standing in for the interpolated parts, and states the condition behind it. What *happens* around a diagnostic — what is undone, contained, or refused — belongs to the section that owns the feature, which each entry points at; this is the index, not a second specification.

Two rules hold throughout. An **error** marks a programming bug — a misuse of the API, or a mismatch between the two sides' builds — and unwinds through the call that committed it, with any partial effect undone first (a refused tag removed, a refused filter value reverted), so the world is never left holding state the module is not honoring. A **warning** marks something the module absorbed and kept going through: a dropped value, a skipped section, a no-op call. Warnings ride the emitting instance's warn sink, so `set_warn_hook` captures them; errors always raise regardless. Every message carries the `[duplecs] ` prefix, and ids embedded in one render under the `$` / `?` convention (see Diagnostics).

### Construction

- **warns** `the world was created by a different jecs instance than the one duplecs requires! replication will misbehave if the two versions ever differ; resolve the game's and duplecs's jecs dependencies to a single installation.` — the world passed to `duplecs.shared` / `duplecs.server` / `duplecs.client` resolves a different jecs installation than `duplecs` itself does, detected once per world at its first duplecs contact (see Construction). This warning predates every instance, so it always goes to the global `warn` regardless of hooks installed later.
- **errors** `the internal entity holding this world's duplecs state was deleted!` — an accessor was called on a world whose internal record entity — minted at the world's first duplecs contact and never exposed — has since been deleted. The world's component set, serdes store, and both halves' memoized instances went with it; nothing is recoverable.

### Schema guards

Each guard below fires from the `world:add` / `world:set` that commits the misuse — or, for schema that predates the owning half, from the `duplecs.server(world)` / `duplecs.client(world)` call whose catch-up finds it (see Construction) — and undoes the offending add before erroring. Three guards warn instead of erroring: a valueless `Private` is rewritten rather than refused, leaving exactly the state the call meant, and a filter naming untracked clients is honored in pruned form — salvageable state either way, so it is absorbed rather than raised, loudly where the result is not what the call named.

- **errors** `<tag> is not meant to be paired! (<id>)` — one of the three tracking tags was added as a pair relation; `<tag>` names which of `Networked`, `NetworkedOnce`, and `NetworkedUnreliable` it was, and `<id>` the entity that received the pair.
- **errors** `Networked, NetworkedOnce, and NetworkedUnreliable are exclusive! (<id>)` — a definition already carrying one tracking tag was given another (see `Networked`).
- **errors** `cannot add <tag> to replicated entities!` — a tracking tag was added to an entity carrying `Replicated`; the two roles imply contradictory client-side mappings for one id (see Networked vs. Replicated).
- **errors** `<tag> components cannot be replicated!` — the same exclusivity from the other direction: `Replicated` was added to a definition that already tracks, with `<tag>` naming whichever of the three tags owns that tracking.
- **errors** `NetworkedUnreliable cannot be added to tags! (<id>)` — the always-replicate mode was applied to a tag definition, which carries no value to stream (see `NetworkedUnreliable`).
- **errors** `Replicated is not meant to be paired! (<id>)` — `Replicated` was added as a pair relation.
- **errors** `InheritsPrivacy must be paired with a group entity! (<id>)` — `InheritsPrivacy` was added unpaired; delegation names its group through the pair (`pair(InheritsPrivacy, group)`).
- **errors** `InheritsPrivacy delegation cannot contain cycles! (<entity> -> <group>)` — the added edge would close a cycle in the delegation DAG (see `InheritsPrivacy`).
- **errors** `privacy filters cannot mix allowed (true) and disallowed (false) clients!` — a `Private` value carried both `true` and `false` entries.
- **errors** `privacy filters must be tables keyed by client! (got a <type>)` — a `Private` value was not a table at all.
- **errors** `privacy filters must map each client to true (allowed) or false (disallowed)! (got a <type>)` — a `Private` table mapped a client to something other than a boolean. Refused rather than coerced: a truthy non-boolean would pass the polarity check and *admit* the client it names.
- **warns** `Private filters cannot have a nil value! it now blocks every client, as an empty filter -- set one explicitly, since world:add leaves an existing filter untouched instead. (<id>)` — `Private` (unpaired or paired) was added with no value, or set to `nil`, on `<id>`. The value is rewritten to an empty filter, so it goes on blocking everyone; the spelling is what the warning is about, plus the `world:add` case duplecs cannot see (see `Private`).
- **warns** `a Private filter named <n> untracked client(s)! they were pruned from it, since filters only carry tracked clients -- register clients through add_client before a filter names them; no client can be tracked before duplecs.server(world) constructs. (<id>)` — a filter set through `world:set` — or replayed by the construction catch-up — named clients this instance does not track (departed, or never added), and the value was replaced with the pruned copy (see `Private`). Once per pruned filter set; the failure is otherwise silent, and a pruned whitelist goes on blocking the clients it meant to admit — from before construction, every client it named.
- **warns** `a Private blacklist named only untracked clients! it was removed outright, since it restricted nobody -- register clients through add_client before a filter names them; no client can be tracked before duplecs.server(world) constructs. (<id>)` — the blacklist shape of the same prune: no named client survived sanitization, so the value was removed outright and the cell is unrestricted — the named clients will be admitted if they later join (see `Private`). `remove_client`'s own departure prune never raises either warning — it is duplecs's bookkeeping, not a caller naming an untracked client.

The three errors above are reverted from inside the triggering `world:set` — to the entity's previous filter, or removed outright when the set was a fresh add — before the error unwinds, so the world never holds a filter the module is not honoring (see `Private`).
- **errors** `serdes hooks cannot be assigned to tags! (<id>)` — `Serdes` was set on a definition (or concrete pair) with no values to encode.
- **errors** `serdes registrations must provide encode and decode hooks! (<id>)` — a `Serdes` value was missing `encode`, `decode`, or both.
- **errors** `serdes size must be a static byte length (a plain number) when present! (<id>)` — a `Serdes` value carried a `size` that was not a number (see Serdes).
- **errors** `Imported is not meant to be paired! (<id>)` — `Imported` was added as a pair relation.
- **errors** `Imported cannot be added to entities with no server mapping! (<id>)` — `Imported` was added by hand to a client entity holding no server mapping; the tag is managed internally (see `Imported`).

### Shared names (server)

Both fire from whatever made the name announcement-relevant — a `world:set(entity, jecs.Name, ...)`, a tracking tag's add, the first tracked pair aimed at the entity, or the construction catch-up — and leave the id unannounced; a later valid rename announces it after all (see Shared names).

- **warns** `shared names must not be empty! (<id>)` — an empty name cannot be announced: a zero length on the wire is a retraction.
- **warns** `shared names must be at most 255 bytes! (<id>)` — the wire's name length field is a `u8`.

### Packet generation (server)

- **warns** `a serdes encode hook threw while encoding <id>! <n> value(s) were dropped from this frame's packets and will not replicate until their cells next change: <error>` — from `generate_packets`, joiner and fresh-client full packets included: a section's `encode` hook threw or broke its contract, so exactly the offending values were pruned and everything else in the frame shipped. One warning per affected section, carrying the first error (see Serdes).
- **warns** `a serdes encode failed while chunking <id>! <n> value(s) were dropped from this call's chunks and will not replicate until the hook or value is fixed: <error>` — the same containment in `generate_unreliable_chunks`, one warning per affected visibility group, and covering two failures of its own besides a throwing hook (unresolvable hooks, and a value no chunk could fit). Every unreliable value re-sends each call, so the dropped values return — and re-report — every call until the hook or value is fixed.
- **errors** `chunk_bytes must be an integer between <min> and <max>! (got <value>)` — `generate_unreliable_chunks` was given a non-integer or out-of-range chunk budget; the bounds are `[19, 65535]`, both derived from the wire layout (see the method).
- **errors** `an unreliable section does not fit an empty chunk! (<id>, budget <budget>)` — an invariant, not a reachable misuse: an empty chunk of the call's budget could hold no cell of the section at all. Oversized *values* never reach it (they are bounded against the same budget before anything packs, and pruned with the containment warning above), and the `chunk_bytes` floor above rules out a budget too small for a section header plus one id, so this can only fire if the wire layout and that floor ever disagree.

### Client lifecycle and privacy editing (server)

- **warns** `cannot mark an untracked client fresh!` — `mark_client_fresh` was passed a client this instance does not track, and nothing happened. Marking a *pending* joiner is a silent no-op instead: their join already produces a full packet (see `mark_client_fresh`).
- **warns** `cannot allow a client without a whitelist to add them to! set the whitelist first.` — `edit_entity_privacy` / `edit_component_privacy` was called with `allowed = true` where no filter is configured, and nothing happened: admission needs an existing whitelist (see Privacy Editing).

### Reconciliation (client)

- **warns** `a received section's <role> (server <id>) has no client mapping! its cells were skipped -- map the id before the server first references it: give the matching client entity the shared jecs.Name, or map it with set_client_entity at startup` — `reconcile_packet` skipped a section, or one run of a grouped pair section, whose id does not resolve locally; `<role>` is `component`, `relation`, or `pair target`. Once per id while it stays unmapped, re-armed if the id later maps. The unreliable path never warns (see `reconcile_chunk`).
- **warns** `shared name "<name>" resolves to a client entity already mapped to server entity <id>!` — an announced name resolved to a client entity already bound to a *different* server id, so the announcement was skipped: a naming collision in the client world (see Shared names).
- **warns** `a serdes decode hook threw while decoding <id>! <n> value(s) were skipped and their cells will not update until they next change server-side: <error>` — `reconcile_packet` contained a throwing `decode`: exactly those values were skipped and the rest of the packet applied. One warning per affected list, carrying the first error (see Serdes).
- **warns** `a serdes decode hook threw while decoding <id>! <n> value(s) were skipped from this chunk; they re-send next frame: <error>` — the same containment in `reconcile_chunk`; the warning re-fires every call until the hook or value is fixed, since every unreliable value re-sends.
- **errors** `received serialized values for <id> but no serdes hooks are assigned!` — `reconcile_packet` or `reconcile_chunk` met inline values for a component with no local hooks. Their length is unknowable without the hooks, so the stream cannot be walked past them; hooks must be registered symmetrically on both sides (see Serdes).
- **errors** `received a packet encoded with wire format version <n>, but this build of duplecs speaks version <m>! the sender and receiver must run compatible duplecs versions.` — from `reconcile_packet` / `get_packet_frame`, checked before any other field is read.
- **errors** `received an unreliable chunk encoded with wire format version <n>, but this build of duplecs speaks version <m>! the sender and receiver must run compatible duplecs versions.` — the chunk-side counterpart, from `reconcile_chunk` / `get_chunk_frame`.
- **errors** `received an unreliable chunk on the reliable path! unreliable chunks must be applied with reconcile_chunk.` — a chunk buffer was handed to `reconcile_packet` or `get_packet_frame`. The two buffer kinds are mutually unparseable by design: their leading version bytes differ in the high bit, so neither can be misread as the other.
- **errors** `received a reliable packet on the unreliable path! reliable packets must be applied with reconcile_packet.` — a packet's `data` was handed to `reconcile_chunk` or `get_chunk_frame`.

### Entity mapping (client)

- **errors** `server entity <id> is already mapped to a client entity!` — `set_client_entity` was called for a server id already mapped to a live client entity, which includes the entity's creation beating a prediction's side channel: check `get_client_entity` first, and on losing that race adopt the server's entity (see `set_client_entity`).

### Serdes contract failures

The checks below sit inside the encode passes and never escape one: every path that runs a user `encode` hook is guarded, so each message reaches the caller as the `<error>` tail of a containment warning above — never as an error of its own. They are listed for the same reason the warnings are: so a message a caller reads has an entry here.

- **reports** `serdes encode hooks must return a buffer! (<id> returned a <type>)` — `encode` returned something other than a buffer.
- **reports** `serdes hooks with a static size must encode exactly that size! (<id> encoded <n> bytes, size is <size>)` — a registration declaring `size` encoded a value to a different length; every value must encode to exactly that many bytes (see Serdes).
- **reports** `serdes values must encode to fewer than 2^16 bytes! (<id> encoded <n> bytes)` — a value overflowed the `u16` length prefix its bytes ride behind.
- **reports** `an unreliable value exceeds the chunk byte budget! (<id> encoded <n> bytes, limit <limit>)` — a chunk value larger than the biggest one an empty chunk of the call's budget could carry. A declared static `size` past the same limit is reported as `<id> encodes <n> bytes` instead, before any value is encoded.
- **reports** `unreliable values cannot be serialized without serdes hooks! (<id>)` — a visible `NetworkedUnreliable` cell whose hooks do not resolve. Its values drop for the call (the cell's `nulled` ids still ship), and the reliable stream, which needs no hooks, is unaffected.

### Internal decoders

`wire.luau`'s record-view decoders (`decode_packet` / `decode_chunk`) parse a packet or chunk into an allocating record of raw wire ids for the verification suite and diagnostics. They are not reachable through the module's public surface; their two diagnostics are listed only so the set above stays complete.

- **errors** `decode_section: no serdes hooks to decode the inline values of <id>` — a section's inline values cannot be sized, let alone decoded, without hooks.
- **errors** `decode_chunk: no serdes hooks to decode the values of <id>` — the chunk-side counterpart.
