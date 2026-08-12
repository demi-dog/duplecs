--!native
--!optimize 2

-- duplecs generate_packets benchmark — the flagship mixed-workload sweep,
-- replacing the value-churn-only original. That bench derived each cell's
-- viewer set from an arithmetic progression with stride floor(P/j), so raising
-- j collapsed cells onto fewer distinct masks (one broadcast section per
-- component at j = P) and higher j measured *cheaper* — j and mask diversity
-- moved together (bench_fanout isolates that confound). Here masks are random
-- distinct j-subsets drawn from an F-sized pool, so fragmentation is a swept
-- parameter rather than an artifact, and j is pinned to P/4 per row.

-- Where the isolation benches each hold one axis pure (bench_whitelist_overlap:
-- mask diversity under unpaired value churn; bench_fanout: viewer count at pinned
-- diversity; bench_relation_heavy: target spread under broadcast visibility;
-- bench_many_sections: sections per node), this one drives a deliberately
-- diverse world through a mixed frame so the axes interact the way real usage
-- does:
--   world  — UNPAIRED_COMPONENTS data components across UNPAIRED_CELLS entities (every
--     4th holding a second, never-churned component), one networked tag,
--     RELATIONS data relations with T targets each and SUBJECTS subjects
--     holding one pair per relation (targets round-robin). every 4th target is
--     named-only (a shared definition, never Replicated), every other 4th
--     carries a static entity-level whitelist, so pair cells routinely pay the
--     target-gate narrowing. every unpaired cell and one relation per subject is
--     gated by a component-level whitelist from the pool; every 8th unpaired cell
--     and every 4th subject adds a static or rotating entity-level whitelist,
--     so cell masks are frequently intersections of two pool masks.
--   frame  — value churn on every unpaired and pair cell, PRIVACY_EDITS
--     component-filter rotations (each cell advancing to the pool's next mask;
--     at F = 1 the rotation diffs to nothing, so the F sweep moves diff volume
--     alongside section count — deliberate), ENTITY_PRIVACY_EDITS entity-filter
--     rotations on subjects (existence diffs: per-client creates/deletes plus
--     live-value reads for the newly visible), RETARGET_SUBJECTS subjects
--     rotating every pair to its next target, TAG_TOGGLES tag adds/removes
--     (nulled sends and removals), and ENTITY_CHURN ring slots deleted and
--     respawned (id recycling included).
--   values — the unpaired components and relations cycle through three serdes
--     states (static f64, sizeless varint, no hooks), so the timed pass
--     exercises every reliable value path: static inline values (sized
--     arithmetically), u16-prefixed inline values (encoded to size at measure
--     time), and hookless values riding the packet's side array. bench_serdes
--     isolates the hooked shapes; here they ride the mixed frame.

-- Sweeps: player count P (shard scaling), pool size F (visibility
-- fragmentation), and targets per relation T (unique pair ids, up to
-- RELATIONS * SUBJECTS distinct). The baseline row (P=64 F=16 T=16) appears in
-- both the F and T sweeps; the pair doubles as a per-run noise gauge (runs on
-- this machine swing ±15-20%). Only generate_packets() is timed; the frame's
-- mutations (and the hook work they trigger) are the untimed analog of the
-- original's dirty(). User ids are padded to fixed floors so a duplecs version
-- changing its internal id count (shifting every user id downstream) can't
-- swing cross-commit comparisons through hash-order artifacts.

