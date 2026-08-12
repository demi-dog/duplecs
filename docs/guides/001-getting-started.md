# Getting Started

This guide takes you from an empty project to entities replicating from a server world into client worlds. It assumes you know [jecs](https://github.com/Ukendio/jecs) basics — worlds, entities, components, and pairs — but nothing about duplecs.

The code below forms three complete scripts — a shared component module, one server script, and one client script. It requires packages by string path; substitute however your project resolves packages.

Install duplecs following the [installation instructions](../../README.md#installation) before starting if you haven't yet.

## Define your networked components

Replication requires two independent opt-ins:

- **`Networked`** goes on a **component definition**: instances of this component are *allowed* to replicate.
- **`Replicated`** goes on a **gameplay entity**: *this entity* and its networked components should replicate.

A component instance replicates only when both gates pass. Everything else stays server-side by default, because nothing replicates until you tag it.

Component definitions can be created and `Networked` in the same place: `duplecs.shared(world)` returns the same component set used by the server and client halves, and the `Networked` tag is inert on the client.

Networked components are mapped by their `jecs.Name` between server and client automatically, so no manual mapping is required.

```lua
-- shared/components.luau
local jecs = require("./roblox_packages/jecs")
local duplecs = require("./roblox_packages/duplecs")

return function(world: jecs.World)
	local net = duplecs.shared(world)

	-- give each definition a name; identical names map automatically
	local Health = world:component() :: jecs.Entity<number>
	world:set(Health, jecs.Name, "Health")
	world:add(Health, net.Networked)

	local Poison = world:component() :: jecs.Entity<{
		tick_duration: number,
		tick_damage: number,
	}>
	world:set(Poison, jecs.Name, "Poison")
	world:add(Poison, net.Networked)

	-- never tagged Networked, so its values never replicate
	local PoisonTickTimer = world:component() :: jecs.Entity<number>
	world:set(PoisonTickTimer, jecs.Name, "PoisonTickTimer")

	-- relations replicate too: networking ChildOf ships the goblin -> poison hierarchy
	world:add(jecs.ChildOf, net.Networked)

	return {
		Health = Health,
		Poison = Poison,
		PoisonTickTimer = PoisonTickTimer,
	}
end
```

`PoisonTickTimer` shows a convention worth adopting: you can define *every* component in a shared module, even ones only one side uses. An untagged definition is inert — it costs nothing on the side that never touches it — and every component your game has stays legible in one place.

## Server setup

`duplecs.server(world)` returns the server half of duplecs for a world. The first call constructs the server half, creates its hooks, and picks up anything already tagged. All subsequent calls then return that same instance, so any system can call it directly instead of passing the instance around. Tracking is live from construction, with nothing further to call before the first `generate_packets`.

A client is any value you hand to `add_client` — here a `Player`, which is also what `generate_packets` keys the returned packets by. After a client joins, the next `generate_packets` call returns a packet containing everything currently visible to them; every call after that returns only what changed since the last call.

```lua
-- server
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local jecs = require("./roblox_packages/jecs")
local duplecs = require("./roblox_packages/duplecs")
local components = require("./shared/components")

local world = jecs.world()
local net = duplecs.server(world)
local c = components(world)

local remote = Instance.new("RemoteEvent")
remote.Name = "Replication"
remote.Parent = ReplicatedStorage

Players.PlayerAdded:Connect(net.add_client)
Players.PlayerRemoving:Connect(net.remove_client)

local function replicate_system()
	for client, packet in net.generate_packets() do
		remote:FireClient(client, packet)
	end
end

local function spawn_goblins_system()
	for _ in world:each(c.Health) do
		return -- one goblin at a time; wait for the current one to die
	end

	local goblin = world:entity()
	world:set(goblin, c.Health, 100)
	world:add(goblin, net.Replicated)

	-- the status effect is an entity of its own: data-driven, found by a query like anything
	-- else, and deleted with its target through ChildOf's cleanup
	local poison = world:entity()
	local state = {
		tick_damage = 10,
		tick_duration = 1,
	}
	world:set(poison, c.Poison, state)
	world:set(poison, c.PoisonTickTimer, state.tick_duration)
	world:add(poison, jecs.pair(jecs.ChildOf, goblin))
	world:add(poison, net.Replicated)
end

local function tick_poisons_system(dt: number)
	local dead: { jecs.Entity } = {}

	for poison, state, timer in world:query(c.Poison, c.PoisonTickTimer) do
		-- a per-frame set on a component that isn't Networked ships nothing
		timer -= dt
		if timer > 0 then
			world:set(poison, c.PoisonTickTimer, timer)
			continue
		end
		world:set(poison, c.PoisonTickTimer, state.tick_duration)

		local target = world:parent(poison)
		if target == nil then
			continue
		end

		local health = world:get(target, c.Health)
		if health == nil then
			continue
		end

		if health > state.tick_damage then
			world:set(target, c.Health, health - state.tick_damage)
		else
			-- deleting the goblin also deletes its poison child, so deleting mid-query would invalidate
			-- this query's iterator: always defer deletions out of query loops (a jecs limitation)
			table.insert(dead, target)
		end
	end

	for _, entity in dead do
		world:delete(entity)
	end
end

-- one Heartbeat runs the frame in a fixed order, with replication last so each frame ships
-- what the systems before it just changed (a system after it would ship a frame late)
RunService.Heartbeat:Connect(function(dt: number)
	spawn_goblins_system()
	tick_poisons_system(dt)
	replicate_system()
end)
```

The poison status effect is ordinary ECS modeling — an entity of its own carrying data, attached with `jecs.ChildOf`, found by a query, deleted with its target — and it replicates like anything else: the definition is `Networked`, the entity is `Replicated`, and because `ChildOf` itself is `Networked`, the hierarchy ships too. The split into two components is deliberate: `Poison` holds configuration that never changes after spawn, so it ships exactly once, while the countdown lives in `PoisonTickTimer`, whose definition never got `Networked` — so sixty sets a second send nothing.

No tag is the right call here because nothing on the client reads the countdown. If a client system *did* need it — say, to render tick progress — the answer still wouldn't be `Networked`: a third tag, `NetworkedOnce`, ships a component's value only when a client receives the component for the first time — clients would instead progress the timers locally. [Replication basics](002-replication.md) covers choosing between the tracking modes.

## Client setup

`duplecs.client(world)` is the client-side counterpart — the same construct-once-per-world accessor, returning the client half. Run the same shared component module against the client's world, and mirror the scheduler shape: received packets queue up, and the first system of every frame reconciles them.

```lua
-- client
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local jecs = require("./roblox_packages/jecs")
local duplecs = require("./roblox_packages/duplecs")
local components = require("./shared/components")

local world = jecs.world()
local net = duplecs.client(world)
local c = components(world)

-- queue packets to be processed by the reconcile system
local pending_packets: { duplecs.Packet } = {}

local remote = ReplicatedStorage:WaitForChild("Replication")
remote.OnClientEvent:Connect(function(packet: duplecs.Packet)
	table.insert(pending_packets, packet)
end)

local function reconcile_system()
	for _, packet in pending_packets do
		net.reconcile_packet(packet)
	end
	table.clear(pending_packets)
end

-- track the last health seen per entity so only changes are printed
local last_seen: { [jecs.Entity]: number } = {}

local function watch_goblins_system()
	for entity, health in world:query(c.Health) do
		if last_seen[entity] ~= health then
			last_seen[entity] = health
			print(`goblin {entity} health: {health}`)
		end
	end

	for entity in last_seen do
		if not world:contains(entity) then
			last_seen[entity] = nil
			print(`goblin {entity} died`)
		end
	end
end

-- announce each poison once, then forget ids that died with their goblin
local announced: { [jecs.Entity]: boolean } = {}

local function watch_poisons_system()
	for poison, state in world:query(c.Poison) do
		if not announced[poison] then
			announced[poison] = true
			-- world:parent resolves the replicated ChildOf pair to the goblin's client id
			print(`goblin {world:parent(poison)} is poisoned: {state.tick_damage} damage every {state.tick_duration}s`)
		end
	end

	for poison in announced do
		if not world:contains(poison) then
			announced[poison] = nil
		end
	end
end

-- reconcile first, so every system after it reads the most recent server state
RunService.Heartbeat:Connect(function()
	reconcile_system()
	watch_goblins_system()
	watch_poisons_system()
end)
```

`reconcile_packet` deletes unreplicated entities and removes unreplicated components, creates newly-replicated ones, registers announced names, and applies every value change. After it returns, the client world reflects the server world it's allowed to see. Feeding it straight from `OnClientEvent` would work as well, since RemoteEvents deliver reliably and in order — but draining a queue at a fixed point in the frame means every system after `reconcile_system` reads the most recent server state.

The client world is an ordinary jecs world — the goblin and its poison arrive as plain client entities, found by plain queries. The ids are the *client world's* own: the same goblin has a different id in each world, so requests about a specific entity should go through the mapping API; see [Entities across the network](004-entity-mapping.md). The poison watcher leans on that mapping without a single call: the `ChildOf` pair arrived re-targeted at the client's own goblin, so `world:parent` just works.

## What ships, frame by frame

Press Play, and the client's output shows one goblin lifetime every ten seconds:

```
goblin 271 health: 100
goblin 271 is poisoned: 10 damage every 1s
goblin 271 health: 90
...
goblin 271 health: 10
goblin 271 died
```

The poison line agrees with the health lines about who `271` is even though one number came from a query and the other from `world:parent` — the mapping held. The id itself is whatever the client world created: a respawned goblin gets a fresh one, and ids are neither consecutive nor predictable — never take one apart or count on its value. The same lifetime, from the wire's point of view:

- **The spawn frame.** `spawn_goblins_system` creates and tags the goblin and poison entities; the same frame's `replicate_system` ships one delta carrying both creations, the goblin's `Health`, the poison's `Poison` value, and the `ChildOf` pair — which the client re-targets at its local goblin, so `world:parent` resolves.
- **Quiet frames.** Nothing was queued up to send, so nothing ships — even though `tick_poisons_system` sets `PoisonTickTimer` on every one of them: the definition isn't `Networked`, so the set queues nothing. Clients with nothing to receive are omitted from `generate_packets`' return, the loop body never runs, and the wire carries zero bytes. At sixty frames per second, that is ~59 frames of every second.
- **Tick frames.** The once-a-second `world:set` on `Health` queues one change, and the delta ships exactly that value. A `world:remove(goblin, c.Health)` would ship the same way, as a removal — the client's goblin losing the component with it.
- **The death frame.** `world:delete` ships the goblin's disappearance — and its poison child's, deleted server-side by `ChildOf`'s cleanup. The client deletes both client entities whole, and the watch system prints the death. Removing `Replicated` instead would unreplicate an entity the same way.
- **A joiner, any time.** Their first packet is a full packet of everything currently visible to them — a goblin mid-decay arrives at its current health, not its history, poison and hierarchy included — and every packet after is a delta. The server code never distinguishes: send whatever comes back.

Each change is delivered exactly once — `generate_packets` drains the accumulated changes, which is why the Heartbeat calls it every frame, unconditionally. Meanwhile `PoisonTickTimer` changes every frame and never crosses the wire: a `Replicated` entity moves only its *networked* components, and one failed gate keeps a component home. Hiding data behind a [visibility filter](005-visibility-filters.md) arrives through the same machinery — a client newly excluded from a component receives its removal, one excluded from the entity receives its deletion — so a client world always holds exactly what that client is currently allowed to see, and nothing you do server-side needs a cleanup path of its own.

## Common early mistakes

- **A component doesn't replicate.** Check both gates: the definition carries `Networked` *and* the entity carries `Replicated`. Also check the name — the shared module must have run on both sides with identical `jecs.Name`s before the component's data first arrives; the client warns (`[duplecs]`-prefixed) when data arrives for an id it cannot map.
- **Mutating a networked value in place.** Editing a field inside a table value fires no changed hook, so nothing ships. Put changed values through `world:set` (jecs fires the hook even when the value is equal, so re-setting the same table works) — or split per-frame scratch state into a non-networked component, as the demo does with `PoisonTickTimer`.
- **Referencing server entities by client id.** The same gameplay entity has different ids in each world. When the client sends a request about an entity, translate with `get_server_entity` first — see [Entities across the network](004-entity-mapping.md).
- **Skipping `generate_packets` on "idle" frames.** Joins resolve and deltas flush inside it; call it every replication step even when the world seems quiet.
- **Scheduling systems after `replicate_system`.** They still replicate — changes made after `generate_packets` accumulate for the next call — but everything they do ships a frame late. Keep the replication system last.
- **Marking definitions `Replicated` or gameplay entities `Networked`.** The two tags are mutually exclusive roles and duplecs errors on the mixup at the offending call site.

## Where next

The [guide index](README.md) lists every per-feature guide. Natural next steps from here:

- [Replication basics](002-replication.md) — the tracking modes (`Networked`, `NetworkedOnce`, `NetworkedUnreliable`) and exactly what ships when.
- [Replicating relationships](003-pairs.md) — more on networked relations like `ChildOf`: what makes a pair target replicable, and target-deletion behavior.
- [Visibility filters](005-visibility-filters.md) — per-client visibility: server-only state, whitelists, and blacklists.
- [Serdes](008-serdes.md) — serialize/deserialize hooks that pack values into the packet buffer instead of the side array; a third-party library makes this a few lines per component.
- [Unreliable values](009-unreliable.md) — stream per-frame values (positions, velocities) without flooding the reliable channel.

For exact contracts — edge cases, guarantees, performance characteristics — every guide links into the [specification](../spec.md), the complete reference behind all of them.
