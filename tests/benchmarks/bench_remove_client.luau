--!native
--!optimize 2

-- duplecs remove_client benchmark — departure-time privacy filter pruning.
-- remove_client walks every cached privacy filter to prune the departing
-- client's key, so departure cost scales with the total number of cached
-- filters in the world plus a clone/freeze per filter actually naming the
-- client. Two sweeps over the total filter count:
--
--   scattered — 8-member whitelists, the departer named in at most
--   NAMED_FILTERS of them: the scan dominates, the clones are a constant.
--
--   pessimistic — every filter is a name-everyone whitelist (all clients
--   plus the departer), so a departure clones every filter in the world:
--   the naive shape of whitelisting almost every user (e.g. wide distance
--   gating) on individually-tagged objects (e.g. every part).
--
-- Each row times two departures: a client named in no filter (the pure scan)
-- and the named departer. Between timed removals the departed client is
-- re-added and the filters naming them are re-set, then an untimed
-- generate_packets flushes the churn, so every timed remove_client runs
-- against identical state: an allocated client and a fully cached filter
-- store.

local jecs = require("../../roblox_packages/jecs")
local pair = jecs.pair

local duplecs = require("../../src")

local NUM_CLIENTS = 64
local WHITELIST_SIZE = 8
local NAMED_FILTERS = 64
local REPS = 100
-- the pessimistic rows re-set every filter between reps, so they take fewer
-- (and their timed removals are large enough to stay stable at this count)
local PESSIMISTIC_REPS = 20
local FILTER_COUNTS = { 0, 256, 1024, 4096, 16384 }

-- ---- guard: fold observable state into a live sum so the timed calls can't
-- be optimized away. remove_client mutates module state regardless, this is
-- belt-and-braces.

local guard = 0

-- ---- run ------------------------------------------------------------------

local function run(filter_count, whitelist_size, named_count, reps)
	local world = jecs.World.new()
	local net = duplecs.server(world)

	local component = world:component()
	world:add(component, net.Networked)

	-- dummy client stand-ins; the module only uses them as table keys. the two
	-- departers are tracked alongside the pool so their slots exist before the
	-- filters cache.
	local clients = table.create(NUM_CLIENTS) :: { any }
	for i = 1, NUM_CLIENTS do
		clients[i] = {}
	end
	local unnamed_departer = {}
	local named_departer = {}

	for _, client in clients do
		net.add_client(client)
	end
	net.add_client(unnamed_departer)
	net.add_client(named_departer)
	net.generate_packets()

	-- one per-component whitelist per entity, drawing whitelist_size pool
	-- members round-robin (the full pool when whitelist_size == NUM_CLIENTS);
	-- the first named_count entities additionally name the named departer. the
	-- member lists are kept so the per-rep re-sets rebuild identical filters.
	local entities = table.create(filter_count)
	local members = table.create(filter_count)
	for i = 1, filter_count do
		local entity = world:entity()
		world:set(entity, component, i)
		world:add(entity, net.Replicated)
		entities[i] = entity
		local picked = table.create(whitelist_size)
		local whitelist = {}
		for k = 1, whitelist_size do
			local member = clients[(i * 3 + k) % NUM_CLIENTS + 1]
			picked[k] = member
			whitelist[member] = true
		end
		if i <= named_count then
			whitelist[named_departer] = true
		end
		members[i] = picked
		world:set(entity, pair(net.Private, component), whitelist)
	end
	net.generate_packets()

	-- rebuilds the whitelists that named the departer, who is pending again
	-- after the rejoin (sanitization keeps pending clients cached bitless, and
	-- the slot grant at the next generate_packets restores their bit)
	local function rename_departer()
		for i = 1, named_count do
			local whitelist = {}
			for _, member in members[i] do
				whitelist[member] = true
			end
			whitelist[named_departer] = true
			world:set(entities[i], pair(net.Private, component), whitelist)
		end
	end

	local scan_elapsed = 0
	for _ = 1, reps do
		local t = os.clock()
		net.remove_client(unnamed_departer)
		scan_elapsed += os.clock() - t
		guard += if net.is_client_tracked(unnamed_departer) then 1 else 0
		net.add_client(unnamed_departer)
		net.generate_packets()
	end

	local named_elapsed = 0
	for _ = 1, reps do
		local t = os.clock()
		net.remove_client(named_departer)
		named_elapsed += os.clock() - t
		guard += if net.is_client_tracked(named_departer) then 1 else 0
		net.add_client(named_departer)
		rename_departer()
		net.generate_packets()
	end

	local scan_us = 1e6 * scan_elapsed / reps
	local named_us = 1e6 * named_elapsed / reps
	print(
		string.format(
			"filters=%6d  | unnamed departure=%8.2fus  named-in-%d departure=%8.2fus",
			filter_count,
			scan_us,
			named_count,
			named_us
		)
	)
end

print(string.format("clients=%d", NUM_CLIENTS))

print(
	string.format(
		"scattered: whitelist size=%d, departer named in at most %d, reps=%d",
		WHITELIST_SIZE,
		NAMED_FILTERS,
		REPS
	)
)
for _, filter_count in FILTER_COUNTS do
	run(filter_count, WHITELIST_SIZE, math.min(NAMED_FILTERS, filter_count), REPS)
end

print(
	string.format(
		"pessimistic: whitelist size=%d (everyone + departer), departer named in every filter, reps=%d",
		NUM_CLIENTS,
		PESSIMISTIC_REPS
	)
)
for _, filter_count in FILTER_COUNTS do
	run(filter_count, NUM_CLIENTS, filter_count, PESSIMISTIC_REPS)
end

print("guard:", guard)

return true
