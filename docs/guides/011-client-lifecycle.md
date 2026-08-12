# Client Lifecycle

How clients join, leave, and — for games that need it — hand a replication stream over to a new connection. Exact contracts live in the spec's [Client Lifecycle](../spec.md#client-lifecycle-server) and [Client slots and visibility](../spec.md#client-slots-and-visibility) sections.

## The basic loop

A client is any value you hand to `add_client` — typically a `Player` — and the caller drives the lifecycle:

```lua
-- server
Players.PlayerAdded:Connect(function(player)
	net.add_client(player)
end)

Players.PlayerRemoving:Connect(function(player)
	net.remove_client(player)
end)
```

`add_client` queues the client as a **pending joiner**: their slot is allocated and their first packet — a full packet carrying everything currently visible to them — is built at the end of the next `generate_packets`, after that frame's delta has resolved. There is no joiner special-casing on your side: send whatever `generate_packets` returns. Until that call, the pending client sees nothing — visibility queries answer `false` and the client enumerators skip them — but they are already *registered*: `is_client_tracked` answers `true`, and visibility filters may already name them.

`remove_client` frees the slot (or cancels a pending join). There is no cap on concurrent clients, and slots freed by departures are reused, so a stable population stays compact however much churn preceded it.

## Departures and visibility filters

`remove_client` also prunes the departing client from every cached [visibility filter](005-visibility-filters.md), so the caches never pin a departed `Player` and a rejoin under the same value always starts **unlisted** — re-admit (or re-name) them after the rejoin if they should keep their standing. A blacklist whose last named client departs is removed from its entity outright, since it no longer restricts anyone.

The prune walks the cached filter store, so departure cost scales with how many filters exist — negligible for typical setups, but one extreme shape (whitelists naming nearly every client, on very many entities) makes departures expensive. If that describes your filters, restructure toward a blacklist or one shared [inheritance group](006-visibility-inheritance.md); the spec's [Client Lifecycle](../spec.md#client-lifecycle-server) section has the measured numbers.

## Handovers: `mark_client_fresh`

Some games keep a replication slot alive across connections — e.g. a fog-of-war RTS where a disconnected player's seat must keep exactly what it could see, for a reconnecting or substituting player to resume. The key move: register **slot values, not connections**, as the clients:

```lua
-- server
local slots = { "seat_1", "seat_2", "seat_3", "seat_4" }
local connections: { [string]: Player } = {}

for _, slot in slots do
	net.add_client(slot)
end

RunService.Heartbeat:Connect(function()
	for slot, packet in net.generate_packets() do
		local player = connections[slot]
		if player then
			remote:FireClient(player, packet)
		end
		-- no connection behind the slot: discard the packet — the slot's stream state advances regardless
	end
end)

local function assign_connection(slot: string, player: Player)
	connections[slot] = player
	net.mark_client_fresh(slot)
end
```

`mark_client_fresh(slot)` declares that the world behind the slot has never reconciled a packet from this server world, so the next `generate_packets` returns a **full packet** in place of the slot's delta. The slot itself — visibility filters, visibility masks, and the record of what it has already been sent — persists untouched, and subsequent deltas continue seamlessly from the full. Send that full packet and everything after it to the new connection.

Three warnings from the spec worth repeating:

- **Freshness is a precondition you're declaring, not a resync knob.** A full packet carries no removals or deletes, so a client world that has already reconciled state from this server world would keep whatever the full doesn't name. The receiving world must genuinely be fresh — tear it down first if it isn't.
- **A vacant slot keeps costing what a live client costs** — visibility tracking, section resolution, per-frame packet assembly. Don't hold slots that will never be filled again; `remove_client` them.
- While a slot is vacant, the `was_*` visibility queries describe what the slot's *stream* has been sent — exactly what the next occupant's deltas will diff against — not what any connected client holds.

Marking a pending joiner is a no-op (their join already produces a full), marking an untracked client warns and does nothing, and `remove_client` clears the mark.

## Splitting streams across channels

Packets are self-describing enough to route flexibly: every packet from one `generate_packets` call carries the same **packet frame** counter, readable on the client via `get_packet_frame(packet)` without reconciling. A caller sending packets over several channels can group, dedupe, or order them by frame (the spec's [Reconciliation](../spec.md#reconciliation-client) entries have the exact comparison rules) before applying with `reconcile_packet`. Over a single ordered channel (a `RemoteEvent` per client), none of this is needed: apply in arrival order.
