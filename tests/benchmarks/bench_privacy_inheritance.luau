--!native
--!optimize 2

-- duplecs privacy-inheritance benchmark: manual per-entity filters vs the
-- built-in InheritsPrivacy delegation. The scenario is the one the relation
-- targets -- a group (squad, room, team) whose members should all be visible to
-- exactly the group's clients -- and the axis is how a membership change on that
-- group propagates to its members.
--
-- TOTAL_MEMBERS Replicated entities (each holding one networked value) are held
-- constant and partitioned into G groups of M members; M sweeps while G =
-- TOTAL_MEMBERS / M keeps the world size fixed, so the number of cells restaged
-- per tick is the same at every M and only the *shape* of the propagation
-- differs:
--   manual  -- every member carries its own unpaired Private whitelist; a
--     membership change loops over all TOTAL_MEMBERS members and edits each
--     (TOTAL_MEMBERS edit_entity_privacy calls, one filter clone/freeze/set apiece).
--   builtin -- every member delegates via pair(InheritsPrivacy, group) and the
--     whitelist lives once on each group; a membership change edits each group
--     (G edit_entity_privacy calls), and the group edit fans out over its members.
--
-- Both wire up identical per-client visibility, so the packets are byte-for-byte
-- equal -- the comparison reports that match, and it (not the timings) is the
-- fairness check that the two modes are doing the same replication.
--
-- The sweep runs in two structural variants that change how the manual side finds
-- and edits its members, peeling confounds off the comparison one at a time:
--   flat    -- members hold only their component (+ Replicated, + own Private on
--     the manual side), and the manual side edits a hand-maintained member array.
--     Manual members share one archetype, pay no discovery cost, and touch no
--     group entity; builtin members delegating to *distinct* groups land in
--     distinct archetypes, the fan-out queries them, and the edit runs on the
--     group. So at small M builtin pays a fragmentation tax, a traversal cost, and
--     a group edit that manual dodges, on top of the fan-out overhead.
--   childof -- the composite-object case (a turret whose head is a separate
--     entity): every member is pair(ChildOf, group) in *both* modes, so both
--     fragment into one archetype per group and the layouts match (same width,
--     same tracked-cell count -- the ChildOf target is un-Replicated and unnamed,
--     so the pair never reaches the wire, it only splits archetypes). The edit now
--     starts on the group root in *both* modes -- edit_entity_privacy(group) is the
--     natural "hide this object" operation, so both pay it and its restage.
--     builtin's group edit fans out over InheritsPrivacy; manual has no
--     delegation, so it then discovers the parts with world:each(pair(ChildOf,
--     group)) and mirrors the edit onto each. After the shared group edit the only
--     difference left is per-part: builtin re-derives M effective words, manual
--     runs M more full filter edits.
--
-- So flat lets manual dodge fragmentation, discovery, and the group edit; childof
-- charges it for all three (the realistic composite workflow). What survives in
-- childof at small M is the irreducible delegation overhead -- and since the group
-- edit is now shared, builtin trades M heavy per-part filter edits for M light
-- re-derivations, so it should stay competitive even at small M.
--
-- The two phases are timed separately: edit (the membership propagation, where
-- the delegation fan-out runs eagerly and the win lives) and flush
-- (generate_packets draining the staged diff). No serdes hooks (values travel
-- out-of-band), matching the other benches. Absolute ms carry the usual per-run
-- noise on this machine, so read the manual-vs-builtin ratio and the trend
-- across M -- and the shift between variants -- rather than the raw numbers.

local jecs = require("../../roblox_packages/jecs")
local pair = jecs.pair
local ChildOf = jecs.ChildOf

local duplecs = require("../../src")

local TOTAL_MEMBERS = 1024 -- held constant; partitioned into G groups of M
local MEMBER_COUNTS = { 1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024 } -- M per group
local P = 32
local BASE = 4 -- clients permanently in every whitelist (stable viewers)
local SWING_INDEX = BASE + 1 -- the one client toggled in/out each tick
local REPS = 200
local WARM = 20

local guard = 0

