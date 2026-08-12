--!native
--!optimize 2

-- duplecs generate_packets benchmark — sections-per-node sweep. Isolates the
-- per-section costs downstream of the resolve passes (finalize, scatter, and
-- assembly) from the per-cell costs that dominate the other benches: every
-- cell here is visible to every client (one accumulated-visibility node), so
-- sweeping the component count C sweeps only how many sections share that
-- node. Cells per component stays small and fixed, keeping encode and copy
-- byte counts low so the per-section call overhead is what moves.

-- Player count is fixed at 100 (four shards), so the shared node routinely
-- exercises the cross-shard trie path alongside the fan-out. Each timed frame
-- bumps every cell's value (a pure send to all P viewers) and times
-- generate_packets() only.

local jecs = require("../../roblox_packages/jecs")

local duplecs = require("../../src")

local CELLS_PER_COMPONENT = 8
local REPS = 300
local NUM_PLAYERS = 100
local COMPONENT_COUNTS = { 4, 16, 64, 128 }

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

local function run(num_components)
	local world = jecs.World.new()
	local net = duplecs.server(world)

	-- dummy player stand-ins; the module only uses them as table keys
	local players = table.create(NUM_PLAYERS) :: { any }
	for i = 1, NUM_PLAYERS do
		players[i] = {}
	end

	-- networked data components
	local components = table.create(num_components)
	for c = 1, num_components do
		local component = world:component()
		world:add(component, net.Networked)
		components[c] = component
	end

	-- CELLS_PER_COMPONENT distinct entities per component, each Replicated and
	-- holding that one component; no privacy filters, so every cell shares the
	-- one all-clients visibility node
	local cell_entities = table.create(num_components * CELLS_PER_COMPONENT)
	local cell_components = table.create(num_components * CELLS_PER_COMPONENT)
	local cell_count = 0
	for c = 1, num_components do
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

	-- queue every player, then a warmup call allocates their slots (full
	-- packets) and settles last_visibilities before the timed deltas begin
	for _, player in players do
		net.add_client(player)
	end
	net.generate_packets()

	-- untimed value bump: a fresh value for every cell, staging a value send to
	-- every client
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
			"C=%3d  sections/frame=%3d  sends/frame=%5d  | generate_packets=%8.2fms  (%.4fms/frame)",
			num_components,
			num_components,
			num_components * CELLS_PER_COMPONENT,
			ms,
			ms / REPS
		)
	)
end

print(
	string.format(
		"cells/comp=%d  players=%d  reps=%d  broadcast visibility (one node)",
		CELLS_PER_COMPONENT,
		NUM_PLAYERS,
		REPS
	)
)

for _, num_components in COMPONENT_COUNTS do
	run(num_components)
end

print("guard:", guard)

return true
