--!native
--!optimize 2

-- duplecs hook-overhead benchmark: the mutation side of replication — the
-- added/changed/removed hooks duplecs connects on every tracked component,
-- and the Replicated add/remove hooks with their restage walks.
-- Every other bench times generate_packets (or reconcile_packet) with the
-- frame's mutations untimed; this one inverts that: only the mutations are
-- timed, and an untimed generate_packets drains the staged state after every
-- rep so each rep mutates a settled world the way a real frame would. Ops
-- include the raw jecs cost (archetype moves, column writes), so each section
-- leads with an untracked baseline to subtract.
--
-- Sections (op = one world:set, or one full remove+add / delete+respawn cycle):
--   set churn  — the changed hook: untracked baseline, NetworkedOnce (tracked,
--     deliberately no changed hook — should match the baseline), Networked
--     cells visible to clients (stage_value hit on the first occupied shard),
--     Networked cells on unreplicated entities (a full-scan miss), and pair
--     cells (is_pair_replicable on every set).
--   toggles    — the added + removed hooks, two archetype moves per op:
--     untracked baseline, a data component, a tag (nulled staging), and a pair
--     retarget (deindex + reindex + visibility stages on two distinct pair
--     ids) against its untracked twin.
--   Replicated — the replicated add/remove hooks: remove+add cycles whose
--     restage_entity walk scales with the entity's cell count (2 vs 8 tracked
--     cells, and 2 tracked among 6 untracked — the walk visits every archetype
--     type but only stages the tracked ones), a pair target fanned out to
--     FAN_SUBJECTS subjects (restage_pairs_targeting re-stages every subject's
--     cell twice per cycle), and the full spawn+despawn lifecycle (adds,
--     Replicated add, then the delete's removed cascade, ids recycling).
--   clients    — the shard-sensitive rows swept across client counts: 0
--     (nothing to stage against), 32 (one full shard, the default every row
--     above runs at — the repeats double as a per-run noise gauge; runs on
--     this machine swing ±15-20%), 128 (four shards). value churn should stay
--     near-flat (stage_value exits on the first occupied shard's hit); the
--     toggle rows stage a word per occupied shard per cell.
--
-- No serdes hooks. User ids are padded to fixed floors so a duplecs version
-- changing its internal id count (shifting every user id downstream) can't
-- swing cross-commit comparisons through hash-order artifacts.

local jecs = require("../../roblox_packages/jecs")
local pair = jecs.pair

local duplecs = require("../../src")

local CELLS = 1024 -- set-churn cells (one op each per rep)
local TOGGLES = 512 -- toggled entities (one remove+add cycle each per rep)
local REPLICATED_TOGGLES = 128 -- Replicated-cycled entities per rep
local FAN_SUBJECTS = 256 -- subjects targeting the fanned pair target
local FAN_CYCLES = 8 -- target Replicated cycles per rep
local SPAWN_RING = 256 -- ring of short-lived entities
local SPAWNS = 128 -- delete+respawn cycles per rep
local BACKDROP = 64 -- visible cells keeping the stores occupied (see below)

local DEFAULT_P = 32 -- exactly one full shard
local CLIENT_COUNTS = { 0, 32, 128 }
local REPS = 200
local WARM = 20

-- fixed id floors (see the header): user components and entities always start
-- here no matter how many ids duplecs claims internally
local COMPONENT_FLOOR = 32
local ENTITY_FLOOR = 4096

local guard = 0

local function drain(packets)
	local n = 0
	for _client in packets do
		n += 1
	end
	return n
end

-- fresh world with padded ids and P allocated clients; definitions and
-- entities are per-scenario, so every row builds against the same baseline
local function make_server(P)
	local world = jecs.World.new()
	local net = duplecs.server(world)

	-- pad user ids to the fixed floors (padding entities stay alive in the
	-- root archetype, so no walked path ever sees them)
	while (world:component() :: any) < COMPONENT_FLOOR do
	end
	while (world:entity() :: any) < ENTITY_FLOOR do
	end

	local players = table.create(P) :: { any }
	for i = 1, P do
		players[i] = {}
		net.add_client(players[i])
	end
	net.generate_packets()

	return world, net, players
end

-- shared timing shell: WARM then REPS of mutate + untimed drain, returning
-- nanoseconds per op
local function measure(net, mutate, ops)
	for _ = 1, WARM do
		mutate()
		guard += drain(net.generate_packets())
	end

	local elapsed = 0
	for _ = 1, REPS do
		local t = os.clock()
		mutate()
		elapsed += os.clock() - t
		guard += drain(net.generate_packets())
	end

	return 1e9 * elapsed / (REPS * ops)
end

local function report(label, P, ns)
	print(string.format("%-44s P=%3d | %9.1f ns/op", label, P, ns))
end

-- set churn: CELLS entities each holding one data component, every cell set to
-- a fresh value per rep. mode picks the tracking tag (nil = untracked, no
-- hooks connected at all); replicated gates whether the cells are visible.
local function bench_set_churn(label, P, mode, replicated)
	local world, net = make_server(P)

	local component = world:component()
	if mode == "networked" then
		world:add(component, net.Networked)
	elseif mode == "once" then
		world:add(component, net.NetworkedOnce)
	end

	-- a backdrop of visible cells on a second Networked component keeps the
	-- visibility stores occupied, so the unreplicated row's stage_value scan
	-- pays a real miss instead of an empty-store exit (present in every row
	-- so they stay comparable)
	local backdrop = world:component()
	world:add(backdrop, net.Networked)
	for i = 1, BACKDROP do
		local entity = world:entity()
		world:set(entity, backdrop, i)
		world:add(entity, net.Replicated)
	end

	local entities = table.create(CELLS)
	for i = 1, CELLS do
		local entity = world:entity()
		world:set(entity, component, i)
		if replicated then
			world:add(entity, net.Replicated)
		end
		entities[i] = entity
	end
	net.generate_packets()

	local tick = 0
	local function churn()
		tick += 1
		for i = 1, CELLS do
			world:set(entities[i], component, i + tick)
		end
	end

	report(label, P, measure(net, churn, CELLS))
end

-- pair set churn: CELLS subjects each holding one data pair on a shared
-- Replicated target, every pair set to a fresh value per rep — the changed
-- hook pays is_pair_replicable (gen-cache resolves) on top of the unpaired-cell path
local function bench_pair_set_churn(label, P)
	local world, net = make_server(P)

	local relation = world:component()
	world:add(relation, net.Networked)
	local target = world:entity()
	world:add(target, net.Replicated)

	local subjects = table.create(CELLS)
	for i = 1, CELLS do
		local subject = world:entity()
		world:set(subject, pair(relation, target), i)
		world:add(subject, net.Replicated)
		subjects[i] = subject
	end
	net.generate_packets()

	local tick = 0
	local function churn()
		tick += 1
		for i = 1, CELLS do
			world:set(subjects[i], pair(relation, target), i + tick)
		end
	end

	report(label, P, measure(net, churn, CELLS))
end

-- component toggles: TOGGLES visible entities; each op removes the component
-- and sets (or, for tags, adds) it back, so every op pays one removed hook,
-- one added hook, and two archetype moves
local function bench_toggle(label, P, mode, tag_definition)
	local world, net = make_server(P)

	local component
	if tag_definition then
		component = world:entity()
	else
		component = world:component()
	end
	if mode == "networked" then
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
		world:add(entity, net.Replicated)
		entities[i] = entity
	end
	net.generate_packets()

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

	report(label, P, measure(net, toggle, TOGGLES))
end

-- pair retargets: TOGGLES visible subjects alternating between two Replicated
-- targets; each op removes pair(relation, old) and sets pair(relation, new),
-- paying the deindex + reindex walk and visibility stages on two distinct
-- pair ids. tracked gates the relation's Networked only — the world shape is
-- identical either way, so the untracked row is the raw-jecs twin.
local function bench_retarget(label, P, tracked)
	local world, net = make_server(P)

	local relation = world:component()
	if tracked then
		world:add(relation, net.Networked)
	end
	local targets = { world:entity(), world:entity() }
	world:add(targets[1], net.Replicated)
	world:add(targets[2], net.Replicated)

	local subjects = table.create(TOGGLES)
	local assigned = table.create(TOGGLES)
	for i = 1, TOGGLES do
		local subject = world:entity()
		local target_index = (i - 1) % 2 + 1
		world:set(subject, pair(relation, targets[target_index]), i)
		world:add(subject, net.Replicated)
		subjects[i] = subject
		assigned[i] = target_index
	end
	net.generate_packets()

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

	report(label, P, measure(net, rotate, TOGGLES))
end

-- Replicated toggles: each op removes Replicated and adds it back, so both
-- replicated hooks run and restage_entity walks the entity's cells twice.
-- tracked_count / untracked_count shape the walked archetype: every type is
-- visited, but only the tracked ones stage.
local function bench_replicated_toggle(label, P, tracked_count, untracked_count)
	local world, net = make_server(P)

	local tracked = table.create(tracked_count)
	for c = 1, tracked_count do
		local component = world:component()
		world:add(component, net.Networked)
		tracked[c] = component
	end
	local untracked = table.create(untracked_count)
	for c = 1, untracked_count do
		untracked[c] = world:component()
	end

	local entities = table.create(REPLICATED_TOGGLES)
	for i = 1, REPLICATED_TOGGLES do
		local entity = world:entity()
		for c = 1, tracked_count do
			world:set(entity, tracked[c], i * 10 + c)
		end
		for c = 1, untracked_count do
			world:set(entity, untracked[c], i * 100 + c)
		end
		world:add(entity, net.Replicated)
		entities[i] = entity
	end
	net.generate_packets()

	local function toggle()
		for i = 1, REPLICATED_TOGGLES do
			world:remove(entities[i], net.Replicated)
			world:add(entities[i], net.Replicated)
		end
	end

	report(label, P, measure(net, toggle, REPLICATED_TOGGLES))
end

-- pair-target toggle: one Replicated target fanned out to FAN_SUBJECTS
-- subjects, its Replicated cycled FAN_CYCLES times per rep; each cycle's two
-- restage_pairs_targeting walks re-stage every subject's pair cell, so one op
-- covers 2 * FAN_SUBJECTS cell stages
local function bench_target_toggle(label, P)
	local world, net = make_server(P)

	local relation = world:component()
	world:add(relation, net.Networked)
	local target = world:entity()
	world:add(target, net.Replicated)

	for i = 1, FAN_SUBJECTS do
		local subject = world:entity()
		world:set(subject, pair(relation, target), i)
		world:add(subject, net.Replicated)
	end
	net.generate_packets()

	local function toggle()
		for _ = 1, FAN_CYCLES do
			world:remove(target, net.Replicated)
			world:add(target, net.Replicated)
		end
	end

	report(label, P, measure(net, toggle, FAN_CYCLES))
end

-- spawn+despawn: a ring of short-lived entities, each holding two tracked
-- cells and Replicated; every op deletes the oldest slot and respawns it
-- (recycled ids), so one op is the full lifecycle every hook family fires
-- for — two added hooks, the Replicated add's restage, then the delete's
-- removed cascade
local function bench_spawn_despawn(label, P)
	local world, net = make_server(P)

	local ComponentA = world:component()
	world:add(ComponentA, net.Networked)
	local ComponentB = world:component()
	world:add(ComponentB, net.Networked)

	local tick = 0
	local ring = table.create(SPAWN_RING)
	local function spawn(slot)
		tick += 1
		local entity = world:entity()
		world:set(entity, ComponentA, tick)
		world:set(entity, ComponentB, tick * 2)
		world:add(entity, net.Replicated)
		ring[slot] = entity
	end
	for slot = 1, SPAWN_RING do
		spawn(slot)
	end
	net.generate_packets()

	local slot_cursor = 0
	local function churn()
		for _ = 1, SPAWNS do
			slot_cursor = slot_cursor % SPAWN_RING + 1
			world:delete(ring[slot_cursor])
			spawn(slot_cursor)
		end
	end

	report(label, P, measure(net, churn, SPAWNS))
end

print(
	string.format(
		"duplecs hook overhead  cells=%d toggles=%d replicated=%d fan=%d spawns=%d reps=%d  (mutations timed, drains untimed)",
		CELLS,
		TOGGLES,
		REPLICATED_TOGGLES,
		FAN_SUBJECTS,
		SPAWNS,
		REPS
	)
)
print("")

print("set churn (changed hook; op = one world:set):")
bench_set_churn("set: untracked baseline", DEFAULT_P, nil, true)
bench_set_churn("set: NetworkedOnce (no changed hook)", DEFAULT_P, "once", true)
bench_set_churn("set: Networked, visible cells", DEFAULT_P, "networked", true)
bench_set_churn("set: Networked, unreplicated cells", DEFAULT_P, "networked", false)
bench_pair_set_churn("set: Networked pair, visible cells", DEFAULT_P)
print("")

print("component toggles (added + removed hooks; op = one remove+add cycle):")
bench_toggle("toggle: untracked baseline", DEFAULT_P, nil, false)
bench_toggle("toggle: Networked data component", DEFAULT_P, "networked", false)
bench_toggle("toggle: Networked tag", DEFAULT_P, "networked", true)
bench_retarget("retarget: untracked pair baseline", DEFAULT_P, false)
bench_retarget("retarget: Networked pair", DEFAULT_P, true)
print("")

print("Replicated cycles (replicated hooks; op = one remove+add or delete+respawn):")
bench_replicated_toggle("Replicated cycle: 2 tracked cells", DEFAULT_P, 2, 0)
bench_replicated_toggle("Replicated cycle: 8 tracked cells", DEFAULT_P, 8, 0)
bench_replicated_toggle("Replicated cycle: 2 tracked + 6 untracked", DEFAULT_P, 2, 6)
bench_target_toggle(string.format("Replicated cycle: pair target of %d", FAN_SUBJECTS), DEFAULT_P)
bench_spawn_despawn("spawn+despawn: 2 tracked cells", DEFAULT_P)
print("")

print("client-count sweep (shard scaling):")
for _, P in CLIENT_COUNTS do
	bench_set_churn("set: Networked, visible cells", P, "networked", true)
end
for _, P in CLIENT_COUNTS do
	bench_toggle("toggle: Networked data component", P, "networked", false)
end
for _, P in CLIENT_COUNTS do
	bench_replicated_toggle("Replicated cycle: 8 tracked cells", P, 8, 0)
end
print("")

print("guard:", guard)

return true