local function drain(packets)
	local n = 0
	for _client in packets do
		n += 1
	end
	return n
end

-- wire bytes of one client's packet (buffer only); 0 when the client received
-- nothing this pass
local function bytes_of(packets, client)
	local packet = packets[client]
	if packet == nil then
		return 0
	end
	return buffer.len(packet.data)
end

-- a fresh whitelist admitting only the BASE permanent viewers; the swing client
-- is layered on top through edit_entity_privacy in the timed loop. built as a new table
-- per call so manual mode can set an independent copy on every member.
local function base_whitelist(players)
	local whitelist = {}
	for i = 1, BASE do
		whitelist[players[i]] = true
	end
	return whitelist
end

-- builds the world for one mode: TOTAL_MEMBERS Replicated members holding one
-- shared networked component, partitioned into G groups of M. builtin members
-- delegate to a plain (un-Replicated) group entity carrying the whitelist;
-- manual members each carry their own copy. When parent_members is set, every
-- member is also pair(ChildOf, group) in both modes so the archetype
-- fragmentation matches. slots are allocated before the whitelist is applied (so
-- masks derive against tracked players) and the narrowing is flushed, matching
-- bench_generate_packets' setup ordering.
local function setup(M, mode, parent_members)
	local world = jecs.World.new()
	local net = duplecs.server(world)

	local G = TOTAL_MEMBERS // M

	-- dummy player stand-ins; the module only uses them as table keys
	local players = table.create(P) :: { any }
	for i = 1, P do
		players[i] = {}
	end
	local swing = players[SWING_INDEX]

	-- one shared networked data component (no serdes hooks)
	local component = world:component()
	world:add(component, net.Networked)

	-- group entities: plain, un-Replicated holders. builtin always needs them
	-- (the delegation target and whitelist holder); the childof variant also
	-- needs them in manual mode as the ChildOf parent that fragments members.
	local groups
	if mode == "builtin" or parent_members then
		groups = table.create(G)
		for g = 1, G do
			groups[g] = world:entity()
		end
	end

	-- members, laid out group by group into a flat array the loops drive
	local members = table.create(TOTAL_MEMBERS)
	local member_count = 0
	for g = 1, G do
		for _ = 1, M do
			member_count += 1
			local entity = world:entity()
			world:set(entity, component, member_count * 3)
			world:add(entity, net.Replicated)
			if mode == "builtin" then
				world:add(entity, pair(net.InheritsPrivacy, groups[g]))
			end
			-- ChildOf points at the same group; its target is un-Replicated and
			-- unnamed, so the pair never reaches the wire -- it exists only to
			-- split members into one archetype per group, matching however the
			-- InheritsPrivacy pair fragments the builtin side.
			if parent_members then
				world:add(entity, pair(ChildOf, groups[g]))
			end
			members[member_count] = entity
		end
	end

	-- warmup #1: allocate every client's slot (full packets) so the whitelist
	-- masks below derive against tracked players
	for _, player in players do
		net.add_client(player)
	end
	net.generate_packets()

	-- apply the base whitelist: once per group for builtin (the delegation fans
	-- it out to the members), once per member for manual
	if mode == "builtin" then
		for g = 1, G do
			world:set(groups[g], net.Private, base_whitelist(players))
		end
	else
		for _, member in members do
			world:set(member, net.Private, base_whitelist(players))
		end
		-- childof manual edits the group root as the composite's source-of-truth
		-- filter before mirroring onto the parts, so seed the groups too
		if parent_members then
			for g = 1, G do
				world:set(groups[g], net.Private, base_whitelist(players))
			end
		end
	end

	-- warmup #2: flush the narrowing so last_visibilities holds each member's
	-- base mask before the timed toggles begin
	net.generate_packets()

	return world, net, members, groups, players, swing, G
end

