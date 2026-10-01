# Visibility Inheritance

Many entities can share one entity-level [visibility filter](005-visibility-filters.md), and `InheritsPrivacy` is the component that points them at it: `pair(InheritsPrivacy, group)` makes an entity inherit `group`'s unpaired `Private` filter on top of its own — a client must pass both — so a single filter edit on the group updates every entity inheriting from it at once. Inheritance chains, too: a group may itself inherit from wider groups, so one edit near the top of a hierarchy reaches everything below it. When the group is also the entity's container, `InheritsPrivacyThrough` lets the entity inherit through a relationship it already has — `jecs.ChildOf`, say — so there is no second pair to keep in step. And a group can hand its inheritors *less* than it sees itself, with `ExportsPrivacy`. Exact contracts live in the spec's [`InheritsPrivacy`](../spec.md#inheritsprivacy), [`InheritsPrivacyThrough`](../spec.md#inheritsprivacythrough), and [`ExportsPrivacy`](../spec.md#exportsprivacy) sections.

## Multi-entity objects

The simplest shape: an object composed of several entities — a vehicle whose turret and wheels are entities of their own next to the hull. Point each part at the object's root and the parts follow the root's visibility automatically:

```lua
-- server
local pair = jecs.pair

local hull = world:entity()
world:add(hull, net.Replicated)

local turret = world:entity()
world:add(turret, pair(net.InheritsPrivacy, hull))
world:add(turret, net.Replicated)

for i = 1, 4 do
	local wheel = world:entity()
	world:add(wheel, pair(net.InheritsPrivacy, hull))
	world:add(wheel, net.Replicated)
end

-- hide the vehicle from everyone but its driver: the turret and all four wheels hide with it
world:set(hull, net.Private, { [driver] = true })

-- and teardown completes the one-object illusion (see Deletion below)
world:delete(hull)
```

One edit on the hull moved six entities — nothing per-part to remember when the filter changes, and no way for a part to drift out of sync with its object.

## A shared filter for many entities

The same mechanism scales from one object to whole populations: a squad whose hundreds of units should be visible to exactly its members. Without inheritance that is hundreds of parallel whitelists to keep in sync; with it, the membership lives in exactly one place:

```lua
-- server
local squad = world:entity()
world:set(squad, net.Private, { [alice] = true, [bob] = true })

local function spawn_unit()
	local unit = world:entity()
	world:add(unit, pair(net.InheritsPrivacy, squad))
	world:add(unit, net.Replicated)
	return unit
end

-- one edit, every unit follows
net.edit_entity_privacy(squad, carol, true)
```

The group is an ordinary entity — it does not need to be `Replicated`, or even to carry a filter at all — and it is inspected and edited through the same APIs as any entity. Editing the group's filter and editing a member's own filter are structurally distinct operations, so a per-entity edit can never silently affect siblings.

And because inheritance chains, the two shapes compose: put the vehicles of a squad's convoy under the squad group and every hull — and every wheel inheriting from its hull — follows the squad's filter, three levels down, still from one edit:

```lua
-- server
world:add(hull, pair(net.InheritsPrivacy, squad))
-- squad -> hull -> wheels: hiding the squad now hides every wheel
```

## Combining independent gates

An entity may inherit from **several groups at once**, and a client must pass every one of them. That lets independent visibility rules combine without duplicating either one's membership:

```lua
-- server
world:add(unit, pair(net.InheritsPrivacy, team_fog_group))     -- who has vision of this team
world:add(unit, pair(net.InheritsPrivacy, region_interest_group)) -- who is near this region
-- visible only to clients both groups admit
```

## Containment: inheriting through a relationship

Very often the entity whose filter should be followed is the entity's *container*, and the game already records that relationship — furniture in a room is `ChildOf` the room, an item in a chest is `ChildOf` the chest, the chest is `ChildOf` the vehicle carrying it. A direct `pair(InheritsPrivacy, room)` beside the `ChildOf` pair duplicates the relationship, and the two have to be kept in step by hand: every move is a retarget *plus* a matching inheritance edit, and a forgotten edit is a silent bug — an item picked up from a room but still inheriting from it is deleted along with the room when the room is deleted.

