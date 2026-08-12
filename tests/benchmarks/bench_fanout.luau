--!native
--!optimize 2

-- duplecs generate_packets benchmark — fan-out sweep. Isolates the cost of the
-- per-cell viewer count j from the mask-diversity effect that dominates
-- bench_generate_packets. There, j is derived from an arithmetic progression
-- whose stride is floor(P/j), so raising j collapses cells onto fewer distinct
-- masks (one section per component at j = P) and cost *drops* — j and mask
-- diversity move together. Here the number of *distinct* masks is pinned at
-- MASK_COUNT and j is swept as the size of each mask, so j moves only fan-out:
-- longer client lists per section and more section references per client. With
-- diversity held fixed, cost should rise ~linearly in j (mask expansion is
-- MASK_COUNT * j attaches, and total (client, section) references scale the
-- same way), which is the clean fan-out signal.

-- Player count is fixed at 128 (four shards), so masks routinely span shard
-- boundaries and the sweep exercises cross-shard section sharing alongside
-- fan-out. Masks are random distinct j-subsets drawn exactly like
-- bench_whitelist_overlap; MASK_COUNT stays <= C(P, j) across the swept range
-- (P and P-1 at the j = 1 / j = P-1 extremes both exceed it) so the pool is
-- always fillable. j never reaches P: at j = P every mask is the full mask,
-- forcing diversity to 1 and defeating the point.

-- Setup mirrors bench_whitelist_overlap: warmup #1 allocates the players (full
-- packets), whitelists are applied, warmup #2 flushes them into
-- last_visibilities, then each timed frame bumps every cell's value (a pure send
-- to its j viewers) and times generate_packets() only.

local jecs = require("../../roblox_packages/jecs")
local pair = jecs.pair

local duplecs = require("../../src")

local NUM_COMPONENTS = 4
local CELLS_PER_COMPONENT = 128
local REPS = 300
local NUM_PLAYERS = 128
local MASK_COUNT = 16 -- distinct masks, held fixed while j sweeps
local VIEWER_COUNTS = { 1, 2, 4, 8, 16, 24, 31, 47, 63, 95, 127 } -- per cell; each < P

-- ---- distinct mask generation: `count` unique random j-subsets of P player
-- indices (0-based), deduped by their numeric bitmask. Identical to
-- bench_whitelist_overlap; C(P, j) stays well above MASK_COUNT across the swept
-- j range, so the retry loop is effectively free.

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

local function run(j)
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
	-- correctly. cell i draws from the shared MASK_COUNT-sized pool round-robin,
	-- so diversity stays pinned at MASK_COUNT and only mask *size* (j) varies.
	local masks = generate_masks(MASK_COUNT, j, NUM_PLAYERS)
	for cell = 1, cell_count do
		local indices = masks[(cell - 1) % MASK_COUNT + 1]
		local whitelist = {}
		for _, index in indices do
			whitelist[players[index + 1]] = true
		end
		world:set(cell_entities[cell], pair(net.Private, cell_components[cell]), whitelist)
	end

	-- warmup #2: flush the whitelist visibility changes so last_visibilities
	-- holds each cell's j-viewer mask before the timed deltas begin
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
			"j=%2d  masks=%3d  sends/frame=%6d  | generate_packets=%8.2fms  (%.4fms/frame)",
			j,
			MASK_COUNT,
			j * NUM_COMPONENTS * CELLS_PER_COMPONENT,
			ms,
			ms / REPS
		)
	)
end

print(
	string.format(
		"components=%d  cells/comp=%d  players=%d  masks=%d  reps=%d",
		NUM_COMPONENTS,
		CELLS_PER_COMPONENT,
		NUM_PLAYERS,
		MASK_COUNT,
		REPS
	)
)

for _, j in VIEWER_COUNTS do
	if j <= NUM_PLAYERS then
		run(j)
	end
end

print("guard:", guard)

return true
