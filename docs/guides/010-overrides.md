# Reconciliation Overrides

By default, reconciliation applies a packet's entries directly to the world: set entries via `world:set`, nulled entries via `world:add` (or a `nil` set for data components), removed entries via `world:remove`. Overrides replace those defaults per component, putting your code between the wire and the world — the hook point for prediction, id translation, and interpolation buffers. Exact contracts live in the spec's [Overrides](../spec.md#overrides-client) section.

## Registering

```lua
-- client
net.set_changed_override(component, function(entity, value)
	-- invoked for the component's set and nulled entries (value is nil for nulled)
end)

net.set_removed_override(component, function(entity)
	-- invoked for the component's removed entries
end)
```

Pass `nil` to clear either. Once a changed override is registered, *you* own application — the world only changes if your handler changes it. The getters (`get_changed_override`/`get_removed_override`) return what's registered, which makes wrapping an existing override straightforward:

```lua
-- client
local inner = net.get_changed_override(components.Health)
net.set_changed_override(components.Health, function(entity, health)
	record_damage_event(entity, health)
	if inner then
		inner(entity, health)
	else
		world:set(entity, components.Health, health)
	end
end)
```

## Translating embedded entity ids

A component value that *embeds* an entity id arrives holding a server id — duplecs never looks inside a value, so it can't know to translate it. An override does it at the boundary, so the rest of the client only ever sees client entities:

```lua
-- client: Target's value is an entity id; the server stores (and thus sends) its own ids
net.set_changed_override(components.Target, function(entity, server_id: number?)
	if server_id == nil then
		world:set(entity, components.Target, nil)
		return
	end
	-- may be nil if the target isn't visible to this client — decide what that means for you
	world:set(entity, components.Target, net.get_client_entity(server_id))
end)
```

(Where the relationship's shape allows it, a replicated *pair* avoids the problem entirely — pair targets are translated by duplecs itself. Embedded ids are for values where a pair doesn't fit: ids inside larger payloads, arrays of ids, and so on.)

## Prediction: keeping the server from clobbering local simulation

A client predicting an entity's state wants authoritative values *reconciled*, not snapped over its simulation. Gate the default with a local marker:

```lua
-- client
local Predicted = world:component()

net.set_changed_override(components.Position, function(entity, position: Vector3?)
	if world:has(entity, Predicted) then
		-- feed the authoritative value to the corrector instead of the world
		submit_correction(entity, position)
		return
	end
	world:set(entity, components.Position, position)
end)
```

This composes with the [prediction mapping flow](004-entity-mapping.md#the-prediction-flow): the stand-in entity you map ahead of replication is where you add `Predicted`.

## Interpolation buffers

Streamed values usually belong in a snapshot buffer, not directly in the world; with an override, the world's copy never churns and your interpolator owns the timeline. See [Unreliable values](009-unreliable.md#timestamping-received-values) for the full pattern, including frame-stamping each captured value with `get_chunk_frame`. Overrides registered for a component fire on both paths — reliable packets and unreliable chunks — with one asymmetry: on the unreliable path the default applies a value only where the entity already has the component, but a registered changed override is invoked regardless and owns that decision. Removed overrides never fire there, since chunks carry no removals.

## Pairs: register per-relation

A pair whose target is the wildcard registers for the relation itself, so one registration covers every pair of that relation — and a concrete pair without an override of its own falls back to its relation's:

```lua
-- client
net.set_changed_override(jecs.pair(components.DamageOver, jecs.Wildcard), function(entity, amount)
	...  -- fires for pair(DamageOver, fire), pair(DamageOver, poison), ...
end)

-- a concrete pair with a registration of its own uses it instead of the relation's
net.set_changed_override(jecs.pair(components.DamageOver, fire), function(entity, amount)
	...  -- fires for pair(DamageOver, fire) only; other targets still use the wildcard's
end)
```

The getters return only what was registered for exactly the key you pass, under the same wildcard-reads-as-the-relation rule — never the relation fallback.

## Handler ground rules

- **Declare nillability.** `nulled` entries invoke changed handlers with `nil`, so when nulls are possible for the component (a tag, or a data component set to `nil`), type the parameter nillable and handle it.
- **Handlers run inside reconciliation.** Keep them focused on applying (or routing) the one entry they're given; the packet's remaining entries apply after they return.
- **Removed overrides own removal.** With one registered, `world:remove` is not called for you — forgetting to remove leaves the component stale on the entity.
