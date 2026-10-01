--!native
--!optimize 2

-- duplecs delegation-lifecycle benchmark — deep InheritsPrivacy delegation across a group's whole lifecycle:
-- spawned, its export edited, and deleted. Each group is a Replicated gate entity with a wide own Private
-- filter (a blacklist naming only the EXCLUDED last players, so most players see the gate itself and joiners
-- are admitted) and a narrow ExportsPrivacy whitelist of the EXPORTED first players; its N members
-- (positioned members holding Position, Health, and Kind; counted members holding Kind and Count) sit under
-- it with a networked pair(ChildOf, group) for containment and pair(InheritsPrivacy, group) for visibility,
-- so they reach only the exported players. Position carries a static f64 serdes hook, Health and Count a
-- sizeless varint one, and Kind none, so the reliable value paths are all exercised (see
-- bench_generate_packets).
--
-- Every world also holds a background population of delegators: per-player inventory gates (an un-Replicated
-- gate per player whitelisting its owner, items inheriting from it) and container -> sub-container -> item
-- chains (a broadcast container, SUBS_PER_CONTAINER sub-containers inheriting from it with an ExportsPrivacy
-- filter -- empty for closed sub-containers, one player for the container's open sub-container -- and
-- ITEMS_PER_SUB items inheriting from each sub-container, every link also a ChildOf). Half of a background
-- count is inventory items, half container chains.
--
-- Two modes build the same per-client visibility, so their packets are byte-equal
-- (each row prints that match as its fairness check, like bench_privacy_inheritance):
--   delegated -- the shape above.
--   manual    -- no InheritsPrivacy or ExportsPrivacy anywhere: every member and item carries its own copy of
--     the filter its chain would derive (the exported whitelist, its owner's whitelist, its sub-container's
--     opener or the empty whitelist), and a visibility flip edits every member's filter in turn.
-- Server rows on the spawn/delete cycle also time a plain jecs twin with duplecs absent (a stand-in relation
-- with (OnDeleteTarget, Delete) in place of InheritsPrivacy, so the archetype work matches), and client rows
-- time applying the same changes to a plain world directly, so both sides read as ratios too.
--
-- Rows (server phases clocked separately: mutate = the mutations with duplecs's hooks live, generate = the
-- generate_packets call that follows):
--   spawn  -- (a) the gate and its N members spawned in one frame; client = an exported player reconciling
--     the frame's creations.
--   delete -- (d) world:delete(group) in one frame, the InheritsPrivacy and ChildOf cascades deleting every
--     member; client = an exported player reconciling N + 1 deletions in one batch. Spawn and delete
--     alternate in one loop, so every rep is one full group lifecycle.
--   admit  -- (b) a player who sees the gate but not its members being added to the export whitelist, a
--     whole-group visibility flip; client = that player reconciling N creations.
--   revoke -- the same player removed from the export again (N deletions client-side).
--   export -- (c) export edits on a populated group, per edit and per frame: toggle (FLAPPERS players on the
--     export boundary each flipping every frame, half admitted, half revoked), flap (each of them admitted
--     and revoked within one frame, a net-zero diff, so generate has nothing to ship and the edits are pure
--     restage cost), and own (one bystander's standing toggled in the group's own blacklist, which narrows
--     nothing the export doesn't already, so it fans out to no member -- the reference for what an edit costs
--     without the descendant restage).
--   join   -- (e) add_client plus the generate_packets that allocates the slot (re-deriving every delegator's
--     and exporter's gates, plus the per-filter grant loop) and builds the joiner's full packet, swept over
--     the background delegator count with one DEFAULT_N group also live; the joiner is in no export and opens
--     no sub-container, so their packet holds the group gates, containers, and sub-containers only.
--
-- Rows a-d sweep the group size at DEFAULT_P and the client count at DEFAULT_N, so the P=DEFAULT_P
-- N=DEFAULT_N row appears in both sweeps as a per-run noise gauge; they run against DEFAULT_BACKGROUND
-- background delegators. User ids are padded to fixed floors so a duplecs version changing its internal id
-- count (shifting every user id downstream) can't swing cross-commit comparisons through hash-order
-- artifacts, and every world replays an identical create/delete sequence, so recycled ids line up across
-- commits too.

local jecs = require("../../roblox_packages/jecs")
local pair = jecs.pair
local ChildOf = jecs.ChildOf

local duplecs = require("../../src")

local GROUP_SIZES = { 500, 1000, 2000 } -- N, at P = DEFAULT_P
local CLIENT_COUNTS = { 8, 32, 64 } -- P, at N = DEFAULT_N
local BACKGROUND_COUNTS = { 0, 1000, 5000, 10000 } -- join sweep, at P = DEFAULT_P and N = DEFAULT_N

local DEFAULT_P = 32
local DEFAULT_N = 1000
local DEFAULT_BACKGROUND = 1000 -- background delegators in the spawn/delete, admit/revoke, and export worlds

local FLAPPERS = 4 -- boundary players flipping their export standing per frame
local SUBS_PER_CONTAINER = 4
local ITEMS_PER_SUB = 24

local LIFECYCLE_REPS = 20
local FLIP_REPS = 20
local EDIT_REPS = 50
local JOIN_REPS = 20
local WARM = 3

-- fixed id floors (see the header): user components and entities always start
-- here no matter how many ids duplecs claims internally
local COMPONENT_FLOOR = 32
local ENTITY_FLOOR = 4096

-- ---- the two serdes shapes, shared with bench_generate_packets. every value
-- here is a non-negative integer, so the sizeless shape varints it.

local f64_serdes = {
	size = 8,
	encode = function(value: number)
		local encoded = buffer.create(8)
		buffer.writef64(encoded, 0, value)
		return encoded
	end,
	decode = function(encoded: buffer)
		return buffer.readf64(encoded, 0)
	end,
}

local varint_serdes = {
	encode = function(value: number)
		local size = 1
		local high = value // 0x80
		while high > 0 do
			size += 1
			high //= 0x80
		end
		local encoded = buffer.create(size)
		local rest = value
		for i = 1, size - 1 do
			buffer.writeu8(encoded, i - 1, bit32.bor(bit32.band(rest, 0x7f), 0x80))
			rest //= 0x80
		end
		buffer.writeu8(encoded, size - 1, rest)
		return encoded
	end,
	decode = function(encoded: buffer)
		local value = 0
		local scale = 1
		for offset = 0, buffer.len(encoded) - 1 do
			value += bit32.band(buffer.readu8(encoded, offset), 0x7f) * scale
			scale *= 0x80
		end
		return value
	end,
}

-- ---- guard: touch every returned map so the generate calls can't be
-- optimized away. untimed; belt-and-braces.

local guard = 0

local function drain(packets)
	local n = 0
	for _client in packets do
		n += 1
	end
	return n
end

-- wire bytes of one client's packet (buffer only); 0 when the client received
-- nothing this pass
local function bytes_of(packets, client)
	local packet = packets[client]
	if packet == nil then
		return 0
	end
	return buffer.len(packet.data)
end

local function check(condition, label)
	if not condition then
		error(`sanity check failed: {label}`)
	end
end

-- ---- worlds -------------------------------------------------------------------

local function pad_ids(world)
	while (world:component() :: any) < COMPONENT_FLOOR do
	end
	while (world:entity() :: any) < ENTITY_FLOOR do
	end
end

-- the shared definitions, created in the same order on every world so ids line
-- up; serdes hooks register through whichever half is passed (nil for a plain
-- world, which never decodes anything)
local function define(world, net)
	local defs = {
		Position = world:component(),
		Health = world:component(),
		Kind = world:component(),
		Count = world:component(),
	}
	if net ~= nil then
		world:set(defs.Position, net.Serdes, table.clone(f64_serdes))
		world:set(defs.Health, net.Serdes, table.clone(varint_serdes))
		world:set(defs.Count, net.Serdes, table.clone(varint_serdes))
	end
	return defs
end

-- a duplecs server world with P queued players (allocated by the caller's first flush, before any filter
-- lands) and the group filters derived from them: exported is the export whitelist, excluded the own
-- blacklist (see the header). the swept players are named by slot: the admittee is the first player seeing
-- only the gate, the flappers the FLAPPERS players from there on, and the bystander the next one (always
-- outside both exported and excluded, given P >= 8).
local function make_server(P)
	local world = jecs.World.new()
	local net = duplecs.server(world)
	pad_ids(world)

	local defs = define(world, net)
	world:add(defs.Position, net.Networked)
	world:add(defs.Health, net.Networked)
	world:add(defs.Kind, net.Networked)
	world:add(defs.Count, net.Networked)
	world:add(ChildOf, net.Networked)

	-- dummy player stand-ins; the module only uses them as table keys
	local players = table.create(P) :: { any }
	for i = 1, P do
		players[i] = {}
		net.add_client(players[i])
	end

	local exported_count = math.max(2, P // 8)
	local excluded_count = math.max(1, P // 8)
	local exported = {}
	for i = 1, exported_count do
		exported[players[i]] = true
	end
	local excluded = {}
	for i = P - excluded_count + 1, P do
		excluded[players[i]] = false
	end

	return {
		world = world,
		net = net,
		defs = defs,
		players = players,
		exported = table.freeze(exported),
		excluded = table.freeze(excluded),
		admittee = players[exported_count + 1],
		flapper_base = exported_count,
		bystander = players[exported_count + FLAPPERS + 1],
	}
end

-- a plain jecs world (duplecs absent entirely). with_stand_in adds the stand-in
-- delegation relation the server twins hang their members on; the client twins
-- (direct application) go without, matching what a client world receives.
local function make_plain(with_stand_in)
	local world = jecs.World.new()
	pad_ids(world)
	local defs = define(world, nil)
	local stand_in = nil
	if with_stand_in then
		stand_in = world:entity()
		world:add(stand_in, pair(jecs.OnDeleteTarget, jecs.Delete))
	end
	return { world = world, defs = defs, stand_in = stand_in }
end

-- one player's client world, every definition pre-mapped to its own local
-- component (with matching serdes hooks) and ChildOf to itself
local function create_viewer(server_defs, player)
	local world = jecs.World.new()
	local client = duplecs.client(world)
	pad_ids(world)
	local defs = define(world, client)
	for name, server_def in server_defs do
		client.set_client_entity(server_def, defs[name])
	end
	client.set_client_entity(ChildOf, ChildOf)
	return { world = world, client = client, player = player }
end

-- generate_packets plus the viewer's reconcile, untimed (setup and settling)
local function flush(net, viewer)
	local packets = net.generate_packets()
	guard += drain(packets)
	if viewer ~= nil then
		local packet = packets[viewer.player]
		if packet ~= nil then
			viewer.client.reconcile_packet(packet)
		end
	end
	return packets
end

-- ---- the background population (see the header): count delegators, half inventory items and half container
-- chains. in manual mode every item carries the filter its chain would derive and the gates carry none.
-- returns the number of delegators placed.

local function populate_background(s, mode, count)
	local world = s.world
	local net = s.net
	local defs = s.defs
	local players = s.players
	local P = #players
	local delegated = mode == "delegated"
	local placed = 0

	-- inventories: one un-Replicated gate per player whitelisting its owner
	local inventory_gates = table.create(P)
	local inventory_filters = table.create(P)
	for i = 1, P do
		local whitelist = table.freeze({ [players[i]] = true })
		local gate = world:entity()
		if delegated then
			world:set(gate, net.Private, whitelist)
		end
		inventory_gates[i] = gate
		inventory_filters[i] = whitelist
	end
	local item_count = count // 2
	for i = 1, item_count do
		local owner = (i - 1) % P + 1
		local item = world:entity()
		world:set(item, defs.Kind, i % 7)
		world:set(item, defs.Count, i % 20 + 1)
		if delegated then
			world:add(item, pair(net.InheritsPrivacy, inventory_gates[owner]))
		else
			world:set(item, net.Private, inventory_filters[owner])
		end
		world:add(item, net.Replicated)
		placed += 1
	end

	-- containers -> sub-containers -> items: the first sub-container of each container stands open for one
	-- player, the rest are closed (exporting the empty whitelist)
	local closed = table.freeze({})
	local container_count = (count - item_count) // (SUBS_PER_CONTAINER * (ITEMS_PER_SUB + 1))
	for j = 1, container_count do
		local container = world:entity()
		world:set(container, defs.Position, j * 10)
		world:add(container, net.Replicated)
		for c = 1, SUBS_PER_CONTAINER do
			local opener = closed
			if c == 1 then
				opener = table.freeze({ [players[(j - 1) % P + 1]] = true })
			end
			local sub = world:entity()
			world:set(sub, defs.Kind, 100 + c)
			world:add(sub, pair(ChildOf, container))
			if delegated then
				world:add(sub, pair(net.InheritsPrivacy, container))
				world:set(sub, net.ExportsPrivacy, opener)
				placed += 1
			end
			world:add(sub, net.Replicated)
			for k = 1, ITEMS_PER_SUB do
				local item = world:entity()
				world:set(item, defs.Kind, k % 7)
				world:set(item, defs.Count, k)
				world:add(item, pair(ChildOf, sub))
				if delegated then
					world:add(item, pair(net.InheritsPrivacy, sub))
				else
					world:set(item, net.Private, opener)
				end
				world:add(item, net.Replicated)
				placed += 1
			end
		end
	end

	return placed
end

-- ---- groups -------------------------------------------------------------------

-- the gate: Replicated with the wide own blacklist, plus the narrow export in
-- delegated mode (manual members carry the exported whitelist themselves). plain
-- worlds get a bare entity.
local function create_gate(ctx, mode, tick)
	local world = ctx.world
	local net = ctx.net
	local group = world:entity()
	world:set(group, ctx.defs.Position, tick)
	if net ~= nil then
		world:set(group, net.Private, ctx.excluded)
		if mode == "delegated" then
			world:set(group, net.ExportsPrivacy, ctx.exported)
		end
		world:add(group, net.Replicated)
	end
	return group
end

-- size members under the gate, one third counted and two thirds positioned, in the order a spawner would
-- write them: data first, containment, delegation (or the manual filter), then Replicated last. fills
-- members.
local function spawn_members(ctx, mode, group, size, tick, members)
	local world = ctx.world
	local net = ctx.net
	local defs = ctx.defs
	local stand_in = ctx.stand_in
	for i = 1, size do
		local entity = world:entity()
		if i % 3 == 0 then
			world:set(entity, defs.Kind, i % 7)
			world:set(entity, defs.Count, i % 20 + tick)
		else
			world:set(entity, defs.Position, i + tick)
			world:set(entity, defs.Health, i % 100 + tick)
			world:set(entity, defs.Kind, i % 7)
		end
		world:add(entity, pair(ChildOf, group))
		if mode == "delegated" then
			world:add(entity, pair(net.InheritsPrivacy, group))
		elseif mode == "manual" then
			world:set(entity, net.Private, ctx.exported)
		elseif stand_in ~= nil then
			world:add(entity, pair(stand_in, group))
		end
		if net ~= nil then
			world:add(entity, net.Replicated)
		end
		members[i] = entity
	end
end

local function spawn_group(ctx, mode, size, tick, members)
	local group = create_gate(ctx, mode, tick)
	spawn_members(ctx, mode, group, size, tick, members)
	return group
end

-- ---- spawn + delete (rows a and d) ------------------------------------------------

local function run_lifecycle(P, size)
	local reps = LIFECYCLE_REPS
	local members = table.create(size)

	-- plain twins: the server twin spawns and deletes with the stand-in relation, the
	-- client twin (direct application) without it
	local plain_server = make_plain(true)
	local plain_client = make_plain(false)
	local plain_spawn, plain_delete, direct_spawn, direct_delete = 0, 0, 0, 0
	for rep = 1, WARM + reps do
		local t0 = os.clock()
		local group = spawn_group(plain_server, "plain", size, rep, members)
		local t1 = os.clock()
		plain_server.world:delete(group)
		local t2 = os.clock()
		local direct_group = spawn_group(plain_client, "plain", size, rep, members)
		local t3 = os.clock()
		plain_client.world:delete(direct_group)
		local t4 = os.clock()
		if rep > WARM then
			plain_spawn += t1 - t0
			plain_delete += t2 - t1
			direct_spawn += t3 - t2
			direct_delete += t4 - t3
		end
	end

	-- the duplecs modes, an exported player (players[1], in the export) reconciling
	-- every frame
	local results = {}
	for _, mode in { "manual", "delegated" } do
		local s = make_server(P)
		local viewer = create_viewer(s.defs, s.players[1])
		flush(s.net, viewer)
		populate_background(s, mode, DEFAULT_BACKGROUND)
		flush(s.net, viewer)

		local generate_packets = s.net.generate_packets
		local reconcile_packet = viewer.client.reconcile_packet
		local r = {
			spawn_mutate = 0,
			spawn_generate = 0,
			spawn_client = 0,
			spawn_bytes = 0,
			delete_mutate = 0,
			delete_generate = 0,
			delete_client = 0,
			delete_bytes = 0,
		}
		for rep = 1, WARM + reps do
			local t0 = os.clock()
			local group = spawn_group(s, mode, size, rep, members)
			local t1 = os.clock()
			local packets = generate_packets()
			local t2 = os.clock()
			reconcile_packet(packets[viewer.player])
			local t3 = os.clock()
			guard += drain(packets)
			check(viewer.client.get_client_entity(members[size]) ~= nil, "spawn: the exported player holds the members")
			local spawn_bytes = bytes_of(packets, viewer.player)

			local t4 = os.clock()
			s.world:delete(group)
			local t5 = os.clock()
			packets = generate_packets()
			local t6 = os.clock()
			reconcile_packet(packets[viewer.player])
			local t7 = os.clock()
			guard += drain(packets)
			check(
				viewer.client.get_client_entity(members[size]) == nil,
				"delete: the exported player dropped the members"
			)

			if rep > WARM then
				r.spawn_mutate += t1 - t0
				r.spawn_generate += t2 - t1
				r.spawn_client += t3 - t2
				r.spawn_bytes = spawn_bytes
				r.delete_mutate += t5 - t4
				r.delete_generate += t6 - t5
				r.delete_client += t7 - t6
				r.delete_bytes = bytes_of(packets, viewer.player)
			end
		end
		results[mode] = r
	end

	local scale = 1000 / reps
	local manual = results.manual
	local delegated = results.delegated
	local spawn_total = delegated.spawn_mutate + delegated.spawn_generate
	local delete_total = delegated.delete_mutate + delegated.delete_generate
	print(
		string.format(
			"spawn  N=%5d P=%3d | plain %7.3f | manual %7.3f + %7.3f | delegated %7.3f + %7.3f = %7.3f ms (x%5.2f)"
				.. " | client %7.3f ms (direct %7.3f, x%5.2f) | %6d B %s",
			size,
			P,
			plain_spawn * scale,
			manual.spawn_mutate * scale,
			manual.spawn_generate * scale,
			delegated.spawn_mutate * scale,
			delegated.spawn_generate * scale,
			spawn_total * scale,
			spawn_total / plain_spawn,
			delegated.spawn_client * scale,
			direct_spawn * scale,
			delegated.spawn_client / direct_spawn,
			delegated.spawn_bytes,
			if manual.spawn_bytes == delegated.spawn_bytes then "ok" else "MISMATCH"
		)
	)
	print(
		string.format(
			"delete N=%5d P=%3d | plain %7.3f | manual %7.3f + %7.3f | delegated %7.3f + %7.3f = %7.3f ms (x%5.2f)"
				.. " | client %7.3f ms (direct %7.3f, x%5.2f) | %6d B %s",
			size,
			P,
			plain_delete * scale,
			manual.delete_mutate * scale,
			manual.delete_generate * scale,
			delegated.delete_mutate * scale,
			delegated.delete_generate * scale,
			delete_total * scale,
			delete_total / plain_delete,
			delegated.delete_client * scale,
			direct_delete * scale,
			delegated.delete_client / direct_delete,
			delegated.delete_bytes,
			if manual.delete_bytes == delegated.delete_bytes then "ok" else "MISMATCH"
		)
	)
end

-- ---- admit + revoke (row b) -------------------------------------------------------

local function run_flip(P, size)
	local reps = FLIP_REPS

	-- the direct twin: one group's members deleted individually (what a revoke
	-- applies client-side) and spawned back under the standing gate (an admit)
	local direct = make_plain(false)
	local direct_members = table.create(size)
	local direct_group = spawn_group(direct, "plain", size, 0, direct_members)
	local direct_admit, direct_revoke = 0, 0
	for rep = 1, WARM + reps do
		local t0 = os.clock()
		for i = 1, size do
			direct.world:delete(direct_members[i])
		end
		local t1 = os.clock()
		spawn_members(direct, "plain", direct_group, size, rep, direct_members)
		local t2 = os.clock()
		if rep > WARM then
			direct_revoke += t1 - t0
			direct_admit += t2 - t1
		end
	end

	local results = {}
	for _, mode in { "manual", "delegated" } do
		local s = make_server(P)
		local net = s.net
		local admittee = s.admittee
		local viewer = create_viewer(s.defs, admittee)
		flush(net, viewer)
		populate_background(s, mode, DEFAULT_BACKGROUND)
		local members = table.create(size)
		local group = spawn_group(s, mode, size, 0, members)
		flush(net, viewer)
		check(viewer.client.get_client_entity(group) ~= nil, "flip: the admittee sees the gate")

		local function set_admitted(allowed)
			if mode == "delegated" then
				net.edit_exported_privacy(group, admittee, allowed)
			else
				for i = 1, size do
					net.edit_entity_privacy(members[i], admittee, allowed)
				end
			end
		end

		local generate_packets = net.generate_packets
		local reconcile_packet = viewer.client.reconcile_packet
		local r = {
			admit_mutate = 0,
			admit_generate = 0,
			admit_client = 0,
			admit_bytes = 0,
			revoke_mutate = 0,
			revoke_generate = 0,
			revoke_client = 0,
			revoke_bytes = 0,
		}
		for rep = 1, WARM + reps do
			local t0 = os.clock()
			set_admitted(true)
			local t1 = os.clock()
			local packets = generate_packets()
			local t2 = os.clock()
			reconcile_packet(packets[admittee])
			local t3 = os.clock()
			guard += drain(packets)
			check(viewer.client.get_client_entity(members[size]) ~= nil, "admit: the admittee holds the members")
			local admit_bytes = bytes_of(packets, admittee)

			local t4 = os.clock()
			set_admitted(false)
			local t5 = os.clock()
			packets = generate_packets()
			local t6 = os.clock()
			reconcile_packet(packets[admittee])
			local t7 = os.clock()
			guard += drain(packets)
			check(viewer.client.get_client_entity(members[size]) == nil, "revoke: the admittee dropped the members")

			if rep > WARM then
				r.admit_mutate += t1 - t0
				r.admit_generate += t2 - t1
				r.admit_client += t3 - t2
				r.admit_bytes = admit_bytes
				r.revoke_mutate += t5 - t4
				r.revoke_generate += t6 - t5
				r.revoke_client += t7 - t6
				r.revoke_bytes = bytes_of(packets, admittee)
			end
		end
		results[mode] = r
	end

	local scale = 1000 / reps
	local manual = results.manual
	local delegated = results.delegated
	print(
		string.format(
			"admit  N=%5d P=%3d | manual %7.3f + %7.3f = %7.3f | delegated %7.3f + %7.3f = %7.3f ms"
				.. " | client %7.3f ms (direct %7.3f, x%5.2f) | %6d B %s",
			size,
			P,
			manual.admit_mutate * scale,
			manual.admit_generate * scale,
			(manual.admit_mutate + manual.admit_generate) * scale,
			delegated.admit_mutate * scale,
			delegated.admit_generate * scale,
			(delegated.admit_mutate + delegated.admit_generate) * scale,
			delegated.admit_client * scale,
			direct_admit * scale,
			delegated.admit_client / direct_admit,
			delegated.admit_bytes,
			if manual.admit_bytes == delegated.admit_bytes then "ok" else "MISMATCH"
		)
	)
	print(
		string.format(
			"revoke N=%5d P=%3d | manual %7.3f + %7.3f = %7.3f | delegated %7.3f + %7.3f = %7.3f ms"
				.. " | client %7.3f ms (direct %7.3f, x%5.2f) | %6d B %s",
			size,
			P,
			manual.revoke_mutate * scale,
			manual.revoke_generate * scale,
			(manual.revoke_mutate + manual.revoke_generate) * scale,
			delegated.revoke_mutate * scale,
			delegated.revoke_generate * scale,
			(delegated.revoke_mutate + delegated.revoke_generate) * scale,
			delegated.revoke_client * scale,
			direct_revoke * scale,
			delegated.revoke_client / direct_revoke,
			delegated.revoke_bytes,
			if manual.revoke_bytes == delegated.revoke_bytes then "ok" else "MISMATCH"
		)
	)
end

-- ---- export edits (row c) ---------------------------------------------------------

-- times frames of edit() plus generate_packets on one settled delegated world;
-- returns mutate ms per edit and generate ms per frame
local function measure_edits(net, edits_per_frame, edit)
	local generate_packets = net.generate_packets
	for frame = 1, WARM do
		edit(frame)
		guard += drain(generate_packets())
	end
	local mutate_elapsed = 0
	local generate_elapsed = 0
	for frame = WARM + 1, WARM + EDIT_REPS do
		local t0 = os.clock()
		edit(frame)
		local t1 = os.clock()
		local packets = generate_packets()
		generate_elapsed += os.clock() - t1
		mutate_elapsed += t1 - t0
		guard += drain(packets)
	end
	return 1000 * mutate_elapsed / (EDIT_REPS * edits_per_frame), 1000 * generate_elapsed / EDIT_REPS
end

local function run_export_edits(P, size)
	local s = make_server(P)
	local net = s.net
	flush(net, nil)
	populate_background(s, "delegated", DEFAULT_BACKGROUND)
	local members = table.create(size)
	local group = spawn_group(s, "delegated", size, 0, members)
	flush(net, nil)

	local players = s.players
	local base = s.flapper_base

	-- toggle: flapper k is admitted on frames of k's parity and revoked on the others,
	-- so after the first frame every flapper flips every frame, half each way
	local toggle_edit, toggle_generate = measure_edits(net, FLAPPERS, function(frame)
		for k = 1, FLAPPERS do
			net.edit_exported_privacy(group, players[base + k], (frame + k) % 2 == 0)
		end
	end)

	-- flap: every flapper is admitted and revoked within the frame, starting from outside
	for k = 1, FLAPPERS do
		net.edit_exported_privacy(group, players[base + k], false)
	end
	flush(net, nil)
	local flap_edit, flap_generate = measure_edits(net, FLAPPERS * 2, function()
		for k = 1, FLAPPERS do
			net.edit_exported_privacy(group, players[base + k], true)
			net.edit_exported_privacy(group, players[base + k], false)
		end
	end)

	-- own: the bystander's standing in the group's own blacklist flips each
	-- frame; the bystander is outside the export, so no member's gate moves
	local bystander = s.bystander
	local own_edit, own_generate = measure_edits(net, 1, function(frame)
		net.edit_entity_privacy(group, bystander, frame % 2 == 0)
	end)

	print(
		string.format(
			"export N=%5d P=%3d | toggle %7.4f ms/edit + %7.4f ms/frame | flap %7.4f ms/edit + %7.4f ms/frame"
				.. " | own %7.4f ms/edit + %7.4f ms/frame",
			size,
			P,
			toggle_edit,
			toggle_generate,
			flap_edit,
			flap_generate,
			own_edit,
			own_generate
		)
	)
end

-- ---- join (row e) -------------------------------------------------------------------

local function run_join(background)
	local results = {}
	for _, mode in { "manual", "delegated" } do
		local s = make_server(DEFAULT_P)
		local net = s.net
		flush(net, nil)
		local placed = populate_background(s, mode, background)
		local members = table.create(DEFAULT_N)
		spawn_group(s, mode, DEFAULT_N, 0, members)
		flush(net, nil)

		local add_elapsed = 0
		local generate_elapsed = 0
		local bytes = 0
		for rep = 1, WARM + JOIN_REPS do
			local joiner = {}
			local t0 = os.clock()
			net.add_client(joiner)
			local t1 = os.clock()
			local packets = net.generate_packets()
			local t2 = os.clock()
			guard += drain(packets)
			bytes = bytes_of(packets, joiner)
			net.remove_client(joiner)
			flush(net, nil)
			if rep > WARM then
				add_elapsed += t1 - t0
				generate_elapsed += t2 - t1
			end
		end
		results[mode] = {
			placed = placed,
			add = add_elapsed,
			generate = generate_elapsed,
			bytes = bytes,
		}
	end

	local scale = 1000 / JOIN_REPS
	local manual = results.manual
	local delegated = results.delegated
	local manual_total = manual.add + manual.generate
	local delegated_total = delegated.add + delegated.generate
	print(
		string.format(
			"join   B=%5d delegators=%5d P=%3d | manual %7.4f + %7.4f = %7.4f | delegated %7.4f + %7.4f = %7.4f ms (x%5.2f)"
				.. " | %6d B %s",
			background,
			delegated.placed + DEFAULT_N,
			DEFAULT_P,
			manual.add * scale,
			manual.generate * scale,
			manual_total * scale,
			delegated.add * scale,
			delegated.generate * scale,
			delegated_total * scale,
			delegated_total / manual_total,
			delegated.bytes,
			if manual.bytes == delegated.bytes then "ok" else "MISMATCH"
		)
	)
end

-- ---- run ------------------------------------------------------------------------------

print(
	string.format(
		"duplecs delegation lifecycle  background=%d delegators  flappers=%d  subs/container=%d  items/sub=%d"
			.. "  reps: lifecycle=%d flip=%d edits=%d join=%d",
		DEFAULT_BACKGROUND,
		FLAPPERS,
		SUBS_PER_CONTAINER,
		ITEMS_PER_SUB,
		LIFECYCLE_REPS,
		FLIP_REPS,
		EDIT_REPS,
		JOIN_REPS
	)
)
print("server columns are mutate + generate ms per group/flip; client = the receiving player's")
print("reconcile against applying the same changes to a plain world directly. x = delegated vs plain.")
print("")

print(string.format("spawn + delete, group-size sweep (P=%d):", DEFAULT_P))
for _, size in GROUP_SIZES do
	run_lifecycle(DEFAULT_P, size)
end
print("")

print(string.format("spawn + delete, client sweep (N=%d):", DEFAULT_N))
for _, P in CLIENT_COUNTS do
	run_lifecycle(P, DEFAULT_N)
end
print("")

print(string.format("admit + revoke, group-size sweep (P=%d):", DEFAULT_P))
for _, size in GROUP_SIZES do
	run_flip(DEFAULT_P, size)
end
print("")

print(string.format("admit + revoke, client sweep (N=%d):", DEFAULT_N))
for _, P in CLIENT_COUNTS do
	run_flip(P, DEFAULT_N)
end
print("")

print(string.format("export edits, group-size sweep (P=%d):", DEFAULT_P))
for _, size in GROUP_SIZES do
	run_export_edits(DEFAULT_P, size)
end
print("")

print(string.format("export edits, client sweep (N=%d):", DEFAULT_N))
for _, P in CLIENT_COUNTS do
	run_export_edits(P, DEFAULT_N)
end
print("")

print(string.format("join, background sweep (P=%d, one N=%d group live):", DEFAULT_P, DEFAULT_N))
for _, background in BACKGROUND_COUNTS do
	run_join(background)
end
print("")

print("guard:", guard)

return true
