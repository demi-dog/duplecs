--!native
--!optimize 2

-- duplecs end-to-end overhead benchmark — the paired source of the numbers in
-- docs/guides/012-performance.md. Every server row runs one mutation workload
-- twice: on a plain jecs world with duplecs absent entirely (baseline; the
-- mutations alone are timed) and on a duplecs server world (the mutations
-- plus the same frame's generate_packets — or generate_unreliable_chunks —
-- timed together), printing both times and the ratio. The ratio answers "how
-- much more does this operation cost end-to-end once it replicates than it
-- does on a world that isn't networked at all", amortized per op at the row's
-- stated ops/frame — generate_packets has a per-frame floor besides its
-- marginal per-change cost, so the ratios only hold near these batch sizes
-- (the floor section measures the fixed part alone). Every server row also
-- prints a mutate/generate split of the same timed frames: `mutate` is the
-- workload's mutations with duplecs's hooks live (mutate minus plain ~ the
-- per-op staging cost) and `generate` is the packet pass, so a row says not
-- just how much overhead replication adds but which phase it lives in. The
-- joiner row splits the same way into add_client and generate_packets.
--
-- Sections:
--   canonical      — the headline rows at P=32 (one full shard), broadcast
--     visibility, hookless values: value sets under each tracking mode,
--     component/tag toggles, pair sets and retargets, spawn+despawn. Each row
--     re-measures its own plain twin, so the plain column doubles as a
--     per-run noise gauge.
--   clients        — the value-set and spawn+despawn rows swept across client
--     counts, against one shared plain baseline per sweep.
--   fragmentation  — value churn under per-cell whitelists drawn from an
--     F-mask pool (F distinct visibility nodes — the fragmentation axis),
--     then a fan-out sweep (mask size j at pinned F), same shared-baseline
--     arrangement.
--   floor          — a settled world's generate_packets alone: the per-frame
--     fixed cost with nothing staged, per client count.
--   joiner         — one client's full packet built from a populated world
--     (absolute ms/join; joining has no plain-jecs analog, so no ratio).
--   client         — reconcile_packet/reconcile_chunk timed against applying
--     the same changes to a plain world directly with world:set and friends;
--     the server side of each link runs untimed.
--
-- To refresh the guide after a change: run this bench and re-round the
-- guide's tables from its output (the guide states the workload shapes, which
-- must move with this file's constants if they change). No serdes hooks
-- except where the unreliable channel requires them, so reliable values ride
-- the side array. User ids are padded to fixed floors so a duplecs version
-- changing its internal id count (shifting every user id downstream) can't
-- swing cross-commit comparisons through hash-order artifacts.

local jecs = require("../../roblox_packages/jecs")
local pair = jecs.pair

local duplecs = require("../../src")

