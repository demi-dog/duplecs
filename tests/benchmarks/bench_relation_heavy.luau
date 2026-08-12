--!native
--!optimize 2

-- duplecs relationship-heavy benchmark: a fixed count of pair cells swept
-- across how many distinct targets they spread over — the axis the
-- relation-grouped packet groups and the grouped pair section layout target.
-- Pre-grouping, every distinct pair(relation, target) id cost its own
-- persistent group, its own section draft, and its own buffer with the
-- relation id repeated in every header; grouped, a relation pays one of each,
-- with per-target runs inside the section. T=1 collapses to the single-target
-- layout, so the first row of every mode doubles as a no-regression check;
-- run against the pre-grouping commit for the before side of a comparison
-- (the public API is identical, only the wire format differs).

-- Scenario: SUBJECTS entities each hold one data pair per relation,
-- pair(relation, target), targets assigned round-robin from that relation's T
-- distinct Replicated target entities. Visibility is broadcast (no Private),
-- so every cell of a relation shares one mask and lands in one section — the
-- pure grouping shape, undiluted by mask splits. P clients, no serdes hooks.

-- Modes, each swept across TARGET_COUNTS:
--   value churn — every pair's value changes per tick, so component_changes
--     carries T distinct pair ids per relation; times generate_packets.
--   retarget    — RETARGET subjects per relation rotate to their next target
--     per tick (a pair removed + a pair added, staging visibility cells on
--     two distinct pair ids each); times generate_packets.
--   join        — a client joins the settled world; times the full-packet
--     pass, whose emit walks every pair cell.
--   apply       — a client world reconciles the value-churn delta; times
--     reconcile_packet (per-run header parsing vs per-section).

local jecs = require("../../roblox_packages/jecs")
local pair = jecs.pair

local duplecs = require("../../src")

local RELATIONS = 2
local SUBJECTS = 1024 -- one pair per relation per subject
local TARGET_COUNTS = { 1, 4, 16, 64, 256, 1024 } -- distinct targets per relation
local RETARGET = 128 -- subjects rotating their target per tick, per relation
local P = 8
local REPS = 200
local WARM = 20
local JOINS = 20

local guard = 0

local function drain(packets)
	local n = 0
	for _client in packets do
		n += 1
	end
	return n
end

local function bytes_of(packets, client)
	-- wire bytes of one client's packet (buffer only), plus the count of
	-- out-of-band values it carries
	local packet = packets[client]
	if packet == nil then
		return 0, 0
	end
	local bytes = buffer.len(packet.data)
	local variants = 0
	if packet.values then
		for _, values in packet.values do
			variants += #values
		end
	end
	return bytes, variants
end

-- builds the world: RELATIONS networked data relations, T Replicated targets
-- each, SUBJECTS Replicated subjects holding one pair per relation with
-- targets assigned round-robin (assigned[r][i] tracks the live index so the
-- retarget mode can rotate it). clients are allocated by the trailing
-- generate_packets, so the timed loops always run against a settled world.
local function setup(T)
	local world = jecs.World.new()
	local net = duplecs.server(world)

	local relations = table.create(RELATIONS)
	for r = 1, RELATIONS do
		local relation = world:component()
		world:add(relation, net.Networked)
		relations[r] = relation
	end

	local targets = table.create(RELATIONS)
	for r = 1, RELATIONS do
		local relation_targets = table.create(T)
		for k = 1, T do
			local target = world:entity()
			world:add(target, net.Replicated)
			relation_targets[k] = target
		end
		targets[r] = relation_targets
	end

	local subjects = table.create(SUBJECTS)
	local assigned = table.create(RELATIONS)
	for r = 1, RELATIONS do
		assigned[r] = table.create(SUBJECTS)
	end
	for i = 1, SUBJECTS do
		local subject = world:entity()
		for r = 1, RELATIONS do
			local target_index = (i - 1) % T + 1
			world:set(subject, pair(relations[r], targets[r][target_index]), i * 3)
			assigned[r][i] = target_index
		end
		world:add(subject, net.Replicated)
		subjects[i] = subject
	end

	local players = table.create(P) :: { any }
	for i = 1, P do
		players[i] = {}
		net.add_client(players[i])
	end
	net.generate_packets()

	return world, net, relations, targets, subjects, assigned, players
end

