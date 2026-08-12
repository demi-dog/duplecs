--!native
--!optimize 2

-- duplecs generate_packets benchmark — whitelist overlap sweep for the sections
-- implementation. Player count and per-cell viewer count stay fixed (32 players,
-- 16 viewers per cell) while the number of *distinct* whitelists shared across
-- cells sweeps from 1 (every cell the same mask — best case: one section per
-- component, expanded once) to cell_count (every cell its own mask — worst
-- case: one section per cell, bucketing buys nothing).

-- VIEWERS_PER_CELL is 16 rather than 32: whitelisting all 32 of 32 players makes
-- every mask the full mask, leaving nothing to vary; 16-of-32 maximizes the
-- space of possible masks. Sections are keyed by *exact* mask, so partially
-- overlapping whitelists share nothing — only identical ones do — which makes
-- distinct-mask count the axis spanning best to worst case. Masks are random
-- distinct 16-subsets, so pairwise partial overlap is present but irrelevant.

-- Setup mirrors duplecs_bench_generate_packets: warmup #1 allocates the players
-- (full packets), whitelists are applied, warmup #2 flushes them into
-- last_visibilities, then each timed frame bumps every cell's value (a pure
-- send to its 16 viewers) and times generate_packets() only.

local jecs = require("../../roblox_packages/jecs")
local pair = jecs.pair

local duplecs = require("../../src")

local NUM_COMPONENTS = 4
local CELLS_PER_COMPONENT = 128
local REPS = 300
local NUM_PLAYERS = 32
local VIEWERS_PER_CELL = 16
local MASK_COUNTS = { 1, 2, 4, 8, 16, 32, 64, 128, 256, 512 }

-- ---- distinct mask generation: `count` unique random j-subsets of P player
-- indices (0-based), deduped by their numeric bitmask. C(32,16) ≈ 6e8, so
-- collisions are vanishingly rare and the retry loop is effectively free.

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

-- ---- run ------------------------------------------------------------------

local function run(mask_count)
	local world = jecs.World.new()
	local net = duplecs.server(world)

	-- dummy player stand-ins; the module only uses them as table keys
	local players = table.create(NUM_PLAYERS) :: { any }
	for i = 1, NUM_PLAYERS do
		players[i] = {}
	end

	-- networked data components
	local components = table.create(NUM_COMPONENTS)
	for c = 1, NUM_COMPONENTS do
		local component = world:component()
		world:add(component, net.Networked)
		components[c] = component
	end

	-- CELLS_PER_COMPONENT distinct entities per component, each Replicated and
	-- holding that one component. flat arrays drive the whitelist/value loops.
	local cell_entities = table.create(NUM_COMPONENTS * CELLS_PER_COMPONENT)
	local cell_components = table.create(NUM_COMPONENTS * CELLS_PER_COMPONENT)
	local cell_count = 0
	for c = 1, NUM_COMPONENTS do
		local component = components[c]
		for _ = 1, CELLS_PER_COMPONENT do
			cell_count += 1
			local entity = world:entity()
			world:set(entity, component, cell_count * 3)
			world:add(entity, net.Replicated)
			cell_entities[cell_count] = entity
			cell_components[cell_count] = component
		end
	end

	-- queue every player, then warmup #1 allocates their slots (full packets)
	for _, player in players do
		net.add_client(player)
	end
	net.generate_packets()

	-- per-cell whitelists, now that players are tracked so masks derive
	-- correctly. cell i draws from the shared mask pool round-robin, so
	-- mask_count controls exactly how many cells resolve to identical masks.
	local masks = generate_masks(mask_count, VIEWERS_PER_CELL, NUM_PLAYERS)
	for cell = 1, cell_count do
		local indices = masks[(cell - 1) % mask_count + 1]
		local whitelist = {}
		for _, index in indices do
			whitelist[players[index + 1]] = true
		end
		world:set(cell_entities[cell], pair(net.Private, cell_components[cell]), whitelist)
	end

	-- warmup #2: flush the whitelist visibility changes so last_visibilities
	-- holds each cell's viewer mask before the timed deltas begin
	net.generate_packets()

	-- untimed value bump: a fresh value for every cell, staging a value send to
	-- its current viewer set
	local tick = 0
	local function dirty()
		tick += 1
		for cell = 1, cell_count do
			world:set(cell_entities[cell], cell_components[cell], cell * 3 + tick)
		end
	end

	local elapsed = 0
	for _ = 1, REPS do
		dirty()
		local t = os.clock()
		local packets = net.generate_packets()
		elapsed += os.clock() - t
		guard += packet_guard(packets)
	end

	local ms = 1000 * elapsed
	print(
		string.format(
			"masks=%4d  cells/mask=%5.1f  | generate_packets=%8.2fms  (%.4fms/frame)",
			mask_count,
			cell_count / mask_count,
			ms,
			ms / REPS
		)
	)
end

print(
	string.format(
		"components=%d  cells/comp=%d  players=%d  viewers/cell=%d  writes/frame=%d  reps=%d",
		NUM_COMPONENTS,
		CELLS_PER_COMPONENT,
		NUM_PLAYERS,
		VIEWERS_PER_CELL,
		NUM_COMPONENTS * CELLS_PER_COMPONENT,
		REPS
	)
)

for _, mask_count in MASK_COUNTS do
	run(mask_count)
end

print("guard:", guard)

return true