local CELLS = 1024 -- value-churn cells (one set each per frame)
local TOGGLES = 512 -- toggled entities (one remove+add cycle each per frame)
local PAIR_CELLS = 512 -- pair-holding subjects (one pair set each per frame)
local SPAWN_RING = 256 -- ring of short-lived entities
local SPAWNS = 128 -- delete+respawn cycles per frame
local FULL_BASE = 1024 -- joiner-world entities (shape mirrors bench_reconcile_packet's full)
local FULL_PAIRS = 256 -- joiner-world pair cells
local CHURN_LIVE = 1024 -- client-section churn ring size
local CHURN_PER_FRAME = 128 -- client-section delete+respawn cycles per frame

local DEFAULT_P = 32 -- exactly one full shard
local CLIENT_COUNTS = { 8, 32, 128 }
local FRAG_P = 64 -- the fragmentation and fan-out sweeps' client count
local MASK_COUNTS = { 1, 4, 16, 64, 256 } -- F sweep at j = FRAG_P / 4
local VIEWER_COUNTS = { 2, 16, 48 } -- j sweep at F = 16

local REPS = 200
local WARM = 20
local FULL_REPS = 100

-- fixed id floors (see the header): user components and entities always start
-- here no matter how many ids duplecs claims internally
local COMPONENT_FLOOR = 32
local ENTITY_FLOOR = 4096

-- the one serdes shape in the file, required by the unreliable channel
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

-- ---- distinct mask generation: `count` unique random j-subsets of P player
-- indices (0-based), deduped by their numeric bitmask. Identical to
-- bench_whitelist_overlap; C(P, j) stays well above every swept count, so the
-- retry loop is effectively free.

local function generate_masks(count, j, P)
	math.randomseed(1337)
	local masks = table.create(count)
	local seen = {}
	while #masks < count do
		local deck = table.create(P)
		for i = 1, P do
			deck[i] = i - 1
		end
		local key = 0
		local indices = table.create(j)
		for k = 1, j do
			local pick = math.random(k, P)
			deck[k], deck[pick] = deck[pick], deck[k]
			indices[k] = deck[k]
			key += 2 ^ deck[k]
		end
		if seen[key] == nil then
			seen[key] = true
			table.insert(masks, indices)
		end
	end
	return masks
end

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

-- ---- world construction: P = nil builds the plain twin (no duplecs contact
-- at all), a number builds a duplecs server world with P allocated clients.
-- Both sides pad user ids to the fixed floors.

local function make_world(P)
	local world = jecs.World.new()
	local net = nil
	if P ~= nil then
		net = duplecs.server(world)
	end

	while (world:component() :: any) < COMPONENT_FLOOR do
	end
	while (world:entity() :: any) < ENTITY_FLOOR do
	end

	local players = nil
	if net ~= nil then
		players = table.create(P) :: { any }
		for i = 1, P do
			players[i] = {}
			net.add_client(players[i])
		end
		net.generate_packets()
	end

	return world, net, players
end

-- ---- timing shell: WARM then REPS frames of mutate plus the generate call
-- when one is given. The drain runs outside the timed region. The two phases
-- of each frame are clocked separately so every row can report where its
-- overhead lives: `mutate` is the workload's mutations with duplecs's hooks
-- live (so mutate minus the plain column is the per-op staging cost) and
-- `generate` is the packet pass. Returns total, mutate, and generate
-- nanoseconds per op.

local function measure(mutate, generate, ops)
	for _ = 1, WARM do
		mutate()
		if generate ~= nil then
			guard += drain(generate())
		end
	end

	local mutate_elapsed = 0
	local generate_elapsed = 0
	for _ = 1, REPS do
		local t = os.clock()
		mutate()
		local mid = os.clock()
		mutate_elapsed += mid - t
		if generate ~= nil then
			local packets = generate()
			generate_elapsed += os.clock() - mid
			guard += drain(packets)
		end
	end

	local scale = 1e9 / (REPS * ops)
	return (mutate_elapsed + generate_elapsed) * scale, mutate_elapsed * scale, generate_elapsed * scale
end

local function row(label, P, plain_ns, duplecs_ns, mutate_ns, generate_ns)
	print(
		string.format(
			"%-44s P=%3d | plain %8.1f ns/op | duplecs %8.1f ns/op | x%5.2f | mutate %8.1f + generate %8.1f",
			label,
			P,
			plain_ns,
			duplecs_ns,
			duplecs_ns / plain_ns,
			mutate_ns,
			generate_ns
		)
	)
end

-- ---- scenario setups: each builds its workload into `world` (skipping every
-- duplecs touch when net is nil — the plain twin) and returns the per-frame
-- mutate closure. Workload shapes mirror bench_hooks.

-- value churn: CELLS entities, one data component each, every cell set fresh
-- per frame. mode picks the duplecs side's tracking tag; the unreliable mode
-- registers the serdes hooks the channel requires.
local function setup_value_churn(world, net, mode)
	local component = world:component()
	if net ~= nil then
		if mode == "once" then
			world:add(component, net.NetworkedOnce)
		elseif mode == "unreliable" then
			world:set(component, net.Serdes, table.clone(f64_serdes))
			world:add(component, net.NetworkedUnreliable)
		else
			world:add(component, net.Networked)
		end
	end

	local entities = table.create(CELLS)
	for i = 1, CELLS do
		local entity = world:entity()
		world:set(entity, component, i)
		if net ~= nil then
			world:add(entity, net.Replicated)
		end
		entities[i] = entity
	end

	local tick = 0
	local function churn()
		tick += 1
		for i = 1, CELLS do
			world:set(entities[i], component, i + tick)
		end
	end

	return churn, entities, component
end

-- pair value churn: PAIR_CELLS subjects each holding one data pair on a
-- shared target, every pair set fresh per frame
local function setup_pair_churn(world, net)
	local relation = world:component()
	local target = world:entity()
	if net ~= nil then
		world:add(relation, net.Networked)
		world:add(target, net.Replicated)
	end

	local subjects = table.create(PAIR_CELLS)
	for i = 1, PAIR_CELLS do
		local subject = world:entity()
		world:set(subject, pair(relation, target), i)
		if net ~= nil then
			world:add(subject, net.Replicated)
		end
		subjects[i] = subject
	end

	local tick = 0
	local function churn()
		tick += 1
		for i = 1, PAIR_CELLS do
			world:set(subjects[i], pair(relation, target), i + tick)
		end
	end

	return churn
end

-- component toggles: TOGGLES entities; each op removes the component and sets
-- (or, for tags, adds) it back — two archetype moves per op
local function setup_toggle(world, net, tag_definition)
	local component
	if tag_definition then
		component = world:entity()
	else
		component = world:component()
	end
	if net ~= nil then
		world:add(component, net.Networked)
	end

	local entities = table.create(TOGGLES)
	for i = 1, TOGGLES do
		local entity = world:entity()
		if tag_definition then
			world:add(entity, component)
		else
			world:set(entity, component, i)
		end
		if net ~= nil then
			world:add(entity, net.Replicated)
		end
		entities[i] = entity
	end

	local tick = 0
	local function toggle()
		tick += 1
		if tag_definition then
			for i = 1, TOGGLES do
				world:remove(entities[i], component)
				world:add(entities[i], component)
			end
		else
			for i = 1, TOGGLES do
				world:remove(entities[i], component)
				world:set(entities[i], component, i + tick)
			end
		end
	end

	return toggle
end

-- pair retargets: TOGGLES subjects alternating between two targets; each op
-- removes pair(relation, old) and sets pair(relation, new)
local function setup_retarget(world, net)
	local relation = world:component()
	local targets = { world:entity(), world:entity() }
	if net ~= nil then
		world:add(relation, net.Networked)
		world:add(targets[1], net.Replicated)
		world:add(targets[2], net.Replicated)
	end

	local subjects = table.create(TOGGLES)
	local assigned = table.create(TOGGLES)
	for i = 1, TOGGLES do
		local subject = world:entity()
		local target_index = (i - 1) % 2 + 1
		world:set(subject, pair(relation, targets[target_index]), i)
		if net ~= nil then
			world:add(subject, net.Replicated)
		end
		subjects[i] = subject
		assigned[i] = target_index
	end

	local tick = 0
	local function rotate()
		tick += 1
		for i = 1, TOGGLES do
			local old_index = assigned[i]
			local new_index = old_index % 2 + 1
			world:remove(subjects[i], pair(relation, targets[old_index]))
			world:set(subjects[i], pair(relation, targets[new_index]), i + tick)
			assigned[i] = new_index
		end
	end

	return rotate
end

-- spawn+despawn: a ring of short-lived entities each holding two data
-- components; every op deletes the oldest slot and respawns it (recycled ids)
local function setup_spawn_despawn(world, net)
	local component_a = world:component()
	local component_b = world:component()
	if net ~= nil then
		world:add(component_a, net.Networked)
		world:add(component_b, net.Networked)
	end

	local tick = 0
	local ring = table.create(SPAWN_RING)
	local function spawn(slot)
		tick += 1
		local entity = world:entity()
		world:set(entity, component_a, tick)
		world:set(entity, component_b, tick * 2)
		if net ~= nil then
			world:add(entity, net.Replicated)
		end
		ring[slot] = entity
	end
	for slot = 1, SPAWN_RING do
		spawn(slot)
	end

	local slot_cursor = 0
	local function churn()
		for _ = 1, SPAWNS do
			slot_cursor = slot_cursor % SPAWN_RING + 1
			world:delete(ring[slot_cursor])
			spawn(slot_cursor)
		end
	end

	return churn
end

-- ---- server rows ------------------------------------------------------------

-- measures one setup's plain twin, ready for the duplecs side of a row (or a
-- sweep of them) to compare against
local function measure_plain(setup, ops, ...)
	local world = make_world(nil)
	local mutate = setup(world, nil, ...)
	return measure(mutate, nil, ops)
