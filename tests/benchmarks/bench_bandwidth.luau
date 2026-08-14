--!native
--!optimize 2

-- duplecs wire-size benchmark — the paired source of the numbers in
-- docs/guides/013-bandwidth.md. Nothing here is timed: every row builds a
-- workload, generates one frame, and reports one probe client's packet size —
-- buffer bytes plus, separately, the count of hookless values riding the
-- packet's side array (the transport serializes those itself, so their wire
-- cost is the transport's, not the buffer's). Bytes are deterministic: the
-- same shapes produce the same bytes on any machine, so a changed number
-- across duplecs versions means the wire format moved, not the hardware.
--
-- Sections:
--   deltas       — a settled frame (no packet at all), value sets under each
--     encoding (hookless, static-size serdes, sizeless serdes), tag and
--     component toggles, pair values (shared target vs distinct targets),
--     spawn and despawn frames, and a shared-name announcement frame.
--   joiner       — one client's full packet from a populated world (the same
--     world shape as bench_overhead's joiner), with per-cell bytes.
--   unreliable   — generate_unreliable_chunks swept across visible-value
--     counts: chunk counts, total bytes, and bytes per value.
--   fragmentation — the same changed values encoded as one shared section vs
--     one section per cell (distinct 16-viewer whitelists per cell), the
--     framing-bloat extreme.
--
-- To refresh the guide after a wire change: run this bench and re-derive the
-- guide's tables from its output (the guide states the workload shapes, which
-- must move with this file's constants if they change). Broadcast visibility
-- and P=32 unless a row states otherwise; per-client bytes don't depend on P
-- at broadcast, since every client's packet carries the same content.

local jecs = require("../../roblox_packages/jecs")
local pair = jecs.pair

local duplecs = require("../../src")

