# duplecs

Generalized per-world replication for [jecs](https://github.com/Ukendio/jecs).

duplecs listens for changes in the server's jecs world, decides *what* should replicate to *whom*, packs data into one filtered packet per client (changes for existing clients, everything for newly-joined ones), and reconciles that data back into each client's world.

duplecs does not own transport — sending packets to clients is the caller's responsibility, typically using a `RemoteEvent`.

## Highlights

- **You decide what replicates, and to whom** — a component reaches a client only when its definition is marked `Networked`, the entity containing it is marked `Replicated`, and neither the component nor the containing entity is blocked by a `Private` filter.
- **Visibility filters** — assign a `Private` filter either per-entity or per-component: an empty one to keep state server-only, or a client-keyed one for whitelists and blacklists. A client world always holds exactly what that client is currently allowed to see.
- **Visibility inheritance** — multiple entities can inherit one entity's filter, so their visibility can be edited from a single place: a vehicle's wheels following its hull, a structure's furniture and props following its interior, or a unit inheriting both its team's fog-of-war filter and its region's proximity filter — visible only to clients that pass both.
- **Relationship support** — network relations like `jecs.ChildOf` by tagging the relation itself; a pair is never sent to a client who cannot see its target. `Private` works here too: per-component filters also prune pairs using that component as a relation.
- **Nothing sent twice** — a change ships the frame it happens and is never re-sent on the reliable path; a client joining later gets one packet holding everything currently visible to them. `NetworkedOnce` definitions go further: values ship only when the component is added, for when the client can predict changes on its own.
- **Mapped entity ids** — the server and client often have different ids for the same entity, so duplecs maps them both ways on the client: replicated entities map themselves, shared components map by name so definition order can differ between sides with no manual wiring, and duplecs provides methods for reading or assigning these mappings yourself.
- **Serdes hooks** — give a component's values a byte encoding and they pack into the packet's buffer, for a fraction of the bandwidth; components without hooks ride a plain side array, so day one needs no byte encodings.
- **Unreliable channel** — every-frame changes (e.g. positions, velocities) can be routed through self-contained chunks sized for unreliable transports, for when you need the lowest latency.
- **Client-side control** — reconciliation overrides put your code between the wire and the world: id translation, prediction gating, and interpolation buffers.

## At a glance

```lua
-- shared/components.luau -- one definitions module, shared by both sides
local jecs = require("./roblox_packages/jecs")
local duplecs = require("./roblox_packages/duplecs")

return function(world)
	local net = duplecs.shared(world) -- the duplecs component set; repeated calls return the same set

	local Health = world:component() :: jecs.Entity<number>
	world:set(Health, jecs.Name, "Health") -- component ids map by name between server and client
	world:add(Health, net.Networked) -- marks that instances of this component are allowed to replicate

	return { Health = Health }
end
```

```lua
-- server
local jecs = require("./roblox_packages/jecs")
local duplecs = require("./roblox_packages/duplecs")
local components = require("./shared/components")

local world = jecs.world()
local net = duplecs.server(world) -- the server half; subsequent calls return the same instance
local c = components(world)

-- a client is whatever you pass to add_client; in this case a Player
Players.PlayerAdded:Connect(net.add_client)
Players.PlayerRemoving:Connect(net.remove_client)

-- once per replication step: run your simulation first, then ship what it changed
RunService.Heartbeat:Connect(function()
	for client, packet in net.generate_packets() do
		remote:FireClient(client, packet)
	end
end)

-- replicate an entity: tag it, then add its networked components (the reverse also works)
local goblin = world:entity()
world:add(goblin, net.Replicated)
world:set(goblin, c.Health, 100)
```

```lua
-- client
local jecs = require("./roblox_packages/jecs")
local duplecs = require("./roblox_packages/duplecs")
local components = require("./shared/components") -- the same component module

local world = jecs.world()
local net = duplecs.client(world) -- the client half; subsequent calls return the same instance
local c = components(world)

-- reconcile packets when received
remote.OnClientEvent:Connect(net.reconcile_packet)

-- the goblin should show up as an ordinary entity in the client world
RunService.RenderStepped:Connect(function()
	for entity, health in world:query(c.Health) do
		print(`goblin health: {health}`)
	end
end)
```

The full wiring can be found in the [getting started guide](docs/guides/001-getting-started.md).

## Installation

duplecs is published to the [pesde](https://pesde.dev) and [Wally](https://wally.run) registries (the scope is `demidog` on pesde but `demi-dog` on Wally — the two registries forbid opposite punctuation characters in names, so the spelling difference is deliberate, not a typo).

With pesde, run `pesde add demidog/duplecs`, or declare the dependency in `pesde.toml` yourself, alongside your own jecs dependency:

```toml
[dependencies]
duplecs = { name = "demidog/duplecs", version = "^1.0.0" }
jecs = { wally = "ukendio/jecs", version = "^0.11.0" }
```

With Wally, declare it in `wally.toml`:

```toml
[dependencies]
duplecs = "demi-dog/duplecs@^1.0.0"
jecs = "ukendio/jecs@^0.11.0"
```

duplecs resolves jecs `^0.11.0` transitively (from the Wally registry, `ukendio/jecs`), but your project needs jecs anyway to create the world — keep the versions compatible so both resolve to a single installation.

For Studio-only workflows, every release also attaches a ready-to-insert `duplecs.rbxm` to its [GitHub release](https://github.com/demi-dog/duplecs/releases). Insert it somewhere both sides can reach (typically `ReplicatedStorage`), then open `duplecs > roblox_packages > jecs` and replace its error line with a require of your project's jecs module, as its comment instructs — until then, requiring duplecs raises that same instruction. The artifact deliberately bundles no jecs of its own, because duplecs and your own code must share one jecs installation; if your place doesn't have jecs yet, jecs attaches its own `.rbxm` to [its releases](https://github.com/Ukendio/jecs/releases) (use a `0.11.x` version).

Before upgrading duplecs, check the [changelog](CHANGELOG.md): every entry states whether the wire format changed, and both sides of the wire must run the same duplecs build, so a wire change means upgrading the server and its clients together.

## Documentation

- [`docs/guides/`](docs/guides/README.md) — task-oriented guides, each built around working code: a [getting started](docs/guides/001-getting-started.md) setup guide plus per-feature guides readable in any order.
- [`docs/api.md`](docs/api.md) — the public API listing: every export with a short description.
- [`docs/spec.md`](docs/spec.md) — the complete specification: exact guarantees, edge cases, and performance notes behind every behavior.
- [`CHANGELOG.md`](CHANGELOG.md) — per-release change history.

## Contributing

Development runs standalone under [Lune](https://github.com/lune-org/lune) — no Roblox instance involved. [`CONTRIBUTING.md`](CONTRIBUTING.md) covers the setup, the repository layout, the checks a change must keep green, and the changelog and release process.

## Status

duplecs is licensed under the [MIT license](LICENSE) and published on the pesde and Wally registries — see [Installation](#installation) for the package names. Releases are documented in the [changelog](CHANGELOG.md), each entry stating whether the wire format changed.
