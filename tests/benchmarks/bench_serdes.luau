--!native
--!optimize 2

-- duplecs serdes-mode benchmark: isolates the value-encoding paths of
-- generate_packets (and the chunk path of generate_unreliable_chunks) by
-- churning every cell of one data component each frame under broadcast
-- visibility -- one shared section per frame, so the timed differences
-- between rows are the serdes work itself plus the bytes it puts on the
-- wire. Rows:
--   hookless   -- no registration; values ride the packet's side array
--   serdes-fix -- hooks with a static size (arithmetic sizing; one fresh
--                 buffer per value, copied with no per-value framing)
--   serdes-var -- hooks without a static size (one fresh buffer per value,
--                 copied behind a u16 prefix)
-- Each row times both halves: `gen` is the server's generate call, `rec` is
-- the first client's packet (or chunk list) reconciled into a live client
-- world -- where the serdes rows pay one fresh buffer.create per value on
-- decode. Both columns report the mean and the p99 frame, since allocation
-- cost lives in GC-assist tails a mean hides; the two worlds share one luau
-- VM, so either timed region may absorb assists provoked by the other
-- half's garbage -- comparable across rows, which all run the identical
-- harness. Payloads are strings of exactly L bytes for every row --
-- deliberately fixed-length even in the sizeless row, so rows compare at
-- equal encode work per value. User ids are padded to fixed floors like the
-- other benches so a duplecs version changing its internal id count can't
-- swing cross-commit comparisons.

local jecs = require("../../roblox_packages/jecs")

local duplecs = require("../../src")

local CELLS = 512
local PLAYERS = 32

local REPS = 500
local WARM = 20

local VALUE_SIZES = { 8, 64, 1024 }
local UNRELIABLE_VALUE_SIZES = { 8, 64 } -- bounded by the default 980-byte chunk budget

-- fixed id floors (see the header): user components and entities always start
-- here no matter how many ids duplecs claims internally
local COMPONENT_FLOOR = 32
local ENTITY_FLOOR = 4096

-- ---- guard: touch the returned packets so the call can't be optimized away.

local guard = 0

local function packet_guard(packets)
	local n = 0
	for _client in packets do
		n += 1
	end
	return n
end

local function bytes_of(packets, client)
	-- wire bytes of one client's packet (buffer only), plus the count of
	-- out-of-band values it carries (nonzero only in the hookless row)
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

local function chunk_bytes_of(packets, client)
	-- summed wire bytes and chunk count of one client's chunk list
	local chunks = packets[client]
	if chunks == nil then
		return 0, 0
	end
	local bytes = 0
	for _, chunk in chunks do
		bytes += buffer.len(chunk)
	end
	return bytes, #chunks
end

local function check(condition, label)
	if not condition then
		error(`sanity check failed: {label}`)
	end
end