`InheritsPrivacyThrough` removes the duplicate. Added to the inheriting entity as `pair(InheritsPrivacyThrough, relation)`, it makes the entity inherit from the target of every pair of that relation it carries, kept in sync with the relation automatically:

```lua
-- server
local room = world:entity()
world:add(room, net.Replicated)
world:set(room, net.Private, { [nearby_player] = true })

local item = world:entity()
world:add(item, pair(net.InheritsPrivacyThrough, jecs.ChildOf)) -- "follow whatever my parent allows"
world:add(item, pair(jecs.ChildOf, room))                       -- the containment pair is now the privacy edge too
world:add(item, net.Replicated)

-- picking the item up is one retarget: its visibility follows it to the player's inventory
world:add(item, pair(jecs.ChildOf, player_inventory))

-- and dropping it in another room is the same one move
world:add(item, pair(jecs.ChildOf, other_room))
```

Prefer this over direct `InheritsPrivacy` pairs wherever the two would mirror each other. The pair goes on the entity, not on `ChildOf` itself — `ChildOf` is used for interface and visual hierarchies too, and only the entities that opt in become privacy edges — and it works with any relation the entity already uses, as long as that relation carries `pair(jecs.OnDeleteTarget, jecs.Delete)` the way `ChildOf` does. duplecs refuses a relation without it, with an error explaining why: under the default policy a container's deletion would merely drop the pair, and with it the inherited filter, leaving the contents visible to everyone — a leak. With `Delete`, deleting the room deletes its contents, which is also the natural teardown. A relation of your own just needs to declare it:

```lua
-- shared
local StoredIn = world:entity()
world:add(StoredIn, pair(jecs.OnDeleteTarget, jecs.Delete)) -- required before anything inherits through it

-- server: an item in two containers at once is visible only to clients both admit
world:add(item, pair(net.InheritsPrivacyThrough, StoredIn))
world:add(item, pair(StoredIn, crate))
world:add(item, pair(StoredIn, vault))
```

Everything else about inheritance carries over unchanged. The chain `room -> chest -> item` works with each level inheriting through `ChildOf`, so one edit on the room reaches the item two levels down. Inheriting through a relation combines with direct pairs and with other relations, every gate intersecting — and a group reached more than one way stays inherited until the last way to it is gone. A container's `ExportsPrivacy` narrows what its contents inherit, exactly as for direct inheritors. And adding the pair to an entity that already has `ChildOf` pairs takes them into account immediately, while removing it drops the inherited filters again.

Reparenting ships only what changed: a client who could see the old parent but not the new one is told to delete the entity, one who sees only the new parent receives it, one who sees both receives just the changed `ChildOf` pair, and one who sees neither receives nothing at all. One thing to keep in mind if you register `removed` hooks of your own on the relation: jecs removes the old pair before adding the new one, so a hook running between the two can see the entity momentarily between parents (through `is_entity_visible`); that moment never reaches a packet.

## Containers more visible than their contents

Sometimes the group should stay visible to more clients than what inherits from it: a chest everyone can see, whose item entities should reach only the player who opened it — or an enemy base shown to everyone as a map marker, whose contents replicate only to players nearby. `ExportsPrivacy` is a second filter on the group that narrows what its inheritors receive *below* the group's own visibility, while the group itself is unaffected:

```lua
-- server
local chest = world:entity()
world:add(chest, net.Replicated) -- visible to everyone: no Private filter

-- the chest's contents inherit from it, but receive only what the chest exports
world:set(chest, net.ExportsPrivacy, {}) -- hidden from everyone, until someone opens the chest

local function spawn_item(kind)
	local item = world:entity()
	world:set(item, Item, kind)
	world:add(item, pair(net.InheritsPrivacy, chest))
	world:add(item, net.Replicated)
	return item
end

-- a player opens the chest: they alone receive its items
net.edit_exported_privacy(chest, opener, true)

-- and later, closing it takes the items away again
net.edit_exported_privacy(chest, opener, false)
```

