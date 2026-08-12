# Replicating Relationships

jecs pairs — `pair(relation, target)` — replicate through the same machinery as unpaired components, with one extra rule about targets. This guide covers networking a relation, what makes a target replicable, and how pair removals behave around target deletion. Exact contracts live in the spec's [Networked vs. Replicated](../spec.md#networked-vs-replicated) and [Shared names](../spec.md#shared-names) sections.

## Networking a relation

Tagging a component (or relation) definition `Networked` networks *both* the unpaired component *and* every pair using it as the relation. duplecs networks no relation on its own — parent-child relationships included:

```lua
-- server
local pair = jecs.pair

world:add(jecs.ChildOf, net.Networked)

world:add(wheel, pair(jecs.ChildOf, vehicle))  -- replicates, target permitting (below)
```

`jecs.ChildOf` maps across sides automatically — jecs built-ins are named out of the box, and named definitions map by [shared name](004-entity-mapping.md). Your own relations follow the same pattern as any component: define them in the shared module with a `jecs.Name`, tag them `Networked` on the server.

Data pairs work too — when the relation is a data component, the pair's value replicates like any component value:

```lua
-- in shared/components.luau
local DamageOver = world:component() :: jecs.Entity<number>
world:set(DamageOver, jecs.Name, "DamageOver")

-- server
world:add(DamageOver, net.Networked)
world:set(enemy, pair(DamageOver, fire), 12)  -- 12 damage over fire, replicated
```

## Replicable targets

A networked pair replicates only when its **target is replicable** — one of:

- The target is itself **`Replicated`**. It replicates as an ordinary entity, and pairs aimed at it map through its creation entry.
- The target carries a **`jecs.Name`**. This covers well-known entities that both sides define themselves — element types, teams, definition entities — where replicating the target would be pointless. The server announces the name; the client resolves it against its own world's identically-named entity.

```lua
-- in shared/components.luau: both sides define the entity, only the name crosses the wire
local fire = world:entity()
world:set(fire, jecs.Name, "FireElement")

-- server
world:set(enemy, pair(DamageOver, fire), 12)
```

A pair with a target that is neither `Replicated` nor named simply does not replicate — no error. Target replicability is a live condition: tagging it `Replicated` later (or naming it with `jecs.Name` on both sides) makes the pairs aimed at it visible from the next packet, and removing it removes them again.

Visibility follows the target as well: a pair is never sent to a client who cannot see its target entity, so a pair's visibility is always a subset of its target's. Hiding an entity behind a [visibility filter](005-visibility-filters.md) also hides every replicated pair pointing at it.

## Target deletion

What clients receive when a pair's target dies depends on what the target was:

- **A `Replicated` target** — its deletion replicates, the client deletes the client entity, and jecs's own cleanup removes every pair aimed at it on both sides. No per-pair removals ship; the wholesale delete covers them.
- **A named, unreplicated target** — the client entity survives (a name-mapped entity belongs to the client world, and reconciliation never deletes it), so there is no wholesale delete to lean on: clients instead receive explicit removals for exactly the pairs aimed at it. The name mapping ends afterward via a retraction, so a recycled server id can never misbind against it.

On the client side, reconciliation follows `(OnDeleteTarget, Delete)` relations with one twist: when a deleted entity's dependents are *imported* (server-driven), they are detached rather than cascade-deleted — the server remains authoritative about their lifetimes and deletes them itself if that's the intent. Purely-local dependents are deleted with it.

## Choosing the target's mechanism

When a pair's target could be modeled either way, the rule of thumb: use `Replicated` for gameplay entities with replicating data of their own, and a `jecs.Name` for the fixed set of things both sides already know at startup. Named targets cost one announcement — a name describes the setup rather than gameplay state, so it is sent to every client regardless of privacy. Replicated targets cost an entity's full replication. Keep names unique per world, non-empty, and at most 255 bytes — invalid names warn and are not announced.

If a named target must be created *dynamically* on the client after packets are already flowing, establish the name before any pair data referencing it arrives — announcements are one-shot, and data arriving for a still-unmapped id warns and is skipped until it next changes server-side. The safe pattern is names at startup; see [Entities across the network](004-entity-mapping.md) for the full mapping rules.