-- After the timed frames, each row probes a joiner: JOINS fresh clients added
-- one at a time against the settled world, timing the generate_packets call
-- that grants the slot and builds the full packet — the one measurement of the
-- full-packet pass over unpaired cells, pairs, and privacy gates together
-- (bench_relation_heavy's join mode times a pairs-only world). Nothing is
-- dirtied between joins and the departure flush is untimed, so the timed call
-- carries the joiner's full packet alone.

local jecs = require("../../roblox_packages/jecs")
local pair = jecs.pair

local duplecs = require("../../src")

local UNPAIRED_COMPONENTS = 4
local UNPAIRED_CELLS = 512 -- total, spread round-robin across the unpaired components
local RELATIONS = 4
local SUBJECTS = 512 -- one pair per relation per subject
local CHURN_POOL = 64 -- ring of short-lived entities

local PRIVACY_EDITS = 64 -- component-filter rotations per frame
local ENTITY_PRIVACY_EDITS = 16 -- entity-filter rotations per frame
local RETARGET_SUBJECTS = 16 -- subjects rotating all RELATIONS pairs per frame
local TAG_TOGGLES = 64 -- tag adds/removes per frame
local ENTITY_CHURN = 16 -- ring slots deleted and respawned per frame

local REPS = 200
local WARM = 20
local JOINS = 20

local DEFAULT_P = 64
local DEFAULT_F = 16
local DEFAULT_T = 16

local PLAYER_COUNTS = { 8, 32, 128 } -- at F=DEFAULT_F, T=DEFAULT_T
local MASK_COUNTS = { 1, 4, 16, 64, 256 } -- at P=DEFAULT_P, T=DEFAULT_T
local TARGET_COUNTS = { 1, 8, 16, 64, 512 } -- at P=DEFAULT_P, F=DEFAULT_F; T <= SUBJECTS

-- fixed id floors (see the header): user components and entities always start
-- here no matter how many ids duplecs claims internally
local COMPONENT_FLOOR = 32
local ENTITY_FLOOR = 4096

-- ---- the two serdes shapes of the three-state cycle (see the header), shared
-- with bench_generate_unreliable. every churned value is a non-negative
-- integer, so the sizeless shape varints it — 1-3 bytes at these magnitudes,
-- behind the framing's u16 prefix.

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

-- the serdes state of definition `index` within its group (components and
-- relations each cycle independently): static f64, sizeless varint, or nil for
-- hookless side-array values
local function serdes_of(index: number)
	local state = index % 3
	if state == 1 then
		return f64_serdes
	elseif state == 2 then
		return varint_serdes
	end
	return nil
end

-- ---- distinct mask generation: `count` unique random j-subsets of P player
-- indices (0-based), deduped by their numeric bitmask. Identical to
-- bench_whitelist_overlap; j = P/4 keeps C(P, j) well above every swept F, so
-- the retry loop is effectively free.

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

-- ---- guard: touch the returned packets so the call can't be optimized away.
-- untimed; generate_packets mutates world state regardless, this is belt-and-braces.

local guard = 0

local function packet_guard(packets)
	local n = 0
	for _player in packets do
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

-- ---- run ------------------------------------------------------------------

local function run(P, F, T)
	local world = jecs.World.new()
	local net = duplecs.server(world)

	-- pad user ids to the fixed floors (padding entities stay alive in the
	-- root archetype, so no walked path ever sees them)
	while (world:component() :: any) < COMPONENT_FLOOR do
	end
	while (world:entity() :: any) < ENTITY_FLOOR do
	end

	-- dummy player stand-ins; the module only uses them as table keys
	local players = table.create(P) :: { any }
	for i = 1, P do
		players[i] = {}
	end

	-- the shared whitelist pool: F distinct frozen j-subsets of the players,
	-- reused by reference across every filter drawing from them
	local j = math.max(P // 4, 2)
	local mask_indices = generate_masks(F, j, P)
	local pool = table.create(F)
	for m = 1, F do
		local whitelist = {}
		for _, index in mask_indices[m] do
			whitelist[players[index + 1]] = true
		end
		pool[m] = table.freeze(whitelist)
	end

	-- networked definitions: unpaired data components, one tag, and the relations,
	-- each group cycling through the three serdes states (see serdes_of)
	local unpaired = table.create(UNPAIRED_COMPONENTS)
	for c = 1, UNPAIRED_COMPONENTS do
		local component = world:component()
		local hooks = serdes_of(c)
		if hooks ~= nil then
			world:set(component, net.Serdes, table.clone(hooks))
		end
		world:add(component, net.Networked)
		unpaired[c] = component
	end

	local relations = table.create(RELATIONS)
	for r = 1, RELATIONS do
		local relation = world:component()
		local hooks = serdes_of(r)
		if hooks ~= nil then
			world:set(relation, net.Serdes, table.clone(hooks))
		end
		world:add(relation, net.Networked)
		relations[r] = relation
	end

	local tag = world:entity()
	world:add(tag, net.Networked)

	-- T targets per relation: every 4th named-only (a shared definition
	-- clients map by name), the rest Replicated with every other 4th carrying
	-- a static entity-level whitelist (applied after allocation, below)
	local targets = table.create(RELATIONS)
	for r = 1, RELATIONS do
		local relation_targets = table.create(T)
		for k = 1, T do
			local target = world:entity()
			if k % 4 == 0 then
				world:set(target, jecs.Name, `target_{r}_{k}`)
			else
				world:add(target, net.Replicated)
			end
			relation_targets[k] = target
		end
		targets[r] = relation_targets
	end

	-- unpaired cells: one churned component each, every 4th holding a second,
	-- never-churned component (restages walk it; deltas never carry it)
	local cell_entities = table.create(UNPAIRED_CELLS)
	local cell_components = table.create(UNPAIRED_CELLS)
	for i = 1, UNPAIRED_CELLS do
		local entity = world:entity()
		local component = unpaired[(i - 1) % UNPAIRED_COMPONENTS + 1]
		world:set(entity, component, i * 3)
		if i % 4 == 0 then
			world:set(entity, unpaired[i % UNPAIRED_COMPONENTS + 1], i * 7)
		end
		world:add(entity, net.Replicated)
		cell_entities[i] = entity
		cell_components[i] = component
	end

	-- subjects: one pair per relation, targets assigned round-robin
	-- (assigned[r][i] tracks the live index so retargets can rotate it)
	local subjects = table.create(SUBJECTS)
	local assigned = table.create(RELATIONS)
	for r = 1, RELATIONS do
		assigned[r] = table.create(SUBJECTS)
	end
	for i = 1, SUBJECTS do
		local subject = world:entity()
		for r = 1, RELATIONS do
			local target_index = (i - 1) % T + 1
			world:set(subject, pair(relations[r], targets[r][target_index]), i * 5 + r)
			assigned[r][i] = target_index
		end
		world:add(subject, net.Replicated)
		subjects[i] = subject
	end

	-- queue every player, then warmup #1 allocates their slots (full packets)
	for _, player in players do
		net.add_client(player)
	end
	net.generate_packets()

	-- component-level filters, now that players are tracked so masks derive
	-- correctly: every unpaired cell gated on its churned component, every subject
	-- gated on one of its relations, all drawing from the pool round-robin.
	-- the parallel arrays drive the per-frame rotation cursor.
	local gated_entities = {}
	local gated_keys = {}
	local gated_index = {}
	local gated_count = 0
	for i = 1, UNPAIRED_CELLS do
		local m = (i - 1) % F + 1
		world:set(cell_entities[i], pair(net.Private, cell_components[i]), pool[m])
		gated_count += 1
		gated_entities[gated_count] = cell_entities[i]
		gated_keys[gated_count] = cell_components[i]
		gated_index[gated_count] = m
	end
	for i = 1, SUBJECTS do
		local relation = relations[(i - 1) % RELATIONS + 1]
		local m = i % F + 1
		world:set(subjects[i], pair(net.Private, relation), pool[m])
		gated_count += 1
		gated_entities[gated_count] = subjects[i]
		gated_keys[gated_count] = relation
		gated_index[gated_count] = m
	end

	-- entity-level filters: static on every 8th unpaired cell and every other 4th
	-- replicated target, rotating on every 4th subject (the rotation is what
	-- drives per-frame existence diffs)
	for i = 8, UNPAIRED_CELLS, 8 do
		world:set(cell_entities[i], net.Private, pool[(i * 3) % F + 1])
	end
	for r = 1, RELATIONS do
		for k = 2, T, 4 do
			world:set(targets[r][k], net.Private, pool[(r + k) % F + 1])
		end
	end
	local entity_gated = {}
	local entity_gated_index = {}
	local entity_gated_count = 0
	for i = 4, SUBJECTS, 4 do
		local m = (i * 3) % F + 1
		world:set(subjects[i], net.Private, pool[m])
		entity_gated_count += 1
		entity_gated[entity_gated_count] = subjects[i]
		entity_gated_index[entity_gated_count] = m
	end

	-- the churn ring: short-lived entities respawned in place, each holding
	-- one unpaired cell and one pair, every other one entity-gated
	local churn_ring = table.create(CHURN_POOL)
	local churn_tick = 0
	local function spawn_churn(slot)
		churn_tick += 1
		local entity = world:entity()
		world:set(entity, unpaired[(slot - 1) % UNPAIRED_COMPONENTS + 1], churn_tick)
		world:set(entity, pair(relations[1], targets[1][(slot - 1) % T + 1]), churn_tick)
		if slot % 2 == 0 then
			world:set(entity, net.Private, pool[(slot - 1) % F + 1])
		end
		world:add(entity, net.Replicated)
		churn_ring[slot] = entity
	end
	for slot = 1, CHURN_POOL do
		spawn_churn(slot)
	end

	-- warmup #2: flush the filters and the seeded ring into last_visibilities
	-- so the timed deltas diff against a settled world
	net.generate_packets()

	-- the mixed frame (untimed): every mutation kind the header describes
	local tick = 0
	local privacy_cursor = 0
	local entity_privacy_cursor = 0
	local retarget_cursor = 0
	local tag_cursor = 0
	local tagged = {}
	local churn_slot = 0

	local function dirty()
		tick += 1

		-- value churn: a fresh value for every unpaired and pair cell
		for i = 1, UNPAIRED_CELLS do
			world:set(cell_entities[i], cell_components[i], i * 3 + tick)
		end
		for r = 1, RELATIONS do
			local relation = relations[r]
			local relation_targets = targets[r]
			local relation_assigned = assigned[r]
			for i = 1, SUBJECTS do
				world:set(subjects[i], pair(relation, relation_targets[relation_assigned[i]]), i * 5 + tick)
			end
		end

		-- component-privacy churn: rotate each cell to the pool's next mask
		for _ = 1, PRIVACY_EDITS do
			privacy_cursor = privacy_cursor % gated_count + 1
			local m = gated_index[privacy_cursor] % F + 1
			gated_index[privacy_cursor] = m
			world:set(gated_entities[privacy_cursor], pair(net.Private, gated_keys[privacy_cursor]), pool[m])
		end

		-- entity-privacy churn: existence diffs, creates/deletes per client
		for _ = 1, ENTITY_PRIVACY_EDITS do
			entity_privacy_cursor = entity_privacy_cursor % entity_gated_count + 1
			local m = entity_gated_index[entity_privacy_cursor] % F + 1
			entity_gated_index[entity_privacy_cursor] = m
			world:set(entity_gated[entity_privacy_cursor], net.Private, pool[m])
		end

		-- retargets: each chosen subject rotates every pair to its next target
		for _ = 1, RETARGET_SUBJECTS do
			retarget_cursor = retarget_cursor % SUBJECTS + 1
			local subject = subjects[retarget_cursor]
			for r = 1, RELATIONS do
				local relation = relations[r]
				local relation_targets = targets[r]
				local old_index = assigned[r][retarget_cursor]
				local new_index = old_index % T + 1
				world:remove(subject, pair(relation, relation_targets[old_index]))
				world:set(subject, pair(relation, relation_targets[new_index]), retarget_cursor * 5 + tick)
				assigned[r][retarget_cursor] = new_index
			end
		end

		-- tag toggles: nulled sends and removals, plus archetype moves
		for _ = 1, TAG_TOGGLES do
			tag_cursor = tag_cursor % UNPAIRED_CELLS + 1
			if tagged[tag_cursor] then
				tagged[tag_cursor] = nil
				world:remove(cell_entities[tag_cursor], tag)
			else
				tagged[tag_cursor] = true
				world:add(cell_entities[tag_cursor], tag)
			end
		end

		-- entity churn: the ring's oldest slots die and respawn (recycled ids)
		for _ = 1, ENTITY_CHURN do
			churn_slot = churn_slot % CHURN_POOL + 1
			world:delete(churn_ring[churn_slot])
			spawn_churn(churn_slot)
		end
	end

	for _ = 1, WARM do
		dirty()
		guard += packet_guard(net.generate_packets())
	end

	local elapsed = 0
	local bytes, variants = 0, 0
	for _ = 1, REPS do
		dirty()
		local t = os.clock()
		local packets = net.generate_packets()
		elapsed += os.clock() - t
		guard += packet_guard(packets)
		bytes, variants = bytes_of(packets, players[1])
	end

	-- join probe (see the header): the last timed frame drained everything, so
	-- each join's generate_packets carries exactly the joiner's full packet
	local join_elapsed = 0
	local join_bytes, join_variants = 0, 0
	for _ = 1, JOINS do
		local joiner = {}
		net.add_client(joiner)
		local t = os.clock()
		local packets = net.generate_packets()
		join_elapsed += os.clock() - t
		guard += packet_guard(packets)
		join_bytes, join_variants = bytes_of(packets, joiner)
		net.remove_client(joiner)
		net.generate_packets()
	end

	print(
		string.format(
			"P=%4d  F=%4d  T=%4d  pair ids=%5d  | %8.4f ms/frame  | %6d B + %5d values /client"
				.. "  | join %7.4f ms  %6d B + %5d values",
			P,
			F,
			T,
			RELATIONS * T,
			1000 * elapsed / REPS,
			bytes,
			variants,
			1000 * join_elapsed / JOINS,
			join_bytes,
			join_variants
		)
	)
end

print(
	string.format(
		"duplecs mixed-frame  unpaired=%d cells  pairs=%d  churn=%d/frame  privacy=%d+%d/frame  retarget=%d subj/frame"
			.. "  tags=%d/frame  reps=%d  joins=%d/row",
		UNPAIRED_CELLS,
		RELATIONS * SUBJECTS,
		ENTITY_CHURN,
		PRIVACY_EDITS,
		ENTITY_PRIVACY_EDITS,
		RETARGET_SUBJECTS,
		TAG_TOGGLES,
		REPS,
		JOINS
	)
)
print("")

print(string.format("players sweep (F=%d, T=%d):", DEFAULT_F, DEFAULT_T))
for _, P in PLAYER_COUNTS do
	run(P, DEFAULT_F, DEFAULT_T)
end
print("")

print(string.format("fragmentation sweep (P=%d, T=%d):", DEFAULT_P, DEFAULT_T))
for _, F in MASK_COUNTS do
	run(DEFAULT_P, F, DEFAULT_T)
end
print("")

print(string.format("unique-pairs sweep (P=%d, F=%d):", DEFAULT_P, DEFAULT_F))
for _, T in TARGET_COUNTS do
	run(DEFAULT_P, DEFAULT_F, T)
end
print("")

print("guard:", guard)

return true