The export filter follows every rule a `Private` filter does — an empty table hides every inheritor, a populated one is a whitelist or blacklist, `edit_exported_privacy` toggles membership exactly like `edit_entity_privacy` — and absent, inheritors simply receive the group's own gate as always. An export can only ever *narrow*: an inheritor is visible to at most the clients its group is, so hiding the chest from a client hides its items too, and the fog of war that swallows the base marker swallows the base's contents with it. Exports chain the same way inherited filters do: an entity's inheritors receive what it inherited, narrowed by its own export.

Editing an export touches only the inheritors whose visibility actually changed — the chest's own cells never re-send — so it is the right tool for frequent open/close toggles on a container.

## Widening instead: the gate-entity pattern

Occasionally the opposite shape comes up: contents that should be visible to clients who *cannot* see the container. Inheritance never widens, so no filter on the container can express that — but nothing requires an inheritor to point at the container. Point it at a separate **gate entity** instead: an ordinary entity holding the filter, which is never `Replicated` itself, parented to the container so it dies with it:

```lua
-- server
local gate = world:entity()
world:add(gate, pair(jecs.ChildOf, container)) -- deleting the container deletes the gate (and, through it, the contents)
world:set(gate, net.Private, { [scout] = true })

world:add(content, pair(net.InheritsPrivacy, gate))
```

The contents now follow the gate's filter, independent of the container's. The same pattern gives an entity several independently-edited gates at once — one gate entity per rule, each pointed at by whichever entities the rule should cover — and it costs nothing over pointing at the container directly. One thing to keep in mind when contents can be seen where their container is not: a networked pair aimed at the container (a `ChildOf`, say) is never sent to a client who cannot see its target, so such a client receives the content entity without that pair.

## Semantics to keep in mind

- **Everything narrows.** The inherited gates apply on top of the entity's own unpaired `Private` (and each other), so a client must pass all of them. Inheriting can never *widen* what an entity's own filter allows — there is no privacy hazard in pointing at one more group. An *empty* unpaired `Private` filter on any group above an entity blocks every entity below it, and so does an empty `ExportsPrivacy` filter.
- **Inheritance reaches all the way up.** An entity's effective gate applies every filter on every path of groups above it — the convoy example above, where a squad edit reaches the wheels through two levels. Those paths can branch (a group may itself inherit from several wider groups) but they can never loop: an add that would close a cycle removes the pair and errors, as does adding `InheritsPrivacy` or `InheritsPrivacyThrough` unpaired. With `InheritsPrivacyThrough` the pair removed is whichever closed the loop — the inheriting pair when it was added over existing relationship pairs, or the relationship pair itself (a `ChildOf`, say) when parenting or reparenting closed it; a containment cycle that is also a privacy cycle is a bug either way, and the error points at it.
- **Only the entity-level gate inherits.** `pair(Private, component)` filters always stay local to their entity, and `ExportsPrivacy` is entity-level only (pairing it errors).
- **Removing a pair widens safely.** Dropping `pair(InheritsPrivacy, group)` re-derives the entity's gate from its remaining filters; newly-visible clients receive current state through the ordinary visibility diff. Removing an `ExportsPrivacy` filter widens its inheritors the same way, as does removing `pair(InheritsPrivacyThrough, relation)` or one of the relationship pairs it follows.

## Deletion cascades

`InheritsPrivacy` carries `pair(jecs.OnDeleteTarget, jecs.Delete)`: deleting a group **deletes every entity inheriting from it**, and everything inheriting from those, all the way down — an entity dies when *any* of its groups dies. A group deletion therefore never silently widens anyone's visibility, and for multi-entity objects it is exactly the desired teardown (deleting the hull deletes the turret and wheels). Inheriting through a relationship relies on the relationship carrying the same policy — which is why `InheritsPrivacyThrough` refuses one without it — so deleting a container deletes what inherits through it just the same.

When inheritors should outlive a group — disbanding a squad without despawning its units — remove their pairs *before* deleting it:

```lua
-- server
for unit in world:each(pair(net.InheritsPrivacy, squad)) do
	world:remove(unit, pair(net.InheritsPrivacy, squad))
end
world:delete(squad)
```