local CELL_COUNTS = { 1, 64, 1024 } -- hookless value-churn row sizes
local N = 64 -- every other delta row's op count
local NAMES = 8 -- announced definitions in the names row
local FULL_BASE = 1024 -- joiner-world entities (shape mirrors bench_overhead's joiner)
local FULL_PAIRS = 256 -- joiner-world pair cells
local UNRELIABLE_COUNTS = { 16, 128, 512 } -- visible f64 cells per chunk sweep row
local FRAG_CELLS = 512 -- fragmentation-row cells
local FRAG_VIEWERS = 16 -- viewers per cell (the probe plus 15 others)
local FRAG_MASK_COUNTS = { 1, 512 } -- distinct whitelists: fully shared vs one per cell

local DEFAULT_P = 32

-- fixed id floors (as in bench_overhead): user components and entities always
-- start here no matter how many ids duplecs claims internally
local COMPONENT_FLOOR = 32
local ENTITY_FLOOR = 4096

local f64_static_serdes = {
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

-- the same 8-byte encoding without a declared size, so every value pays the
-- u16 length prefix a sizeless registration rides behind
local f64_sizeless_serdes = {
	encode = f64_static_serdes.encode,
	decode = f64_static_serdes.decode,
}

-- ---- world construction: a duplecs server world with P allocated clients,
-- settled so the next generate_packets returns pure deltas. players[1] is the
-- probe every row measures.

local function make_world(P)
	local world = jecs.World.new()
	local net = duplecs.server(world)

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

-- ---- reporting: buffer bytes plus the side-array value count (hookless
-- sections' values, one array per section, concatenated per grouped section)

local function packet_bytes(packet)
	if packet == nil then
		return 0, 0
	end
	local side = 0
	if packet.values ~= nil then
		for _, section_values in packet.values do
			side += #section_values
		end
	end
	return buffer.len(packet.data), side
end

local function row(label, ops, bytes, side)
	print(string.format("%-52s ops=%5d | %6d B | %4d side values | %6.2f B/op", label, ops, bytes, side, bytes / ops))
end

-- ---- delta rows ---------------------------------------------------------------

-- a settled world: everything visible, nothing changed since the last call —
-- the probe receives no packet at all
local function run_settled_row()
	local world, net, players = make_world(DEFAULT_P)
	local component = world:component()
	world:add(component, net.Networked)
	local entity = world:entity()
	world:set(entity, component, 1)
	world:add(entity, net.Replicated)
	net.generate_packets()

	local packet = net.generate_packets()[players[1]]
	assert(packet == nil, "a settled frame should return no packet")
	print(string.format("%-52s ops=    0 | no packet (0 B)", "settled frame"))
end

-- value churn: `cells` entities holding one data component each, every cell
-- set fresh in the measured frame. mode picks the value encoding.
local function run_value_row(cells, mode)
	local world, net, players = make_world(DEFAULT_P)
	local component = world:component()
	if mode == "static" then
		world:set(component, net.Serdes, table.clone(f64_static_serdes))
	elseif mode == "sizeless" then
		world:set(component, net.Serdes, table.clone(f64_sizeless_serdes))
	end
	world:add(component, net.Networked)

	local entities = table.create(cells)
	for i = 1, cells do
		local entity = world:entity()
		world:set(entity, component, i)
		world:add(entity, net.Replicated)
		entities[i] = entity
	end
	net.generate_packets()

	for i = 1, cells do
		world:set(entities[i], component, i + 0.5)
	end
	local bytes, side = packet_bytes(net.generate_packets()[players[1]])
	row(string.format("value sets: %s", mode), cells, bytes, side)
end

-- tag toggles: N tagged entities; one frame removes every tag, the next adds
-- them back (valueless entries)
local function run_tag_rows()
	local world, net, players = make_world(DEFAULT_P)
	local tag = world:entity()
	world:add(tag, net.Networked)

	local entities = table.create(N)
	for i = 1, N do
		local entity = world:entity()
		world:add(entity, tag)
		world:add(entity, net.Replicated)
		entities[i] = entity
	end
	net.generate_packets()

	for i = 1, N do
		world:remove(entities[i], tag)
	end
	local bytes, side = packet_bytes(net.generate_packets()[players[1]])
	row("tag removes", N, bytes, side)

	for i = 1, N do
		world:add(entities[i], tag)
	end
	bytes, side = packet_bytes(net.generate_packets()[players[1]])
	row("tag adds (valueless entries)", N, bytes, side)
end

-- component removes: N entities each dropping their data component
local function run_remove_row()
	local world, net, players = make_world(DEFAULT_P)
	local component = world:component()
	world:add(component, net.Networked)

	local entities = table.create(N)
	for i = 1, N do
		local entity = world:entity()
		world:set(entity, component, i)
		world:add(entity, net.Replicated)
		entities[i] = entity
	end
	net.generate_packets()

	for i = 1, N do
		world:remove(entities[i], component)
	end
	local bytes, side = packet_bytes(net.generate_packets()[players[1]])
	row("component removes", N, bytes, side)
end

-- pair values, shared target: N subjects each setting a data pair on one
-- common target (a single-target pair section)
local function run_pair_shared_row()
	local world, net, players = make_world(DEFAULT_P)
	local relation = world:component()
	world:add(relation, net.Networked)
	local target = world:entity()
	world:add(target, net.Replicated)

	local subjects = table.create(N)
	for i = 1, N do
		local subject = world:entity()
		world:set(subject, pair(relation, target), i)
		world:add(subject, net.Replicated)
		subjects[i] = subject
	end
	net.generate_packets()

	for i = 1, N do
		world:set(subjects[i], pair(relation, target), i + 0.5)
	end
	local bytes, side = packet_bytes(net.generate_packets()[players[1]])
	row("pair values: one shared target", N, bytes, side)
end

-- pair values, distinct targets: N subjects each setting a data pair on their
-- own target (one relation-grouped section, one run per target)
local function run_pair_distinct_row()
	local world, net, players = make_world(DEFAULT_P)
	local relation = world:component()
	world:add(relation, net.Networked)

	local subjects = table.create(N)
	local pairs_by_subject = table.create(N)
	for i = 1, N do
		local target = world:entity()
		world:add(target, net.Replicated)
		local subject = world:entity()
		world:set(subject, pair(relation, target), i)
		world:add(subject, net.Replicated)
		subjects[i] = subject
		pairs_by_subject[i] = pair(relation, target)
	end
	net.generate_packets()

	for i = 1, N do
		world:set(subjects[i], pairs_by_subject[i], i + 0.5)
	end
	local bytes, side = packet_bytes(net.generate_packets()[players[1]])
	row("pair values: distinct targets", N, bytes, side)
end

-- entity lifecycle: one frame spawning N entities (two hookless data
-- components each), the next deleting them all
local function run_lifecycle_rows()
	local world, net, players = make_world(DEFAULT_P)
	local component_a = world:component()
	local component_b = world:component()
	world:add(component_a, net.Networked)
	world:add(component_b, net.Networked)
	net.generate_packets()

	local entities = table.create(N)
	for i = 1, N do
		local entity = world:entity()
		world:set(entity, component_a, i)
		world:set(entity, component_b, i * 2)
		world:add(entity, net.Replicated)
		entities[i] = entity
	end
	local bytes, side = packet_bytes(net.generate_packets()[players[1]])
	row("spawns: 2 tracked cells each", N, bytes, side)

	for i = 1, N do
		world:delete(entities[i])
	end
	bytes, side = packet_bytes(net.generate_packets()[players[1]])
	row("despawns", N, bytes, side)
end

-- shared names: NAMES fresh definitions named (12-byte names) and networked
-- after the settle, so the measured frame carries only their announcements
local function run_names_row()
	local world, net, players = make_world(DEFAULT_P)
	net.generate_packets()

	for i = 1, NAMES do
		local component = world:component()
		world:set(component, jecs.Name, string.format("wire_name_%02d", i))
		world:add(component, net.Networked)
	end
	local bytes, side = packet_bytes(net.generate_packets()[players[1]])
	row("name announcements (12-byte names)", NAMES, bytes, side)
end

-- ---- joiner -------------------------------------------------------------------

-- one client's full packet from a populated world: FULL_BASE entities across
-- four data components, a tag on every fourth, and FULL_PAIRS pair cells on
-- distinct targets — the same shape as bench_overhead's joiner
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

	local viewer = {}
	net.add_client(viewer)
	local bytes, side = packet_bytes(net.generate_packets()[viewer])

	local cells = FULL_BASE + FULL_BASE // 4 + FULL_PAIRS
	print(
		string.format(
			"full packet: %4d entities, %4d cells | %6d B | %4d side values | %6.2f B/cell | %6.2f B/entity",
			FULL_BASE,
			cells,
			bytes,
			side,
			bytes / cells,
			bytes / FULL_BASE
		)
	)
end

-- ---- unreliable ---------------------------------------------------------------

-- V visible f64 cells streamed through generate_unreliable_chunks at the
-- default 980-byte budget: chunk count, total bytes, bytes per value
local function run_unreliable_row(V)
	local world, net, players = make_world(DEFAULT_P)
	local component = world:component()
	world:set(component, net.Serdes, table.clone(f64_static_serdes))
	world:add(component, net.NetworkedUnreliable)

	for i = 1, V do
		local entity = world:entity()
		world:set(entity, component, i)
		world:add(entity, net.Replicated)
	end
	net.generate_packets()

	local chunks = net.generate_unreliable_chunks()[players[1]]
	local bytes = 0
	for _, chunk in chunks do
		bytes += buffer.len(chunk)
	end
	print(
		string.format(
			"unreliable f64 values: V=%4d | %2d chunk(s) | %6d B/call | %6.2f B/value",
			V,
			#chunks,
			bytes,
			bytes / V
		)
	)
end

-- ---- fragmentation ------------------------------------------------------------

-- `count` unique random 15-subsets of the non-probe players, deduped by
-- numeric bitmask (as in bench_overhead); the probe joins every whitelist, so
-- it sees all FRAG_CELLS cells in every row
local function generate_whitelists(count, players, probe)
	math.randomseed(1337)
	local others = {}
	for _, player in players do
		if player ~= probe then
			table.insert(others, player)
		end
	end
	local P = #others
	local j = FRAG_VIEWERS - 1

	local whitelists = table.create(count)
	local seen = {}
	while #whitelists < count do
		local deck = table.create(P)
		for i = 1, P do
			deck[i] = i
		end
		local key = 0
		local whitelist = { [probe] = true }
		for k = 1, j do
			local pick = math.random(k, P)
			deck[k], deck[pick] = deck[pick], deck[k]
			whitelist[others[deck[k]]] = true
			key += 2 ^ deck[k]
		end
		if seen[key] == nil then
			seen[key] = true
			table.insert(whitelists, whitelist)
		end
	end
	return whitelists
end

-- FRAG_CELLS hookless value cells, each whitelisted (per-component) to one of
-- F distinct 16-viewer whitelists round-robin, every cell set fresh in the
-- measured frame; the probe passes every whitelist. F=1 encodes one shared
-- section, F=FRAG_CELLS one section per cell.
local function run_fragmented_row(F)
	local world, net, players = make_world(DEFAULT_P)
	local probe = players[1]
	local component = world:component()
	world:add(component, net.Networked)

	local whitelists = generate_whitelists(F, players, probe)
	local entities = table.create(FRAG_CELLS)
	for i = 1, FRAG_CELLS do
		local entity = world:entity()
		world:set(entity, component, i)
		world:add(entity, net.Replicated)
		world:set(entity, pair(net.Private, component), table.clone(whitelists[(i - 1) % F + 1]))
		entities[i] = entity
	end
	net.generate_packets()

	for i = 1, FRAG_CELLS do
		world:set(entities[i], component, i + 0.5)
	end
	local bytes, side = packet_bytes(net.generate_packets()[probe])
	row(string.format("value sets: hookless, F=%3d whitelists of 16", F), FRAG_CELLS, bytes, side)
end

-- ---- run ----------------------------------------------------------------------

print(
	string.format(
		"duplecs wire size  P=%d, broadcast visibility unless stated"
			.. "  (bytes are per receiving client and deterministic; side values ride the transport, not the buffer)",
		DEFAULT_P
	)
)
print("")

print("reliable deltas:")
run_settled_row()
for _, cells in CELL_COUNTS do
	run_value_row(cells, "hookless")
end
run_value_row(N, "static")
run_value_row(N, "sizeless")
run_tag_rows()
run_remove_row()
run_pair_shared_row()
run_pair_distinct_row()
run_lifecycle_rows()
run_names_row()
print("")

print("joiner (full packet, hookless values):")
run_joiner_row()
print("")

print("unreliable chunks (default 980-byte budget, static 8-byte serdes):")
for _, V in UNRELIABLE_COUNTS do
	run_unreliable_row(V)
end
print("")

print(
	string.format(
		"visibility fragmentation (%d cells, %d viewers per cell, probe in every whitelist):",
		FRAG_CELLS,
		FRAG_VIEWERS
	)
)
for _, F in FRAG_MASK_COUNTS do
	run_fragmented_row(F)
end
print("")

return true
