# Replication Basics

How duplecs decides what ships: the two eligibility gates, the three tracking modes for component definitions, and the delta model behind `generate_packets`. Exact contracts live in the spec's [Networked vs. Replicated](../spec.md#networked-vs-replicated) and [Change tracking](../spec.md#change-tracking) sections.

## The two gates

Replication requires two independent opt-ins — one on the *kind* of data, one on the *entity* holding it:

```lua
-- server
world:add(Health, net.Networked)   -- on the component definition: this kind of data may replicate
world:add(goblin, net.Replicated)  -- on the gameplay entity: this entity's networked components replicate
```

A `Health` value on the goblin replicates; a `Health` value on an untagged entity does not, and a server-only component on the goblin does not. The gates compose with [visibility filters](005-visibility-filters.md), which narrow *which clients* an eligible component reaches.

The two roles are mutually exclusive: adding `Networked` to a `Replicated` entity (or vice versa) removes the offending tag and errors. Order is otherwise free — tagging a definition `Networked` picks up instances already sitting on `Replicated` entities, and adding `Replicated` picks up every currently-eligible component on the entity.

## What a delta carries

Once eligible, a component on an entity replicates through its whole lifecycle without further calls:

- **Adds and changes** ship the new value.
- **Removals** ship as removals: `world:remove(entity, Health)` on the server removes `Health` from the client entity in the next packet. Removing `Replicated` or deleting the entity ships the entity's disappearance instead — the client deletes its client entity whole.
- **Tags** (valueless components) and data components set to `nil` ship as *nulled* entries — the client adds the tag, or sets the data component to `nil`.

Visibility changes ride the same entries: a client newly excluded from a component — a [visibility filter](005-visibility-filters.md) tightened, a pair's target hidden — receives that component's removal, and a client newly admitted receives its current value, exactly as if it had just been removed or added server-side. The client can't distinguish "removed on the server" from "no longer visible to me", and doesn't need to: either way its world holds exactly what it is currently allowed to see, with no cleanup path of your own to write.

`generate_packets` drains everything accumulated since the last call and each change is delivered **exactly once** — call it once per replication step. One consequence worth knowing: jecs fires the changed hook even when a set writes an equal value, so a system that re-sets an unchanged value every frame ships redundant bytes. Check equality before `world:set` when that matters — or use `NetworkedUnreliable` (below) for values that genuinely change every frame.

## `NetworkedOnce`: replicate-once values

`NetworkedOnce` replaces `Networked` for values the client simulates itself. Adds, removals, visibility changes, and full packets replicate exactly like `Networked`. The difference: no changed hook is connected at all, so `world:set` on a component the entity already has costs nothing on the server and ships nothing.

```lua
-- in shared/components.luau
local RespawnAt = world:component() :: jecs.Entity<number>
world:set(RespawnAt, jecs.Name, "RespawnAt")

-- server
world:add(RespawnAt, net.NetworkedOnce)

-- ships once, when the component is added; each client counts down locally
world:set(corpse, RespawnAt, workspace:GetServerTimeNow() + 5)
```

When something unexpected changes such a value — the respawn is delayed, the timer paused — push the current value into the next packet explicitly:

```lua
-- server
world:set(corpse, RespawnAt, workspace:GetServerTimeNow() + 30)
net.force_replicate(corpse, RespawnAt)
```

`force_replicate` pushes the component's current value into the next `generate_packets`, respecting per-client visibility, and is a no-op if the entity lacks the component (removals always replicate on their own — there is nothing to force).

## `NetworkedUnreliable`: always-replicate values

The third mode is for values that change every frame (e.g. positions, velocities): membership stays on the reliable path like `NetworkedOnce`, while current values are re-read and re-sent by every `generate_unreliable_chunks` call through an unreliable transport. `world:set` costs nothing on the server, and a dropped packet costs one frame of staleness. This mode has its own setup requirements (serdes hooks, a second remote) — see [Unreliable values](009-unreliable.md).

The three tracking tags are mutually exclusive on one definition; pick per component. As a rule of thumb:

| Mode | Value changes | Fits |
| --- | --- | --- |
| `Networked` | Ship reliably, exactly once each | State that changes occasionally: health, inventory, names |
| `NetworkedOnce` | Never ship (push with `force_replicate`) | Values the client extrapolates: timers, seeds, spawn parameters |
| `NetworkedUnreliable` | Re-sent every frame, unreliably | Continuous motion: positions, velocities, aim directions |

## Relations replicate too

Every tracking tag covers pairs using the tagged definition as the relation — `world:add(ChildOf, net.Networked)` replicates parent-child relationships. Pairs bring one extra rule (the target must be replicable) and a few patterns of their own: see [Replicating relationships](003-pairs.md).

## Watching it work

Two habits pay off early. First, duplecs prefixes every warning and error with `[duplecs] `, so filter your output for it — misuse guards error at the offending call site, and setup bugs (like data arriving for an unmapped id) warn rather than failing silently. Second, the server can answer visibility questions directly — `is_component_visible(entity, component, client)` tells you whether a component on an entity currently reaches a client, applying every gate `generate_packets` applies — see [Visibility queries](007-visibility-queries.md).

## Narrowing who receives it

Everything in this guide decides what *can* replicate; by default, an eligible component reaches every connected client. [Visibility filters](005-visibility-filters.md) narrow that per client — an empty filter keeps an entity or one of its components server-only, and whitelists and blacklists admit clients selectively — with [visibility inheritance](006-visibility-inheritance.md) sharing one filter across many entities. As above, excluded clients just see removals: filtering needs no cooperation from the replication side of your code.
