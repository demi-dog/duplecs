--!native
--!optimize 2

-- duplecs generate_unreliable_chunks benchmark — the always-replicate
-- counterpart of bench_generate_packets, replacing the value-churn-only
-- original. That bench derived each cell's viewer set from an arithmetic
-- progression with stride floor(P/j), so raising j collapsed cells onto fewer
-- distinct masks (one broadcast node at j = P) and higher j measured
-- *cheaper* — j and mask diversity moved together. Here masks are random
-- distinct j-subsets drawn from an F-sized pool, so fragmentation is a swept
-- parameter rather than an artifact, and j is pinned to P/4 per row.

-- Same world as the reliable bench and the same P/F/T sweeps, with the mixed
-- frame reduced to value churn alone: this channel re-reads and re-sends every
-- visible cell's current value on every call, so a new value is the only
-- mutation kind it responds to. Everything else the reliable frame does —
-- privacy rotations, retargets, tag toggles, entity churn — is reliable-path
-- work that reaches this channel only as a visibility shift at the next
-- generate_packets, and never changes what one call does. Two consequences:
-- the timed loop *is* the steady-state frame cost (nothing drains, every call
-- repeats the whole visible set), and the churn is there for fidelity rather
-- than for the timing — an unreliable component connects no changed hook, so a
-- world:set stages nothing and the timed pass reads the live columns.
--   world  — UNPAIRED_COMPONENTS unreliable data components across UNPAIRED_CELLS
--     entities (every 4th holding a second one, which streams like any other),
--     RELATIONS unreliable data relations with T targets each and SUBJECTS
--     subjects holding one pair per relation (targets round-robin). every 4th
--     target is named-only (a shared definition, never Replicated), every other
--     4th carries a static entity-level whitelist, so pair cells routinely pay
--     the target-gate narrowing. every unpaired cell and one relation per subject
--     is gated by a component-level whitelist from the pool; every 8th unpaired
--     cell and every 4th subject adds an entity-level whitelist, so cell masks
--     are frequently intersections of two pool masks. no networked tag: a tag
--     cannot be NetworkedUnreliable (an always-streamed tag carries nothing).
--   values — unreliable cells must have serdes hooks, so half the definitions
--     carry a static f64 registration (sized arithmetically, nothing encoded
--     during the fit pass) and half a sizeless varint one (every value encoded
--     and stashed to be sized, then framed behind a u16 prefix), running both
--     of the chunk packer's framing paths in one frame. bench_serdes isolates
--     the two shapes; here the varint widths also drift as the churn raises the
--     values, so chunk boundaries land differently frame to frame.

-- Sweeps: player count P (shard scaling), pool size F (visibility
-- fragmentation — on this channel it splits the frame's cells across more
-- visibility nodes, each serializing and packing its own chunk list, so the
-- frame's serialized bytes and the heaviest client's chunk count both climb
-- with F even as any one client's visible share narrows), and targets per
-- relation T (unique pair ids, hence sections, up to RELATIONS * SUBJECTS
-- distinct). The baseline row
-- (P=64 F=16 T=16) appears in both the F and T sweeps; the pair doubles as a
-- per-run noise gauge (runs on this machine swing ±15-20%). Only
-- generate_unreliable_chunks() is timed, at the default chunk budget; the
-- churn is the untimed analog of the reliable bench's dirty(). User ids are
-- padded to fixed floors so a duplecs version changing its internal id count
-- (shifting every user id downstream) can't swing cross-commit comparisons
-- through hash-order artifacts.

local jecs = require("../../roblox_packages/jecs")
local pair = jecs.pair

local duplecs = require("../../src")

local UNPAIRED_COMPONENTS = 4
local UNPAIRED_CELLS = 512 -- entities, spread round-robin across the unpaired components
local RELATIONS = 4
local SUBJECTS = 512 -- one pair per relation per subject

local REPS = 200
local WARM = 20

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

-- ---- the two serdes shapes, alternating across the definitions (see the
-- header). every value is a non-negative integer, so the sizeless shape
-- varints it — 1-3 bytes at these magnitudes, behind the framing's u16 prefix.

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

-- ---- distinct mask generation: `count` unique random j-subsets of P player
-- indices (0-based), deduped by their numeric bitmask. Identical to
-- bench_generate_packets; j = P/4 keeps C(P, j) well above every swept F, so
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

-- ---- guard: touch the returned chunk lists so the call can't be optimized
-- away. untimed; the call mutates the frame counter regardless, this is
-- belt-and-braces.

local guard = 0

local function chunk_guard(packets)
	local n = 0
	for _player, chunks in packets do
		n += #chunks
	end
	return n
end

local function peak_of(packets)
	-- the heaviest client's chunk count and wire bytes (each maximized
	-- independently). the peak rather than a fixed client's share because a
	-- sampled client's own standing swings with whether the pool's masks happen
	-- to admit it, while the peak is what has to fit the transport's budget
	local peak_chunks = 0
	local peak_bytes = 0
	for _player, chunks in packets do
		local bytes = 0
		for _, chunk in chunks do
			bytes += buffer.len(chunk)
		end
		if #chunks > peak_chunks then
			peak_chunks = #chunks
		end
		if bytes > peak_bytes then
			peak_bytes = bytes
		end
	end
	return peak_chunks, peak_bytes
end

