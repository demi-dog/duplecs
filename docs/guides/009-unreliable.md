# Unreliable Values

Values that change every frame — positions, velocities, aim directions — fit the reliable delta model badly: every `world:set` would fire a changed hook and every change would ride the reliable stream. `NetworkedUnreliable` is the tracking mode for exactly these: **membership stays reliable, values go unreliable**, re-sent every frame through a parallel channel that shrugs off drops and reordering. Exact contracts live in the spec's [Unreliable values](../spec.md#unreliable-always-replicate-values) concept and its `generate_unreliable_chunks` ([Packet Generation](../spec.md#packet-generation-server)) and `reconcile_chunk` ([Reconciliation](../spec.md#reconciliation-client)) entries.

## Setup

Three ingredients: the tag, [serdes hooks](008-serdes.md), and a second remote. The hooks — the serialize/deserialize pair that gives a value a byte encoding — are required here because chunking needs byte-exact sizing and there is no side-array fallback:

```lua
-- shared/components.luau
local Position = world:component() :: jecs.Entity<Vector3>
world:set(Position, jecs.Name, "Position")
world:set(Position, net.Serdes, {
	size = 12,
	encode = function(value: Vector3): buffer
		local data = buffer.create(12)
		buffer.writef32(data, 0, value.X)
		buffer.writef32(data, 4, value.Y)
		buffer.writef32(data, 8, value.Z)
		return data
	end,
	decode = function(data: buffer): Vector3
		return Vector3.new(buffer.readf32(data, 0), buffer.readf32(data, 4), buffer.readf32(data, 8))
	end,
})
```

```lua
-- server
world:add(components.Position, net.NetworkedUnreliable)

local unreliable_remote = Instance.new("UnreliableRemoteEvent")
unreliable_remote.Name = "Streaming"
unreliable_remote.Parent = ReplicatedStorage

RunService.Heartbeat:Connect(function()
	for client, packet in net.generate_packets() do
		remote:FireClient(client, packet)
	end
	for client, chunks in net.generate_unreliable_chunks() do
		for _, chunk in chunks do
			unreliable_remote:FireClient(client, chunk)
		end
	end
end)
```

```lua
-- client
unreliable_remote.OnClientEvent:Connect(function(chunk: buffer)
	net.reconcile_chunk(chunk)
end)
```

That's the whole loop. `world:set(entity, Position, ...)` on the server now costs nothing (no changed hook is connected at all) — every `generate_unreliable_chunks` call re-reads every visible value and packs them into **chunks**: self-contained buffers of at most `chunk_bytes` bytes (default 980, sized for Roblox's 1000-byte unreliable remote limit), each sent through the unreliable remote.

## What rides which channel

On the reliable path an unreliable component tracks like `NetworkedOnce`: the **add** replicates with its initial value, **removals** and **visibility changes** replicate, and full packets carry current values — so a joiner (or a client newly admitted by a visibility filter) is never blank while waiting for the stream. Everything in between — the actual motion — rides the chunks.

Pairs using the component as the relation stream too, and tags are refused (an always-streamed tag carries nothing).

## Why drops don't matter

The channel is drop- and reorder-tolerant by construction, with no bookkeeping on your side:

- A **lost chunk** costs one frame of staleness — the next call re-sends everything.
- A **stale chunk** (arriving after a newer one) is dropped whole by the client's chunk-frame gate, so values never snap backward.
- A chunk that **outruns the reliable packet** creating its entities skips those ids harmlessly — they resolve on a later frame's chunks once the mapping exists.

Membership is authoritative on the reliable path: with no override registered, a chunk value applies only where the client entity currently has the component, so a late chunk can never resurrect a reliably-removed component.

The two generate calls may run at different rates (stream at Heartbeat, reliable at 20 Hz, say). Visibility on the unreliable channel follows the **last reliable packets sent**, so membership and privacy changes take effect there after the next `generate_packets` — keep the reliable loop running alongside the stream.

## Timestamping received values

Position streams usually land in an interpolation or snapshot buffer rather than directly in the world — that's a [changed override](010-overrides.md). To order what you capture, read each chunk's frame counter before reconciling; reconcile is synchronous, so an upvalue carries it into the override:

```lua
-- client
local current_frame = 0

net.set_changed_override(components.Position, function(entity, position: Vector3?)
	if position ~= nil then
		push_snapshot(entity, current_frame, position)
	end
end)

unreliable_remote.OnClientEvent:Connect(function(chunk: buffer)
	current_frame = net.get_chunk_frame(chunk)
	net.reconcile_chunk(chunk)
end)
```

A stale chunk is dropped before any override fires, so `current_frame` never stamps values older than ones already captured. The chunk frame is independent of the reliable stream's packet frame — the two counters are never comparable to each other.

## Costs and caveats

- **Bandwidth is rate × visible values.** Every visible value re-sends every call — that's the contract. Budget with fixed-size serdes (a 12-byte position at 30 Hz is ~360 B/s per entity per client, plus ~90 B/s from the 3 bytes per id) and use [visibility filters](005-visibility-filters.md) or interest groups to bound *visible*.
- **Chunk buffers are shared by reference** between clients with equal visibility — never mutate them.
- **Serdes failures self-heal but re-warn.** A failing `encode`, a missing hook, or a value too large to fit even an empty chunk prunes just the affected values with a warning — and since everything re-sends each call, the warning repeats until the hook or value is fixed, and the channel resumes whole on its own.