end

-- one self-contained row: the plain twin, then the duplecs side with the
-- membership flushed so the timed frames diff a settled world
local function run_server_row(label, P, setup, ops, ...)
	local plain_ns = measure_plain(setup, ops, ...)

	local world, net = make_world(P)
	local mutate = setup(world, net, ...)
	net.generate_packets()

	row(label, P, plain_ns, measure(mutate, net.generate_packets, ops))
end

-- the value-set row under each tracking mode, sharing one plain twin (the
-- plain workload is identical across modes). The unreliable mode times
-- generate_unreliable_chunks instead — its values never ride the reliable
-- deltas, and the settle call has already synced membership.
local function run_value_row(label, P, mode, plain_ns)
	local world, net = make_world(P)
	local mutate = setup_value_churn(world, net, mode)
	net.generate_packets()

	local generate
	if mode == "unreliable" then
		generate = net.generate_unreliable_chunks
	else
		generate = net.generate_packets
	end

	row(label, P, plain_ns, measure(mutate, generate, CELLS))
end

-- fragmentation: the Networked value-churn row with a per-cell component
-- whitelist drawn round-robin from a pool of F distinct j-sized masks, so F
-- sweeps visibility-node count and j sweeps fan-out
local function run_fragmented_row(F, j, plain_ns)
	local world, net, players = make_world(FRAG_P)
	local mutate, entities, component = setup_value_churn(world, net, "networked")
	net.generate_packets()

	local masks = generate_masks(F, j, FRAG_P)
	for i = 1, CELLS do
		local indices = masks[(i - 1) % F + 1]
		local whitelist = {}
		for _, index in indices do
			whitelist[players[index + 1]] = true
		end
		world:set(entities[i], pair(net.Private, component), whitelist)
	end
	net.generate_packets()

	local label = string.format("set: Networked, F=%3d masks of j=%2d", F, j)
	row(label, FRAG_P, plain_ns, measure(mutate, net.generate_packets, CELLS))