local function frame_bytes_of(packets)
	-- chunks are shared by reference across the clients of a visibility node, so
	-- the unique tally is the frame's serialized size, not the shipped size
	local seen = {}
	local count = 0
	local bytes = 0
	for _player, chunks in packets do
		for _, chunk in chunks do
			if seen[chunk] == nil then
				seen[chunk] = true
				count += 1
				bytes += buffer.len(chunk)
			end
		end
	end
	return count, bytes
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

	-- unreliable definitions: unpaired data components and the relations, hooks
	-- registered before the tracking tag so no cell can ever stream unencodable
	local unpaired = table.create(UNPAIRED_COMPONENTS)
	for c = 1, UNPAIRED_COMPONENTS do
		local component = world:component()
		local hooks = if c % 2 == 1 then f64_serdes else varint_serdes
		world:set(component, net.Serdes, table.clone(hooks))
		world:add(component, net.NetworkedUnreliable)
		unpaired[c] = component
	end

	local relations = table.create(RELATIONS)
	for r = 1, RELATIONS do
		local relation = world:component()
		local hooks = if r % 2 == 1 then f64_serdes else varint_serdes
		world:set(relation, net.Serdes, table.clone(hooks))
		world:add(relation, net.NetworkedUnreliable)
		relations[r] = relation
	end

	-- T targets per relation: every 4th named-only (a shared definition clients
	-- map by name), the rest Replicated with every other 4th carrying a static
	-- entity-level whitelist (applied after allocation, below)
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

	-- unpaired cells: one component each, every 4th holding a second one (a second
	-- streaming cell on the same entity, which the walk's per-entity visibility
	-- cache resolves once)
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
	local subjects = table.create(SUBJECTS)
	for i = 1, SUBJECTS do
		local subject = world:entity()
		for r = 1, RELATIONS do
			world:set(subject, pair(relations[r], targets[r][(i - 1) % T + 1]), i * 5 + r)
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
	-- correctly: every unpaired cell gated on its own component, every subject gated
	-- on one of its relations, all drawing from the pool round-robin
	for i = 1, UNPAIRED_CELLS do
		world:set(cell_entities[i], pair(net.Private, cell_components[i]), pool[(i - 1) % F + 1])
	end
	for i = 1, SUBJECTS do
		world:set(subjects[i], pair(net.Private, relations[(i - 1) % RELATIONS + 1]), pool[i % F + 1])
	end

	-- entity-level filters: every 8th unpaired cell, every other 4th replicated
	-- target, and every 4th subject, so those cells' masks are intersections
	for i = 8, UNPAIRED_CELLS, 8 do
		world:set(cell_entities[i], net.Private, pool[(i * 3) % F + 1])
	end
	for r = 1, RELATIONS do
		for k = 2, T, 4 do
			world:set(targets[r][k], net.Private, pool[(r + k) % F + 1])
		end
	end
	for i = 4, SUBJECTS, 4 do
		world:set(subjects[i], net.Private, pool[(i * 3) % F + 1])
	end

	-- warmup #2: flush the filters into last_visibilities, the masks the
	-- unreliable walk reads — nothing this bench does afterwards moves them, so
	-- this is the one reliable pass the timed loop depends on
	net.generate_packets()

	-- the frame (untimed): a fresh value for every streaming cell
	local tick = 0

	local function dirty()
		tick += 1

		for i = 1, UNPAIRED_CELLS do
			world:set(cell_entities[i], cell_components[i], i * 3 + tick)
			if i % 4 == 0 then
				world:set(cell_entities[i], unpaired[i % UNPAIRED_COMPONENTS + 1], i * 7 + tick)
			end
		end
		for r = 1, RELATIONS do
			local relation = relations[r]
			local relation_targets = targets[r]
			for i = 1, SUBJECTS do
				world:set(subjects[i], pair(relation, relation_targets[(i - 1) % T + 1]), i * 5 + tick)
			end
		end
	end

	for _ = 1, WARM do
		dirty()
		guard += chunk_guard(net.generate_unreliable_chunks())
	end

	-- untimed shape probe: the heaviest client's chunks and the frame's unique
	-- serialized size (every call repeats the same visible set, so any call does)
	dirty()
	local probe = net.generate_unreliable_chunks()
	local peak_chunks, peak_bytes = peak_of(probe)
	local unique_chunks, unique_bytes = frame_bytes_of(probe)
	guard += chunk_guard(probe)

	local elapsed = 0
	for _ = 1, REPS do
		dirty()
		local t = os.clock()
		local packets = net.generate_unreliable_chunks()
		elapsed += os.clock() - t
		guard += chunk_guard(packets)
	end

	print(
		string.format(
			"P=%4d  F=%4d  T=%4d  pair ids=%5d  | %8.4f ms/frame  | peak %3d chunks + %6d B /client"
				.. "  | %5d chunks + %7d B /frame",
			P,
			F,
			T,
			RELATIONS * T,
			1000 * elapsed / REPS,
			peak_chunks,
			peak_bytes,
			unique_chunks,
			unique_bytes
		)
	)
end

print(
	string.format(
		"duplecs unreliable value churn  unpaired=%d cells  pairs=%d  reps=%d  (default chunk budget)",
		UNPAIRED_CELLS + UNPAIRED_CELLS // 4,
		RELATIONS * SUBJECTS,
		REPS
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