local function bench_value_churn(T)
	local world, net, relations, targets, subjects, assigned, players = setup(T)

	local tick = 0
	local function dirty()
		tick += 1
		for r = 1, RELATIONS do
			local relation = relations[r]
			local relation_targets = targets[r]
			local relation_assigned = assigned[r]
			for i = 1, SUBJECTS do
				world:set(subjects[i], pair(relation, relation_targets[relation_assigned[i]]), i * 3 + tick)
			end
		end
	end

	for _ = 1, WARM do
		dirty()
		guard += drain(net.generate_packets())
	end

	local elapsed = 0
	local bytes, variants = 0, 0
	for _ = 1, REPS do
		dirty()
		local t = os.clock()
		local packets = net.generate_packets()
		elapsed += os.clock() - t
		guard += drain(packets)
		bytes, variants = bytes_of(packets, players[1])
	end

	print(
		string.format(
			"value churn  T=%4d | %8.4f ms/tick  | %6d B + %5d values /client",
			T,
			1000 * elapsed / REPS,
			bytes,
			variants
		)
	)
end

local function bench_retarget(T)
	local world, net, relations, targets, subjects, assigned, players = setup(T)

	local tick = 0
	local function rotate()
		tick += 1
		for r = 1, RELATIONS do
			local relation = relations[r]
			local relation_targets = targets[r]
			local relation_assigned = assigned[r]
			for i = 1, RETARGET do
				local subject = subjects[i]
				local old_index = relation_assigned[i]
				local new_index = old_index % T + 1
				world:remove(subject, pair(relation, relation_targets[old_index]))
				world:set(subject, pair(relation, relation_targets[new_index]), i * 3 + tick)
				relation_assigned[i] = new_index
			end
		end
	end

	for _ = 1, WARM do
		rotate()
		guard += drain(net.generate_packets())
	end

	local elapsed = 0
	local bytes, variants = 0, 0
	for _ = 1, REPS do
		rotate()
		local t = os.clock()
		local packets = net.generate_packets()
		elapsed += os.clock() - t
		guard += drain(packets)
		bytes, variants = bytes_of(packets, players[1])
	end

	print(
		string.format(
			"retarget     T=%4d | %8.4f ms/tick  | %6d B + %5d values /client",
			T,
			1000 * elapsed / REPS,
			bytes,
			variants
		)
	)
end

local function bench_join(T)
	local _world, net = setup(T)

	local elapsed = 0
	local bytes, variants = 0, 0
	for _ = 1, JOINS do
		local joiner = {}
		net.add_client(joiner)
		local t = os.clock()
		local packets = net.generate_packets()
		elapsed += os.clock() - t
		bytes, variants = bytes_of(packets, joiner)
		net.remove_client(joiner)
		net.generate_packets()
	end

	print(
		string.format(
			"join         T=%4d | %8.4f ms/join  | %6d B + %5d values",
			T,
			1000 * elapsed / JOINS,
			bytes,
			variants
		)
	)
end

local function bench_apply(T)
	local world, net, relations, targets, subjects, assigned = setup(T)

	-- client world: only the relation definitions need mapping; targets and
	-- subjects import through the replicated lists
	local c_world = jecs.World.new()
	local c_net = duplecs.client(c_world)
	for r = 1, RELATIONS do
		local c_relation = c_world:component()
		c_net.set_client_entity(relations[r] :: any, c_relation)
	end

	-- initial full state: join one representative client late and apply
	local viewer = {}
	net.add_client(viewer)
	local full = net.generate_packets()[viewer]
	c_net.reconcile_packet(full)

	local tick = 0
	local function dirty()
		tick += 1
		for r = 1, RELATIONS do
			local relation = relations[r]
			local relation_targets = targets[r]
			local relation_assigned = assigned[r]
			for i = 1, SUBJECTS do
				world:set(subjects[i], pair(relation, relation_targets[relation_assigned[i]]), i * 3 + tick)
			end
		end
	end

	for _ = 1, WARM do
		dirty()
		c_net.reconcile_packet(net.generate_packets()[viewer])
	end

	local elapsed = 0
	for _ = 1, REPS do
		dirty()
		local packet = net.generate_packets()[viewer]
		local t = os.clock()
		c_net.reconcile_packet(packet)
		elapsed += os.clock() - t
	end

	print(string.format("apply        T=%4d | %8.4f ms/apply (client)", T, 1000 * elapsed / REPS))
end

print(
	string.format(
		"duplecs relationship-heavy  relations=%d subjects=%d retarget=%d/tick P=%d reps=%d",
		RELATIONS,
		SUBJECTS,
		RETARGET,
		P,
		REPS
	)
)

for _, T in TARGET_COUNTS do
	bench_value_churn(T)
end
print("")

for _, T in TARGET_COUNTS do
	bench_retarget(T)
end
print("")

for _, T in TARGET_COUNTS do
	bench_join(T)
end
print("")

for _, T in TARGET_COUNTS do
	bench_apply(T)
end
print("")

print("guard:", guard)

return true