end

-- floor: a fully settled world's generate_packets with nothing staged — the
-- per-frame fixed cost that every ratio above amortizes over its ops
local function run_floor_row(P)
	local world, net = make_world(P)
	local mutate = setup_value_churn(world, net, "networked")
	mutate()
	net.generate_packets()

	local noop = function() end
	local ns = measure(noop, net.generate_packets, 1)
	print(string.format("settled generate_packets                     P=%3d | %8.2f us/frame", P, ns / 1e3))
end

-- joiner: one client's full packet from a populated world — add_client plus
-- the generate_packets that allocates the slot and builds the snapshot, with
-- the departure untimed so the world holds one client at a time
local function run_joiner_row()
	local world, net = make_world(0)

	local components = table.create(4)
	for c = 1, 4 do
		local component = world:component()
		world:add(component, net.Networked)
		components[c] = component
	end
	local tag = world:entity()
	world:add(tag, net.Networked)
	local relation = world:component()
	world:add(relation, net.Networked)

	local entities = table.create(FULL_BASE)
	for i = 1, FULL_BASE do
		local entity = world:entity()
		world:add(entity, net.Replicated)
		world:set(entity, components[(i - 1) % 4 + 1], i)
		if i % 4 == 0 then
			world:add(entity, tag)
		end
		entities[i] = entity
	end
	for i = 1, FULL_PAIRS do
		world:set(entities[FULL_PAIRS + i], pair(relation, entities[i]), i * 3)
	end
	net.generate_packets()

	local add_elapsed = 0
	local generate_elapsed = 0
	local bytes = 0
	for _ = 1, FULL_REPS do
		local viewer = {}
		local t = os.clock()
		net.add_client(viewer)
		local mid = os.clock()
		local packets = net.generate_packets()
		generate_elapsed += os.clock() - mid
		add_elapsed += mid - t
		bytes = buffer.len(packets[viewer].data)
		net.remove_client(viewer)
		net.generate_packets()
	end

	local cells = FULL_BASE + FULL_BASE // 4 + FULL_PAIRS
	print(
		string.format(
			"full packet: %4d entities, %4d cells        | %8.4f ms/join | %6d B | add_client %.4f + generate %.4f",
			FULL_BASE,
			cells,
			1000 * (add_elapsed + generate_elapsed) / FULL_REPS,
			bytes,
			1000 * add_elapsed / FULL_REPS,
			1000 * generate_elapsed / FULL_REPS
		)
	)
end

-- ---- client section ----------------------------------------------------------

-- one server/client pairing plus the plain twin world the direct-application
-- baseline mutates; the viewer stand-in is only ever a table key
local function make_link()
	local server_world, server = make_world(0)
	local viewer = {}
	server.add_client(viewer)

	local client_world = jecs.World.new()
	local client = duplecs.client(client_world)
	while (client_world:component() :: any) < COMPONENT_FLOOR do
	end
	while (client_world:entity() :: any) < ENTITY_FLOOR do
	end

	local plain_world = make_world(nil)

	return {
		server_world = server_world,
		server = server,
		client_world = client_world,
		client = client,
		plain_world = plain_world,
		viewer = viewer,
	}
