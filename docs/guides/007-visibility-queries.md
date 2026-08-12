# Visibility Queries

The server resolves per-client visibility as changes happen, and it can answer visibility questions directly — which is how you keep side channels (events, sounds, hit markers sent outside the packet stream) consistent with what each client is allowed to know. Exact contracts live in the spec's [Visibility](../spec.md#visibility-server) section.

## Gating a side channel

`is_component_visible` applies every gate `generate_packets` applies — entity replication, entity-level and per-component [visibility filters](005-visibility-filters.md), [visibility inheritance](006-visibility-inheritance.md), pair-target visibility, `Networked` eligibility — so a side-channel send gated on it can never leak what the packet stream is hiding:

```lua
-- server
local function send_ability_used(caster, ability_payload)
	for _, player in Players:GetPlayers() do
		if net.is_component_visible(caster, components.Loadout, player) then
			ability_remote:FireClient(player, ability_payload)
		end
	end
end
```

When the question is about the entity as a whole, `is_entity_visible(entity, client)` is the outer gate — `false` implies every component on the entity is invisible to that client too.

## Enumerating instead of probing

When you'd probe every player, invert it: `get_clients_seeing(entity)` iterates exactly the clients the entity is visible to, read straight off the visibility masks rather than testing each client:

```lua
-- server
for client in net.get_clients_seeing(explosion_source) do
	explosion_remote:FireClient(client, explosion_payload)
end
```

Three caveats: enumeration order is unspecified (don't build on it), pending joiners never enumerate (they have no slot until their first `generate_packets`, and see nothing until their full packet), and the masks are read live as iteration advances — finish the loop (or collect into a table) before making changes that affect visibility (privacy edits, `Replicated` changes, `remove_client`).

## Current vs. last-sent

Every query above has a **last-sent** counterpart — `was_entity_visible`, `was_component_visible`, `get_clients_last_seeing` — answering against only what the most recent `generate_packets` shipped, ignoring anything that has changed since. The distinction: `is_*` describes what the client *is about to* know; `was_*` describes what the client *actually holds right now*, before the next flush. Use `was_*` when acting on the client's present knowledge — e.g. deciding whether an effect needs to be replayed to a client who hasn't yet received the entity at all.

Both families return `false` for untracked clients, and `is_client_tracked(client)` answers registration itself — `true` from `add_client` until `remove_client`, pending joiners included (even while their visibility queries still answer `false`; see [Client lifecycle](011-client-lifecycle.md)).

## Debugging privacy setups

These same queries are how you inspect a filter setup that misbehaves: pick a client and an entity, then walk outward — `is_entity_visible` first (entity gate, including inherited groups), then `is_component_visible` per component (adds the per-component filter and pair-target rules), then `get_clients_seeing` to see the whole admitted set at once. Since every gate composes into these answers, the first query that disagrees with your expectation names the layer to inspect.
