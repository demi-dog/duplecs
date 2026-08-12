# Entities Across the Network

Entity ids are not shared across the network: the same gameplay entity has a different id in the server world than in each client world. duplecs maps ids both ways in each client world — a **server** id (the server's id, as carried in packets) to a **client** entity (this world's id) and back — and most of the mapping forms automatically. This guide covers the mechanisms, when you need to intervene, and the prediction flow. Exact contracts live in the spec's [Server vs. Client entities](../spec.md#server-vs-client-entities), [Shared names](../spec.md#shared-names), and [Entity Mapping](../spec.md#entity-mapping-client) sections.

## What maps automatically

- **Gameplay entities** — as `Replicated` entities arrive, reconciliation creates client entities and maps them through their creation entries. Nothing to do.
- **Named definitions and targets** — the server announces the `jecs.Name` of every networked definition and every named unreplicated pair target; the client resolves each name against its own world's name index. Define components identically-named on both sides (the shared module from [Getting started](001-getting-started.md)) and they map with no calls at all — jecs built-ins like `ChildOf` included.

The one timing rule behind automatic names: the mapping must exist before the id's *data* first arrives. Announcements are one-shot — an announcement resolving no client entity is skipped silently (that's normal: announcements reach every client, including ones the definition is irrelevant to), and naming the entity later does not retroactively form the mapping. Data arriving for a still-unmapped id warns (`[duplecs]`-prefixed, once per id) and skips; the skipped data only re-arrives when it next changes server-side. So: names at startup, before packets flow.

## Sending entity references to the server

When the client references an entity in a request — "attack this target" — translate the client entity to its server id — the id the entity has in the server world:

```lua
-- client
local server_target = net.get_server_entity(target)
if server_target then
	attack_remote:FireServer(server_target)
end
```

```lua
-- server
attack_remote.OnServerEvent:Connect(function(player, target)
	if typeof(target) ~= "number" or not world:contains(target) then
		return
	end
	-- validate gameplay-side too: is this a legal target for this player?
	begin_attack(player, target)
end)
```

Never send a client id raw — it means nothing (or worse, something else) in the server world. In the other direction, when a server value *embeds* an entity id, the client must translate it on arrival with `get_client_entity` — a [changed override](010-overrides.md) is the tool for that.

## Manual mapping: `set_client_entity`

`set_client_entity(server_id, client_entity)` registers a mapping by hand. Two uses:

- **Startup mapping** for definitions automatic names don't reach — definitions without a `jecs.Name`, or named differently across sides.
- **Prediction** — the main event, below.

A manual mapping does *not* claim the entity as client-owned: a mapped entity is server-driven like any other server entity, and unreplication deletes it. (Giving an entity a shared `jecs.Name` is what claims it — a name-mapped entity belongs to the client world, and reconciliation never deletes it.)

## The prediction flow

Prediction means acting locally *now* — spawning the projectile the instant the player fires — and letting the server's authoritative entity land on that local stand-in later, instead of a duplicate appearing next to it. The flow: the client creates the stand-in immediately and includes its id in the request itself, as a token the server does nothing with but echo back. The server creates the real entity and responds with both ids. The client then maps them with `set_client_entity`, so the entity's creation entry adopts the prepared stand-in when it arrives instead of creating a fresh entity.

```lua
-- client: spawn the stand-in immediately, and send its client id along with the request
local function fire()
	local projectile = world:entity()
	world:set(projectile, components.Position, predicted_spawn_position())
	fire_remote:FireServer(projectile)
end

-- server: create the authoritative entity, echo the client entity back beside the real one
fire_remote.OnServerEvent:Connect(function(player, client_entity: number)
	local projectile = spawn_projectile(player)  -- Replicated, like any gameplay entity
	fire_remote:FireClient(player, client_entity, projectile)
end)

-- client: map the server's id onto the client id — or concede the race
fire_remote.OnClientEvent:Connect(function(client_entity, server_entity: number)
	if net.get_client_entity(server_entity) then
		-- the entity's replication arrived first and created its own client entity;
		-- the mapping is taken, so retire the now-duplicate stand-in
		world:delete(client_entity)
		return
	end
	net.set_client_entity(server_entity, client_entity)
end)
```

The response usually wins the race — the server replies from inside the request handler, while the entity's replication waits for the next `generate_packets`. The creation entry then silently adopts the stand-in: the server's components land on it, and locally-set predicted state stands until authoritative values overwrite it (pair prediction with [overrides](010-overrides.md) to reconcile rather than snap). But the ordering is not guaranteed, hence the `get_client_entity` check: when the creation arrives first, reconciliation has already created a client entity for the server id, and `set_client_entity` would error on the taken mapping. The stand-in is now a duplicate — delete it and let the server's entity stand.

## The `Imported` tag

Every mapped client entity carries the `Imported` tag — useful for queries that should distinguish server-driven entities from purely-local ones (effects, UI proxies):

```lua
-- client
for entity in world:each(net.Imported) do
	...
end
```

It is managed internally: adding it yourself is rejected, and removing it tears down the entity's mapping (rarely what you want — prefer letting unreplication do it).