end

-- a networked data component on the server world, pre-mapped to a fresh
-- client-side component so its sections resolve locally, plus the plain
-- twin's own component
local function map_component(link)
	local server_component = link.server_world:component()
	link.server_world:add(server_component, link.server.Networked)
	local client_component = link.client_world:component()
	link.client.set_client_entity(server_component, client_component)
	local plain_component = link.plain_world:component()
	return server_component, client_component, plain_component
end

-- same for a valueless tag
local function map_tag(link)
	local server_tag = link.server_world:entity()
	link.server_world:add(server_tag, link.server.Networked)
	local client_tag = link.client_world:entity()
	link.client.set_client_entity(server_tag, client_tag)
	local plain_tag = link.plain_world:entity()
	return server_tag, client_tag, plain_tag
end

-- the first generate_packets after setup builds the viewer's full packet;
-- reconciling it seeds the client's entity map (untimed)
local function sync_initial(link)
	local packets = link.server.generate_packets()
	link.client.reconcile_packet(packets[link.viewer])
end

-- times REPS frames of the reconcile side (dirty mutates the server world
-- untimed, the viewer's packet reconciles timed) against REPS frames of the
-- plain twin's direct application, and prints the row
local function run_client_row(link, label, ops, dirty, apply)
	for rep = 1, WARM do
		apply(rep)
	end
	local plain_elapsed = 0
	for rep = 1, REPS do
		local t = os.clock()
		apply(rep)
		plain_elapsed += os.clock() - t
	end

	local reconcile_packet = link.client.reconcile_packet
	for rep = 1, WARM do
		dirty(rep)
		reconcile_packet(link.server.generate_packets()[link.viewer])
	end
	local elapsed = 0
	for rep = 1, REPS do
		dirty(rep)
		local packet = link.server.generate_packets()[link.viewer]
		local t = os.clock()
		reconcile_packet(packet)
		elapsed += os.clock() - t
	end

	local plain_ns = 1e9 * plain_elapsed / (REPS * ops)
	local duplecs_ns = 1e9 * elapsed / (REPS * ops)
	print(
		string.format(
			"%-32s ops=%5d | direct %8.1f ns/op | reconcile %8.1f ns/op | x%5.2f",
			label,
			ops,
			plain_ns,
			duplecs_ns,
			duplecs_ns / plain_ns
		)
	)
end

-- values: CELLS unpaired cells churned per frame on both sides of the wire
-- and on the plain twin
local function run_client_values()
	local link = make_link()
	local server_world = link.server_world
	local plain_world = link.plain_world
	local server_component, _, plain_component = map_component(link)

	local entities = table.create(CELLS)
	local plain_entities = table.create(CELLS)
	for i = 1, CELLS do
		local entity = server_world:entity()
		server_world:add(entity, link.server.Replicated)
		server_world:set(entity, server_component, i)
		entities[i] = entity
		local plain_entity = plain_world:entity()
		plain_world:set(plain_entity, plain_component, i)
		plain_entities[i] = plain_entity
	end
	sync_initial(link)

	run_client_row(link, "values", CELLS, function(rep)
		for i = 1, CELLS do
			server_world:set(entities[i], server_component, i * 7 + rep)
		end
	end, function(rep)
		for i = 1, CELLS do
			plain_world:set(plain_entities[i], plain_component, i * 7 + rep)
		end
	end)
end

-- adds_removes: TOGGLES entities, half adding and half removing the component
-- each frame on both sides
local function run_client_adds_removes()
	local link = make_link()
	local server_world = link.server_world
	local plain_world = link.plain_world
	local server_component, _, plain_component = map_component(link)

	local entities = table.create(TOGGLES)
	local plain_entities = table.create(TOGGLES)
	for i = 1, TOGGLES do
		local entity = server_world:entity()
		server_world:add(entity, link.server.Replicated)
		local plain_entity = plain_world:entity()
		if i % 2 == 0 then
			server_world:set(entity, server_component, i)
			plain_world:set(plain_entity, plain_component, i)
		end
		entities[i] = entity
		plain_entities[i] = plain_entity
	end
	sync_initial(link)

	run_client_row(link, "adds_removes", TOGGLES, function(rep)
		for i = 1, TOGGLES do
			if (i + rep) % 2 == 0 then
				server_world:set(entities[i], server_component, i + rep)
			else
				server_world:remove(entities[i], server_component)
			end
		end
	end, function(rep)
		for i = 1, TOGGLES do
			if (i + rep) % 2 == 0 then
				plain_world:set(plain_entities[i], plain_component, i + rep)
			else
				plain_world:remove(plain_entities[i], plain_component)
			end
		end
	end)
end

-- churn: a ring of live entities; each frame deletes the oldest slice and
-- creates a fresh one in its place, each entity holding one data component
-- and one tag on both sides
local function run_client_churn()
	local link = make_link()
	local server_world = link.server_world
	local plain_world = link.plain_world
	local server_component, _, plain_component = map_component(link)
	local server_tag, _, plain_tag = map_tag(link)

	local live = table.create(CHURN_LIVE)
	local plain_live = table.create(CHURN_LIVE)
	local function spawn(slot, value)
		local entity = server_world:entity()
		server_world:add(entity, link.server.Replicated)
		server_world:set(entity, server_component, value)
		server_world:add(entity, server_tag)
		live[slot] = entity
	end
	local function plain_spawn(slot, value)
		local entity = plain_world:entity()
		plain_world:set(entity, plain_component, value)
		plain_world:add(entity, plain_tag)
		plain_live[slot] = entity
	end
	for i = 1, CHURN_LIVE do
		spawn(i, i)
		plain_spawn(i, i)
	end
	sync_initial(link)

	local cursor = 0
	local plain_cursor = 0
	run_client_row(link, "churn", CHURN_PER_FRAME * 2, function(rep)
		for k = 1, CHURN_PER_FRAME do
			local slot = cursor + k
			server_world:delete(live[slot])
			spawn(slot, rep * CHURN_PER_FRAME + k)
		end
		cursor = (cursor + CHURN_PER_FRAME) % CHURN_LIVE
	end, function(rep)
		for k = 1, CHURN_PER_FRAME do
			local slot = plain_cursor + k
			plain_world:delete(plain_live[slot])
			plain_spawn(slot, rep * CHURN_PER_FRAME + k)
		end
		plain_cursor = (plain_cursor + CHURN_PER_FRAME) % CHURN_LIVE
	end)
end

-- pair values: PAIR_CELLS subjects each holding a data pair to its own
-- target, so one relation spans PAIR_CELLS distinct pair ids on both sides
local function run_client_pair_values()
	local link = make_link()
	local server_world = link.server_world
	local plain_world = link.plain_world
	local server_relation, _, plain_relation = map_component(link)

	local subjects = table.create(PAIR_CELLS)
	local server_pairs = table.create(PAIR_CELLS)
	local plain_subjects = table.create(PAIR_CELLS)
	local plain_pairs = table.create(PAIR_CELLS)
	for i = 1, PAIR_CELLS do
		local target = server_world:entity()
		server_world:add(target, link.server.Replicated)
		local subject = server_world:entity()
		server_world:add(subject, link.server.Replicated)
		server_world:set(subject, pair(server_relation, target), i)
		subjects[i] = subject
		server_pairs[i] = pair(server_relation, target)
		local plain_target = plain_world:entity()
		local plain_subject = plain_world:entity()
		plain_world:set(plain_subject, pair(plain_relation, plain_target), i)
		plain_subjects[i] = plain_subject
		plain_pairs[i] = pair(plain_relation, plain_target)
	end
	sync_initial(link)

	run_client_row(link, "pair values", PAIR_CELLS, function(rep)
		for i = 1, PAIR_CELLS do
			server_world:set(subjects[i], server_pairs[i], i * 3 + rep)
		end
	end, function(rep)
		for i = 1, PAIR_CELLS do
			plain_world:set(plain_subjects[i], plain_pairs[i], i * 3 + rep)
		end
	end)
end

-- unreliable: CELLS always-replicated f64 cells; the timed reconcile side
-- applies every chunk of one generate_unreliable_chunks call, the plain twin
-- applies the same sets directly. Membership arrived through sync_initial's
-- full packet, so chunk values land on existing cells.
local function run_client_unreliable()
	local link = make_link()
	local server_world = link.server_world
	local plain_world = link.plain_world

	local server_component = server_world:component()
	server_world:set(server_component, link.server.Serdes, table.clone(f64_serdes))
	server_world:add(server_component, link.server.NetworkedUnreliable)
	local client_component = link.client_world:component()
	link.client_world:set(client_component, link.client.Serdes, table.clone(f64_serdes))
	link.client.set_client_entity(server_component, client_component)
	local plain_component = plain_world:component()

	local entities = table.create(CELLS)
	local plain_entities = table.create(CELLS)
	for i = 1, CELLS do
		local entity = server_world:entity()
		server_world:add(entity, link.server.Replicated)
		server_world:set(entity, server_component, i)
		entities[i] = entity
		local plain_entity = plain_world:entity()
		plain_world:set(plain_entity, plain_component, i)
		plain_entities[i] = plain_entity
	end
	sync_initial(link)

	local reconcile_chunk = link.client.reconcile_chunk
	local function dirty(rep)
		for i = 1, CELLS do
			server_world:set(entities[i], server_component, i * 7 + rep)
		end
	end
	local function apply(rep)
		for i = 1, CELLS do
			plain_world:set(plain_entities[i], plain_component, i * 7 + rep)
		end
	end

	for rep = 1, WARM do
		apply(rep)
	end
	local plain_elapsed = 0
	for rep = 1, REPS do
		local t = os.clock()
		apply(rep)
		plain_elapsed += os.clock() - t
	end

	for rep = 1, WARM do
		dirty(rep)
		for _, chunk in link.server.generate_unreliable_chunks()[link.viewer] do
			reconcile_chunk(chunk)
		end
	end
	local elapsed = 0
	for rep = 1, REPS do
		dirty(rep)
		local chunks = link.server.generate_unreliable_chunks()[link.viewer]
		local t = os.clock()
		for _, chunk in chunks do
			reconcile_chunk(chunk)
		end
		elapsed += os.clock() - t
	end

	local plain_ns = 1e9 * plain_elapsed / (REPS * CELLS)
	local duplecs_ns = 1e9 * elapsed / (REPS * CELLS)
	print(
		string.format(
			"%-32s ops=%5d | direct %8.1f ns/op | reconcile %8.1f ns/op | x%5.2f",
			"unreliable values",
			CELLS,
			plain_ns,
			duplecs_ns,
			duplecs_ns / plain_ns
		)
	)
end

-- full: a joiner's snapshot reconciled into a fresh client world each rep,
-- against building the same content into a fresh plain world directly (world
-- construction and component mapping untimed on both sides)
local function run_client_full()
	local server_world, server = make_world(0)

	local server_components = table.create(4)
	for c = 1, 4 do
		local component = server_world:component()
		server_world:add(component, server.Networked)
		server_components[c] = component
	end
	local server_tag = server_world:entity()
	server_world:add(server_tag, server.Networked)
	local server_relation = server_world:component()
	server_world:add(server_relation, server.Networked)

	local entities = table.create(FULL_BASE)
	for i = 1, FULL_BASE do
		local entity = server_world:entity()
		server_world:add(entity, server.Replicated)
		server_world:set(entity, server_components[(i - 1) % 4 + 1], i)
		if i % 4 == 0 then
			server_world:add(entity, server_tag)
		end
		entities[i] = entity
	end
	for i = 1, FULL_PAIRS do
		server_world:set(entities[FULL_PAIRS + i], pair(server_relation, entities[i]), i * 3)
	end

	local viewer = {}
	server.add_client(viewer)
	local packet = server.generate_packets()[viewer]

	local plain_elapsed = 0
	for _ = 1, FULL_REPS do
		local plain_world = jecs.World.new()
		while (plain_world:component() :: any) < COMPONENT_FLOOR do
		end
		while (plain_world:entity() :: any) < ENTITY_FLOOR do
		end
		local plain_components = table.create(4)
		for c = 1, 4 do
			plain_components[c] = plain_world:component()
		end
		local plain_tag = plain_world:entity()
		local plain_relation = plain_world:component()

		local t = os.clock()
		local plain_entities = table.create(FULL_BASE)
		for i = 1, FULL_BASE do
			local entity = plain_world:entity()
			plain_world:set(entity, plain_components[(i - 1) % 4 + 1], i)
			if i % 4 == 0 then
				plain_world:add(entity, plain_tag)
			end
			plain_entities[i] = entity
		end
		for i = 1, FULL_PAIRS do
			plain_world:set(plain_entities[FULL_PAIRS + i], pair(plain_relation, plain_entities[i]), i * 3)
		end
		plain_elapsed += os.clock() - t
	end

	local elapsed = 0
	for _ = 1, FULL_REPS do
		local client_world = jecs.World.new()
		local client = duplecs.client(client_world)
		while (client_world:component() :: any) < COMPONENT_FLOOR do
		end
		while (client_world:entity() :: any) < ENTITY_FLOOR do
		end
		for c = 1, 4 do
			client.set_client_entity(server_components[c], client_world:component())
		end
		client.set_client_entity(server_tag, client_world:entity())
		client.set_client_entity(server_relation, client_world:component())

		local t = os.clock()
		client.reconcile_packet(packet)
		elapsed += os.clock() - t
	end

	local cells = FULL_BASE + FULL_BASE // 4 + FULL_PAIRS
	local plain_ns = 1e9 * plain_elapsed / (FULL_REPS * cells)
	local duplecs_ns = 1e9 * elapsed / (FULL_REPS * cells)
	print(
		string.format(
			"%-32s ops=%5d | direct %8.1f ns/op | reconcile %8.1f ns/op | x%5.2f  (%.4f ms/join)",
			"full packet",
			cells,
			plain_ns,
			duplecs_ns,
			duplecs_ns / plain_ns,
			1000 * elapsed / FULL_REPS
		)
	)
end

-- ---- run ----------------------------------------------------------------------

print(
	string.format(
		"duplecs end-to-end overhead  cells=%d toggles=%d pairs=%d spawns=%d reps=%d"
			.. "  (plain = same mutations, no duplecs; duplecs = mutations + generate, timed together;"
			.. " mutate/generate = the same frames' two phases clocked separately)",
		CELLS,
		TOGGLES,
		PAIR_CELLS,
		SPAWNS,
		REPS
	)
)
print("")

print(string.format("canonical rows (P=%d, broadcast visibility, hookless values):", DEFAULT_P))
do
	local plain_set_ns = measure_plain(setup_value_churn, CELLS, nil)
	run_value_row("set: Networked", DEFAULT_P, "networked", plain_set_ns)
	run_value_row("set: NetworkedOnce", DEFAULT_P, "once", plain_set_ns)
	run_value_row("set: NetworkedUnreliable (+chunks)", DEFAULT_P, "unreliable", plain_set_ns)
end
run_server_row("set: Networked pair", DEFAULT_P, setup_pair_churn, PAIR_CELLS)
run_server_row("toggle: Networked data component", DEFAULT_P, setup_toggle, TOGGLES, false)
run_server_row("toggle: Networked tag", DEFAULT_P, setup_toggle, TOGGLES, true)
run_server_row("retarget: Networked pair", DEFAULT_P, setup_retarget, TOGGLES)
run_server_row("spawn+despawn: 2 tracked cells", DEFAULT_P, setup_spawn_despawn, SPAWNS)
print("")

print("client-count sweep (broadcast visibility):")
do
	local plain_set_ns = measure_plain(setup_value_churn, CELLS, nil)
	for _, P in CLIENT_COUNTS do
		run_value_row("set: Networked", P, "networked", plain_set_ns)
	end
	local plain_spawn_ns = measure_plain(setup_spawn_despawn, SPAWNS)
	for _, P in CLIENT_COUNTS do
		local world, net = make_world(P)
		local mutate = setup_spawn_despawn(world, net)
		net.generate_packets()
		row("spawn+despawn: 2 tracked cells", P, plain_spawn_ns, measure(mutate, net.generate_packets, SPAWNS))
	end
end
print("")

print(
	string.format("visibility fragmentation (P=%d; F distinct whitelists of j clients, per-cell round-robin):", FRAG_P)
)
do
	local plain_set_ns = measure_plain(setup_value_churn, CELLS, nil)
	for _, F in MASK_COUNTS do
		run_fragmented_row(F, FRAG_P // 4, plain_set_ns)
	end
	for _, j in VIEWER_COUNTS do
		run_fragmented_row(16, j, plain_set_ns)
	end
end
print("")

print("per-frame floor (settled world, nothing staged):")
for _, P in CLIENT_COUNTS do
	run_floor_row(P)
end
print("")

print("joiner (server-side full-packet build):")
run_joiner_row()
print("")

print("client (reconcile vs applying the same changes directly; hookless values unless stated):")
run_client_values()
run_client_adds_removes()
run_client_churn()
run_client_pair_values()
run_client_unreliable()
run_client_full()
print("")

print("guard:", guard)

return true