-- times one mode across REPS ticks, each toggling the swing client in (odd) or
-- out (even) of every group's whitelist, and returns the per-tick edit/flush
-- averages plus the swing packet size on an admit tick.
local function bench(M, mode, parent_members)
	local world, net, members, groups, _players, swing, G = setup(M, mode, parent_members)

	-- one membership propagation. both modes edit the group root first -- the
	-- natural "hide this composite" operation, and the cost the composite case
	-- makes fair to charge both sides. builtin's group edit fans out over
	-- InheritsPrivacy; manual has no delegation, so it discovers the parts with
	-- world:each(pair(ChildOf, group)) -- the same traversal the builtin fan-out
	-- runs over its children -- and mirrors the edit onto each. the flat variant
	-- keeps the older shape: no group entity, so manual walks a maintained member
	-- array. every path restages the same TOTAL_MEMBERS parts. each edit is a
	-- value-only world:set on an already-present Private (base viewers keep the
	-- whitelist non-empty), so it never moves an archetype and the world:each
	-- iteration stays valid.
	local function propagate(allowed)
		if mode == "builtin" then
			for g = 1, G do
				net.edit_entity_privacy(groups[g], swing, allowed)
			end
		elseif parent_members then
			for g = 1, G do
				net.edit_entity_privacy(groups[g], swing, allowed)
				for member in world:each(pair(ChildOf, groups[g])) do
					net.edit_entity_privacy(member, swing, allowed)
				end
			end
		else
			for _, member in members do
				net.edit_entity_privacy(member, swing, allowed)
			end
		end
	end

	-- warmup, ending with the swing client removed so the first timed tick is a
	-- clean admit
	for i = 1, WARM do
		propagate(i % 2 == 1)
		net.generate_packets()
	end
	propagate(false)
	net.generate_packets()

	local edit_elapsed = 0
	local flush_elapsed = 0
	local swing_bytes = 0
	for rep = 1, REPS do
		local allowed = rep % 2 == 1

		local t0 = os.clock()
		propagate(allowed)
		edit_elapsed += os.clock() - t0

		local t1 = os.clock()
		local packets = net.generate_packets()
		flush_elapsed += os.clock() - t1

		guard += drain(packets)
		if allowed then
			swing_bytes = bytes_of(packets, swing)
		end
	end

	return {
		edit = 1000 * edit_elapsed / REPS,
		flush = 1000 * flush_elapsed / REPS,
		bytes = swing_bytes,
	}
end

print(
	string.format(
		"duplecs privacy inheritance  total members=%d  players=%d  base viewers=%d  reps=%d",
		TOTAL_MEMBERS,
		P,
		BASE,
		REPS
	)
)
print("propagating one 'hide this object' change to a group's members. manual mirrors the edit")
print("onto each part; builtin fans out via InheritsPrivacy. total = edit + flush.")
print("")

local VARIANTS = {
	{
		key = "flat",
		parent = false,
		note = "manual edits a cached member list; builtin fans out via InheritsPrivacy",
	},
	{
		key = "childof",
		parent = true,
		note = "composite: both edit the group root; manual then mirrors to ChildOf parts",
	},
}

-- runs are interleaved (manual then builtin per M) so both modes hit the same
-- warmup/GC state at each row, then the row is printed as a direct comparison.
for _, variant in VARIANTS do
	print(string.format("== variant: %-7s (%s) ==", variant.key, variant.note))
	for _, M in MEMBER_COUNTS do
		local manual = bench(M, "manual", variant.parent)
		local builtin = bench(M, "builtin", variant.parent)

		local G = TOTAL_MEMBERS // M
		local m_total = manual.edit + manual.flush
		local b_total = builtin.edit + builtin.flush
		local speedup = if b_total > 0 then m_total / b_total else 0
		local matched = if manual.bytes == builtin.bytes then "ok" else "MISMATCH"

		print(
			string.format(
				"M=%5d G=%5d | change: m %7.4f / b %7.4f ms (%5.2fx) | edit: m %7.4f / b %7.4f | flush: m %6.4f / b %6.4f | %6dB %s",
				M,
				G,
				m_total,
				b_total,
				speedup,
				manual.edit,
				builtin.edit,
				manual.flush,
				builtin.flush,
				manual.bytes,
				matched
			)
		)
	end
	print("")
end

print("guard:", guard)

return true