-- the p-th percentile frame of one row's samples (sorts in place, so take
-- the mean off the running sum, not the array)
local function percentile(samples, p)
	table.sort(samples)
	return samples[math.ceil(p * #samples)]
end

-- ---- the per-row registrations; nil means hookless --------------------------

local function make_serdes(mode, L)
	if mode == "hookless" then
		return nil
	end
	return {
		size = if mode == "serdes-fix" then L else nil,
		encode = function(value)
			local encoded = buffer.create(#value)
			buffer.writestring(encoded, 0, value)
			return encoded
		end,
		decode = function(encoded)
			return buffer.readstring(encoded, 0, buffer.len(encoded))
		end,
	}
end

-- ---- shared world setup ------------------------------------------------------

local function build_world(mode, L, tracking_tag_of)
	local world = jecs.World.new()
	local net = duplecs.server(world)

	local client_world = jecs.World.new()
	local client = duplecs.client(client_world)

	-- pad user ids to the fixed floors on both worlds (padding entities stay
	-- alive in the root archetype, so no walked path ever sees them)
	while (world:component() :: any) < COMPONENT_FLOOR do
	end
	while (world:entity() :: any) < ENTITY_FLOOR do
	end
	while (client_world:component() :: any) < COMPONENT_FLOOR do
	end
	while (client_world:entity() :: any) < ENTITY_FLOOR do
	end

	local component = world:component()
	world:add(component, tracking_tag_of(net))
	local client_component = client_world:component()
	client.set_client_entity(component, client_component)

	-- one registration table set on both worlds (hooks must be symmetric;
	-- the first store freezes it, which the second accepts as-is)
	local serdes = make_serdes(mode, L)
	if serdes ~= nil then
		world:set(component, net.Serdes, serdes)
		client_world:set(client_component, client.Serdes, serdes)
	end

	-- dummy player stand-ins; the module only uses them as table keys. the
	-- first player doubles as the viewer whose packets reconcile into
	-- client_world, with the reconcile half timed.
	local players = table.create(PLAYERS) :: { any }
	for i = 1, PLAYERS do
		players[i] = {}
		net.add_client(players[i])
	end

	-- two prebuilt L-byte payloads, alternated per frame so every set is a
	-- fresh change without per-frame string building
	local payload_a = string.rep("a", L)
	local payload_b = string.rep("b", L)

	local entities = table.create(CELLS)
	for i = 1, CELLS do
		local entity = world:entity()
		world:set(entity, component, payload_a)
		world:add(entity, net.Replicated)
		entities[i] = entity
	end

	-- warmup #1 allocates the players' slots (full packets) and flushes the
	-- seeded cells into last_visibilities; the viewer's full packet seeds the
	-- client world's entity map (untimed)
	local packets = net.generate_packets()
	client.reconcile_packet(packets[players[1]])

	local tick = 0
	local function dirty()
		tick += 1
		local payload = if tick % 2 == 0 then payload_a else payload_b
		for i = 1, CELLS do
			world:set(entities[i], component, payload)
		end
	end

	return {
		world = world,
		net = net,
		client_world = client_world,
		client = client,
		component = component,
		client_component = client_component,
		players = players,
		entities = entities,
		payload_a = payload_a,
		payload_b = payload_b,
		dirty = dirty,
	}
end

-- ---- runs ---------------------------------------------------------------------

local function run(mode, L)
	local link = build_world(mode, L, function(net)
		return net.Networked
	end)
	local net = link.net
	local dirty = link.dirty
	local viewer = link.players[1]
	local reconcile_packet = link.client.reconcile_packet

	for _ = 1, WARM do
		dirty()
		local packets = net.generate_packets()
		guard += packet_guard(packets)
		reconcile_packet(packets[viewer])
	end

	local gen_elapsed, rec_elapsed = 0, 0
	local gen_samples = table.create(REPS)
	local rec_samples = table.create(REPS)
	local bytes, variants = 0, 0
	for rep = 1, REPS do
		dirty()
		local t = os.clock()
		local packets = net.generate_packets()
		local gen = os.clock() - t
		gen_elapsed += gen
		gen_samples[rep] = gen
		guard += packet_guard(packets)
		local packet = packets[viewer]
		t = os.clock()
		reconcile_packet(packet)
		local rec = os.clock() - t
		rec_elapsed += rec
		rec_samples[rep] = rec
		bytes, variants = bytes_of(packets, viewer)
	end

	-- the decoded values actually landed in the client world: the last dirty
	-- was tick WARM + REPS, so its payload parity is known
	local expected = if (WARM + REPS) % 2 == 0 then link.payload_a else link.payload_b
	local client_entity = link.client.get_client_entity(link.entities[1])
	check(client_entity ~= nil, `{mode}: first entity mapped`)
	check(link.client_world:get(client_entity, link.client_component) == expected, `{mode}: last value applied`)

	print(
		string.format(
			"%-10s  L=%5d  | gen %8.4f ms/f  p99 %8.4f  | rec %8.4f ms/f  p99 %8.4f  | %6d B + %4d values /client",
			mode,
			L,
			1000 * gen_elapsed / REPS,
			1000 * percentile(gen_samples, 0.99),
			1000 * rec_elapsed / REPS,
			1000 * percentile(rec_samples, 0.99),
			bytes,
			variants
		)
	)
end

local function run_unreliable(mode, L)
	local link = build_world(mode, L, function(net)
		return net.NetworkedUnreliable
	end)
	local net = link.net
	local viewer = link.players[1]
	local reconcile_chunk = link.client.reconcile_chunk

	-- unreliable cells re-read live every call, so the timed loop needs no
	-- dirty; one delta flushes the memberships into the last-sent masks first
	local flush = net.generate_packets()[viewer]
	if flush ~= nil then
		link.client.reconcile_packet(flush)
	end

	-- re-set every cell to the b payload -- no reliable delta follows
	-- (unreliable tracking connects no changed hook), so the end check proves
	-- the values arrived through the chunk path rather than the initial full
	for _, entity in link.entities do
		link.world:set(entity, link.component, link.payload_b)
	end

	for _ = 1, WARM do
		local packets = net.generate_unreliable_chunks()
		guard += packet_guard(packets)
		for _, chunk in packets[viewer] do
			reconcile_chunk(chunk)
		end
	end

	local gen_elapsed, rec_elapsed = 0, 0
	local gen_samples = table.create(REPS)
	local rec_samples = table.create(REPS)
	local bytes, chunks = 0, 0
	for rep = 1, REPS do
		local t = os.clock()
		local packets = net.generate_unreliable_chunks()
		local gen = os.clock() - t
		gen_elapsed += gen
		gen_samples[rep] = gen
		guard += packet_guard(packets)
		local chunk_list = packets[viewer]
		t = os.clock()
		for _, chunk in chunk_list do
			reconcile_chunk(chunk)
		end
		local rec = os.clock() - t
		rec_elapsed += rec
		rec_samples[rep] = rec
		bytes, chunks = chunk_bytes_of(packets, viewer)
	end

	local client_entity = link.client.get_client_entity(link.entities[1])
	check(client_entity ~= nil, `{mode}: first entity mapped`)
	check(link.client_world:get(client_entity, link.client_component) == link.payload_b, `{mode}: chunk value applied`)

	print(
		string.format(
			"%-10s  L=%5d  | gen %8.4f ms/f  p99 %8.4f  | rec %8.4f ms/f  p99 %8.4f  | %6d B in %3d chunks /client",
			mode,
			L,
			1000 * gen_elapsed / REPS,
			1000 * percentile(gen_samples, 0.99),
			1000 * rec_elapsed / REPS,
			1000 * percentile(rec_samples, 0.99),
			bytes,
			chunks
		)
	)
end

print(
	string.format(
		"duplecs serdes modes  cells=%d  players=%d (broadcast, one shared section)  reps=%d",
		CELLS,
		PLAYERS,
		REPS
	)
)
print("")

print("reliable sweep (gen = generate_packets, rec = reconcile_packet of one client's packet):")
for _, L in VALUE_SIZES do
	run("hookless", L)
	run("serdes-fix", L)
	run("serdes-var", L)
	print("")
end

print("unreliable sweep (gen = generate_unreliable_chunks at the default chunk budget, rec = one client's chunks):")
for _, L in UNRELIABLE_VALUE_SIZES do
	run_unreliable("serdes-fix", L)
	run_unreliable("serdes-var", L)
	print("")
end

print("guard:", guard)

return true
