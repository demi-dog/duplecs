# Visibility Filters

By default a `Replicated` entity and its networked components are visible to every connected client — a **visibility filter** narrows that.

`Private` is the component you use to assign one — a client-keyed table for whitelists or blacklists, or an empty table to mark something server-only.

Exact contracts live in the spec's [Private](../spec.md#private) and [Privacy Editing](../spec.md#privacy-editing-server) sections. For sharing one filter across many entities, see [Visibility Inheritance](006-visibility-inheritance.md).

## At a glance

```lua
-- server
local pair = jecs.pair

-- make the whole entity server-only
world:set(base, net.Private, {})

-- make one component on the entity server-only
world:set(mob, pair(net.Private, AggroTable), {})

-- make the entity visible to only one client
world:set(chest, net.Private, { [finder] = true })

-- hide the entity from exactly one client
world:set(griefer, net.Private, { [blocker] = false })
```

## Two levels, one component

`Private` applies at two levels, and the same rules hold at both:

- **Entity-level** — unpaired `Private` on an entity filters which clients the *entire* entity replicates to. A client excluded here receives nothing about the entity: no creation, no components, no pairs aimed at it.
- **Per-component** — `pair(Private, component)` filters a single component on that entity, narrowing from the entity-level filter if present. The same pair also gates every pair using that component as a *relation* on the entity.

## Server-only state: an empty filter

A filter that names nobody admits nobody, so an empty table blocks every client outright. This is the entire mechanism for server-only state — no membership to build or maintain:

```lua
-- server
world:add(mob, net.Replicated)
world:set(mob, Health, 100)

-- a networked component...
world:set(mob, AggroTable, {})

-- ...kept server-side on this entity
world:set(mob, pair(net.Private, AggroTable), {})
```

Write the empty table out — a filter is always a table. A `Private` with no value at all (`world:add(mob, net.Private)`, or a `world:set` of `nil`) still blocks everyone: duplecs warns and rewrites it to an empty filter. The warning is worth acting on anyway, because of the case duplecs *can't* see: jecs's `add` returns early when the entity already has the component, so `world:add` aimed at an entity that already carries a whitelist quietly leaves that whitelist in place — the clients it names keep seeing everything, with nothing fired for duplecs to warn about. `world:set` never has that problem.

(A component that is never `Networked` needs none of this — it never replicates anywhere. The pair matters when a component replicates on most entities but must stay dark on some, or when it should start dark and admit clients later.)

## Selective filters: whitelists and blacklists

When assigned a client-keyed table value (`{ [Client]: boolean }`), `Private` filters selectively, and the values decide which kind of list it is. Read each value as the answer to "is this client allowed to see it?", and the polarity follows from that answer:

- All-**true** — a **whitelist**: only the named clients are admitted.
- All-**false** — a **blacklist**: every client *except* the named ones is admitted. Clients who join later are admitted unless named.

```lua
-- server

-- true names who may see it: only the party sees the quest objective
world:set(objective, net.Private, { [alice] = true, [bob] = true })

-- false names who may not: everyone except the player who blocked them sees this player's nameplate
world:set(griefer, pair(net.Private, Nameplate), { [blocker] = false })
```

Mixing `true` and `false` in one table errors, as does a value that isn't a boolean at all (`{ [alice] = 1 }` would otherwise read as "admitted") or a filter that isn't a table. The offending value is reverted before the error unwinds, so the world never holds a filter that isn't in effect. An empty table always reads as a whitelist, blocking everyone.

Filter values are **frozen** when they are set: toggle membership through the editing API below, or replace the whole value with another `world:set` — never try to mutate the table directly after assigning it.

## Toggling membership

`edit_entity_privacy` and `edit_component_privacy` change one client's standing in a filter, while preserving the kind of filter it is (a whitelist can never silently become a blacklist, or vice versa):

```lua
-- server

-- a whitelist: only the party sees the objective
world:set(objective, net.Private, { [alice] = true, [bob] = true })

-- carol joins the party
net.edit_entity_privacy(objective, carol, true) -- now { alice, bob, carol }

-- bob leaves the party
net.edit_entity_privacy(objective, bob, false) -- now { alice, carol }

-- a blacklist on one component: everyone except the player who blocked them sees their messages
world:set(offender, pair(net.Private, Messages), { [blocker] = false })

-- another player blocks the offender
net.edit_component_privacy(offender, Messages, second_blocker, false) -- now hidden from both

-- the original blocker un-blocks the offender
net.edit_component_privacy(offender, Messages, blocker, true) -- now hidden from second_blocker only
```

Starting from nothing follows from what each kind of list means with no filter present (everyone admitted):

- `allowed = false` with no filter starts a **blacklist** naming just that client.
- `allowed = true` with no filter warns and does nothing — there is nothing to admit *into*. Start a whitelist from "block everyone" with an empty filter, then admit:

```lua
-- server
world:set(objective, net.Private, {})           -- block everyone
net.edit_entity_privacy(objective, alice, true) -- now a whitelist of { alice }
```

Two tidiness rules the module applies for you: a blacklist that no longer names anyone is removed outright (it restricts nobody), and a whitelist emptied by edits keeps blocking everyone (deliberately different — empty whitelist means "no one", absent filter means "everyone").

## What clients experience

There is no corrections machinery to run: filter changes flow through the same visibility diff as everything else. A client newly admitted to an entity receives its creation and current state, exactly like a joiner; a client newly excluded receives its deletion (or the component's removal, for a per-component filter). Mid-frame flips resolve to whatever the final state is when `generate_packets` runs.

Filter keys never outlive their clients: `remove_client` prunes the departing client from every cached filter, so a rejoining client always starts unlisted — re-admit them after the rejoin if they should keep their standing. (If your filters name nearly every client on very many entities, see the departure-cost note under [Client Lifecycle in the spec](../spec.md#client-lifecycle-server) — a blacklist or a shared [inherited filter](006-visibility-inheritance.md) is usually the better shape anyway.)

## Debugging a filter setup

The server answers visibility directly — `is_entity_visible(entity, client)` for the entity gate (its own filter and every inherited one), `is_component_visible(entity, component, client)` for one component on it (adding the per-component filter and pair-target visibility), and the `get_clients_seeing(entity)` iterator for the entity's whole admitted set. When a filter doesn't behave as expected, query rather than guess: see [Visibility queries](007-visibility-queries.md).
