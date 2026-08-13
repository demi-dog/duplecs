-- duplecs verification suite.
-- Run from the repo root with `lune run tests/verification_suite.luau` (after
-- `lune run tests/setup.luau` has fetched jecs into roblox_packages/).
-- Simulates a server world and one or more client worlds in a single script;
-- packets are deep-copied between worlds to stand in for the network boundary.
-- Each test runs against a fresh server+client pair, so tests are independent.
-- Guard-rail tests intentionally trigger duplecs warnings; each one declares
-- the warning it expects with expected_warning() and the runner asserts the
-- captured warnings match (see the warning capture below), so every test that
-- declares nothing asserts silence.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

-- warning capture, part 1 of 2: the sink. the expectations and their assertions live with the test harness
-- below; only the hijack itself has to happen here.
--
-- every duplecs warning rides its instance's reporter, whose default sink is the global warn (see
-- src/diagnostics.luau), so replacing the global captures both halves of every instance the suite builds --
-- including the warnings a constructor emits before a caller could install a hook of its own, which is why
-- the capture goes through the sink rather than each instance's set_warn_hook.
--
-- this must stay above the requires below: lune copies the globals into each module's environment as it
-- loads it, so a module required before this assignment keeps the original warn and its warnings would
-- escape the capture. moving it fails loudly (every guard-rail test at once) rather than silently.
local real_warn = warn
-- the messages captured while the running test's body executes
local captured_warnings = {}
-- only true during a test body, so the runner's own reporting still reaches the console
local capturing_warnings = false

warn = function(...)
	if not capturing_warnings then
		real_warn(...)
		return
	end
	table.insert(captured_warnings, tostring((...)))
end

local jecs = require("../roblox_packages/jecs")
local pair = jecs.pair

local duplecs = require("../src")
local wire = require("../src/wire")

-- wire-format flag bits, widths, and id encoding used by tests that
-- hand-craft or inspect wire buffers directly; the layouts are documented
-- in src/wire.luau.
local flag_has_ids = wire.flag_has_ids
local flag_has_removed = wire.flag_has_removed
local flag_pair = wire.flag_pair
local flag_runs = wire.flag_runs
local flag_side_values = wire.flag_side_values
local packet_flag_unreplicated = wire.packet_flag_unreplicated
local wire_version = wire.wire_version
local version_width = wire.version_width
local id_width = wire.id_width
local gen_id_width = wire.gen_id_width
local write_id = wire.write_id
local read_packet_header = wire.read_packet_header
local read_name = wire.read_name
local read_section_header = wire.read_section_header

-- test harness

local tests = {}

local function test(name, fn)
	table.insert(tests, { name = name, fn = fn })
end

local function fail(message)
	error(message, 3)
end

local function expect(condition, message)
	if not condition then
		fail(message)
	end
end

local function expect_equal(actual, expected, label)
	if actual ~= expected then
		fail(`{label}: expected {tostring(expected)}, got {tostring(actual)}`)
	end
end

-- the substring is required, not optional: a guard whose test names only a prose label leaves its message text
-- nowhere in the suite, so grepping the message reads as zero coverage. pick a fragment stable enough to
-- survive a rewording -- the mid-message substance, without the [duplecs] prefix or any interpolated id.
local function expect_error(fn, label, expected_substring)
	local ok, err = pcall(fn)
	if ok then
		fail(`{label}: expected an error, but none was thrown`)
	end
	if not string.find(tostring(err), expected_substring, 1, true) then
		fail(`{label}: expected the error to mention "{expected_substring}", got {tostring(err)}`)
	end
end

-- warning capture, part 2 of 2: the expectations. a test declares each warning it expects with
-- expected_warning(), optionally naming a substring of the message; the runner then asserts, once the body
-- returns, that exactly those warnings fired in that order. declaring nothing therefore asserts silence,
-- which is what lets guard-rail tests distinguish warn-and-undo from silent misbehavior.
--
-- the tests that install a hook of their own (section 30) divert that instance's warnings away from the
-- global sink, so the capture correctly sees nothing for them and they assert the messages themselves.

-- the prefix every duplecs warning and error message carries (see src/diagnostics.luau)
local message_prefix = "[duplecs] "

-- the expectations the running test's body declared
local expected_warnings = {}

-- declares one warning the running test expects. declarations sit immediately before the statement that
-- warns, so declaration order matches firing order.
local function expected_warning(expected_substring)
	table.insert(expected_warnings, { substring = expected_substring })
end

-- renders everything captured, for a failure message
local function describe_captured_warnings()
	if #captured_warnings == 0 then
		return "no warnings fired"
	end
	local lines = { `{#captured_warnings} warning(s) fired:` }
	for index, message in captured_warnings do
		table.insert(lines, `\n\t{index}) {message}`)
	end
	return table.concat(lines)
end

-- matches the running test's captured warnings against its declarations, one by one
local function check_warnings()
	for index = 1, math.max(#captured_warnings, #expected_warnings) do
		local captured = captured_warnings[index]
		local expectation = expected_warnings[index]
		if expectation == nil then
			fail(
				`duplecs warning #{index} was never declared: {#expected_warnings} declared, {describe_captured_warnings()}`
			)
		end
		if captured == nil then
			local named = if expectation.substring ~= nil then ` mentioning "{expectation.substring}"` else ""
			fail(`expected duplecs warning #{index}{named}, but {describe_captured_warnings()}`)
		end
		if string.sub(captured, 1, #message_prefix) ~= message_prefix then
			fail(`duplecs warning #{index} does not carry the shared prefix: {captured}`)
		end
		if expectation.substring ~= nil and not string.find(captured, expectation.substring, 1, true) then
			fail(`duplecs warning #{index}: expected it to mention "{expectation.substring}", got {captured}`)
		end
	end
end

-- duplecs only ever uses players as table keys and equality, never as Instances
local function fake_player(name)
	return { Name = name }
end

-- stands in for the serialization boundary: the client must never share
-- table or buffer references with the server
local function deep_copy(value)
	if type(value) == "buffer" then
		local copy = buffer.create(buffer.len(value))
		buffer.copy(copy, 0, value)
		return copy
	end
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, inner in value do
		copy[key] = deep_copy(inner)
	end
	return copy
end

-- tests assert against the decoded record view produced by wire.decode_packet
-- rather than re-parsing wire buffers themselves; see src/wire.luau for the
-- record shape (DecodedPacket/DecodedSection) and the authoritative wire
-- layouts.
local decode_packet = wire.decode_packet

-- environment setup

-- both sides define the same components, mirroring production where shared
-- definitions exist in every world; only the server marks networking
local function make_defs(world)
	return {
		Health = world:component(), -- number value
		Inventory = world:component(), -- table value
		Burning = world:entity(), -- tag
		Cooldown = world:component(), -- number value, NetworkedOnce
		Likes = world:component(), -- value relation
		Targeting = world:entity(), -- tag relation
		LocalOnly = world:component(), -- never networked
	}
end

local function make_client(server)
	local world = jecs.world()
	local net = duplecs.client(world)
	local defs = make_defs(world)

	-- map well-known definitions to the server's ids, as production does at startup
	for name, server_def in server.defs do
		net.set_client_entity(server_def, defs[name])
	end
	net.set_client_entity(jecs.ChildOf, jecs.ChildOf)

	return { world = world, net = net, defs = defs }
end

local function make_env()
	local world = jecs.world()
	local net = duplecs.server(world)
	local defs = make_defs(world)

	world:add(defs.Health, net.Networked)
	world:add(defs.Inventory, net.Networked)
	world:add(defs.Burning, net.Networked)
	world:add(defs.Cooldown, net.NetworkedOnce)
	world:add(defs.Likes, net.Networked)
	world:add(defs.Targeting, net.Networked)
	world:add(jecs.ChildOf, net.Networked)

	-- duplecs.server connects the server-authoritative replication hooks itself, so the Networked tags above
	-- already ran through the live hooks that then drive the Replicated/Private changes tests make. client
	-- worlds (make_client) never track: duplecs.client connects no tracking hooks of its own.

	local server = { world = world, net = net, defs = defs }
	local client = make_client(server)

	local player_a = fake_player("PlayerA")
	local player_b = fake_player("PlayerB")

	-- generate_packets() builds every tracked player's packet in a single
	-- draining pass, so a player must already hold a slot before the frames a
	-- test inspects. register the two standard players and drain once up front:
	-- this consumes the full packet a joiner receives on its first frame (empty
	-- here, nothing exists yet) so subsequent frames are deltas, and lets
	-- whitelists set in test bodies derive their masks against allocated players.
	net.add_client(player_a)
	net.add_client(player_b)
	net.generate_packets()

	-- indexing a frame for a player with no changes yields a blank packet, so
	-- callers can always read .sections / .components / .replicated /
	-- .unreplicated safely; its zeroed data buffer reconciles as a no-op.
	local empty_mt = {
		__index = function()
			return {
				data = wire.assemble_packet(0, nil, nil, nil, nil, 0, nil).data,
				frame = 0,
				replicated = {},
				unreplicated = {},
				names = {},
				sections = {},
				components = {},
			}
		end,
	}

	-- one frame: drain all staged change into a deep-copied packet per tracked
	-- player. the deep copy stands in for the serialization boundary and also
	-- separates the hookless value arrays the module shares between players.
	-- each copy is decoded into the record view (with the merged per-component
	-- .components) for assertions while keeping .data/.values reconcilable.
	-- replaces the old delta()/full() snapshot object.
	-- decodes inline serdes values through the server's hooks; tests assign
	-- hooks symmetrically, so this matches what the receiving client would use
	local function resolve_serdes(component, relation)
		if relation == nil then
			return world:get(component, net.Serdes)
		end
		local target = jecs.ECS_PAIR_SECOND(component)
		local serdes = world:get(relation, pair(net.Serdes, target))
		if serdes == nil then
			serdes = world:get(relation, net.Serdes)
		end
		return serdes
	end

	local function frame()
		local packets = net.generate_packets()
		local copies = setmetatable({}, empty_mt)
		for player, packet in packets do
			copies[player] = decode_packet(deep_copy(packet), resolve_serdes)
		end
		return copies
	end

	return {
		server = server,
		client = client,
		player_a = player_a,
		player_b = player_b,

		make_client = function()
			return make_client(server)
		end,

		-- drains a frame and returns the per-player packet map
		frame = frame,

		-- the standard per-frame flow: drain -> wire -> reconcile. returns the
		-- player's packet (a blank packet if they saw no changes this frame).
		sync = function(player, target_client)
			local target = target_client or client
			local packet = frame()[player]
			target.net.reconcile_packet(packet)
			return packet
		end,

		-- registers a fresh viewer, then drains. a newly-joined player is
		-- allocated a slot and handed a full packet on this first frame.
		join = function(player, target_client)
			local target = target_client or client
			net.add_client(player)
			local packet = frame()[player]
			target.net.reconcile_packet(packet)
			return packet
		end,

		-- pulls one player's packet out of an already-drained frame
		packet_for = function(frame_packets, player)
			return frame_packets[player]
		end,

		apply = function(packet, target_client)
			local target = target_client or client
			target.net.reconcile_packet(packet)
		end,
	}
end

-- 1) core replication loop

test("value component replicates to the client", function(env)
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 100)
	env.sync(env.player_a)

	local le = c.net.get_client_entity(e)
	expect(le ~= nil, "client entity was not created")
	expect_equal(c.world:get(le, c.defs.Health), 100, "client Health")
end)

test("table values cross the boundary as copies", function(env)
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	local inventory = { gold = 5, items = { "sword" } }
	s.world:set(e, s.defs.Inventory, inventory)
	env.sync(env.player_a)

	local le = c.net.get_client_entity(e)
	local received = c.world:get(le, c.defs.Inventory)
	expect(received ~= nil, "Inventory did not arrive")
	-- this only pins the harness's deep-copy boundary stand-in, not duplecs
	-- behavior itself; the content checks below are the real assertions
	expect(received ~= inventory, "client shares the server's table reference")
	expect_equal(received.gold, 5, "copied field")
	expect_equal(received.items[1], "sword", "nested copied field")
end)

test("tags replicate as nulled and reconcile via add", function(env)
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:add(e, s.defs.Burning)
	local packet = env.sync(env.player_a)

	local data = packet.components[s.defs.Burning]
	expect(data ~= nil and data.nulled ~= nil and data.nulled[1] == e, "tag should travel in the nulled bucket")
	-- the packet is the only place "no value" is observable: jecs never stores a
	-- value for a tag, so world:get reads nil however the tag arrived
	expect_equal(data.ids, nil, "a tag must not also ship set entries")
	expect_equal(data.values, nil, "a tag must not ship values")
	local le = c.net.get_client_entity(e)
	expect_equal(c.world:has(le, c.defs.Burning), true, "client has the tag")
end)

test("value changes replicate", function(env)
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 100)
	env.sync(env.player_a)

	s.world:set(e, s.defs.Health, 55)
	env.sync(env.player_a)
	local le = c.net.get_client_entity(e)
	expect_equal(c.world:get(le, c.defs.Health), 55, "client Health after change")
end)

test("component removal replicates", function(env)
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 100)
	env.sync(env.player_a)
	-- anchor: the client entity is created off the replicated list alone, so without
	-- this the post-removal check would also hold if Health had never arrived
	local le = c.net.get_client_entity(e)
	expect_equal(c.world:get(le, c.defs.Health), 100, "client Health before removal")

	s.world:remove(e, s.defs.Health)
	local packet = env.sync(env.player_a)
	local health_data = packet.components[s.defs.Health]
	expect(
		health_data ~= nil and health_data.removed ~= nil and health_data.removed[1] == e,
		"the removal ships as a removed entry"
	)
	expect_equal(c.world:has(le, c.defs.Health), false, "client Health after removal")
	expect_equal(c.world:contains(le), true, "client entity should survive component removal")
end)

test("unreplicating an entity deletes its client entity", function(env)
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	env.sync(env.player_a)
	local le = c.net.get_client_entity(e)

	s.world:remove(e, s.net.Replicated)
	local packet = env.sync(env.player_a)
	expect_equal(packet.unreplicated[1], e, "unreplication announced in packet")
	expect_equal(c.world:contains(le), false, "client entity deleted")
	expect_equal(c.net.get_client_entity(e), nil, "mapping removed")
	expect_equal(s.world:has(e, s.net.Replicated), false, "server reports unreplicated")
end)

test("deleting a replicated server entity deletes its client entity", function(env)
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 100)
	env.sync(env.player_a)
	local le = c.net.get_client_entity(e)

	s.world:delete(e)
	local packet = env.sync(env.player_a)
	expect_equal(packet.unreplicated[1], e, "deletion announced via unreplicated")
	expect_equal(c.world:contains(le), false, "client entity deleted")
	expect_equal(c.net.get_client_entity(e), nil, "mapping removed")
end)

test("deleting an entity omits its redundant removals but keeps removals on survivors", function(env)
	-- the client deletes the entity wholesale from the unreplicated list, which
	-- strips all its components locally, so the per-component removals staged for
	-- the deleted entity's own cells are redundant and packet generation skips
	-- them. the skip is scoped to the deleted entity: a surviving entity's removal
	-- in the same frame still ships.
	local s, c = env.server, env.client
	local e1 = s.world:entity()
	local e2 = s.world:entity()
	local e3 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(e2, s.net.Replicated)
	s.world:add(e3, s.net.Replicated)
	s.world:set(e1, s.defs.Health, 100)
	s.world:add(e1, s.defs.Burning)
	s.world:set(e1, pair(s.defs.Likes, e2), 5)
	s.world:set(e3, s.defs.Inventory, { gold = 1 })
	env.sync(env.player_a)
	local le1 = c.net.get_client_entity(e1)
	local le3 = c.net.get_client_entity(e3)

	s.world:delete(e1)
	s.world:remove(e3, s.defs.Inventory)
	local packet = env.sync(env.player_a)

	expect_equal(packet.unreplicated[1], e1, "deletion announced via unreplicated")
	expect_equal(packet.components[s.defs.Health], nil, "value removal skipped for the deleted entity")
	expect_equal(packet.components[s.defs.Burning], nil, "tag removal skipped for the deleted entity")
	expect_equal(packet.components[pair(s.defs.Likes, e2)], nil, "pair removal skipped for the deleted entity")

	local inventory_data = packet.components[s.defs.Inventory]
	expect(
		inventory_data ~= nil and inventory_data.removed ~= nil and inventory_data.removed[1] == e3,
		"a surviving entity's removal still ships"
	)

	expect_equal(c.world:contains(le1), false, "deleted entity removed on client")
	expect_equal(c.world:has(le3, c.defs.Inventory), false, "survivor's component removed on client")
	expect_equal(c.world:contains(le3), true, "survivor itself intact")
end)

test("deleting a pair's target omits the redundant pair removal from a surviving subject", function(env)
	-- the pair removal is keyed under the still-live subject, so the deleted-
	-- subject skip misses it -- but it is redundant: the client deletes the target
	-- wholesale, which auto-removes the pair locally. packet generation drops it.
	-- the skip is scoped to the vanished target, so an unrelated removal on the
	-- same subject in the same frame still ships.
	local s, c = env.server, env.client
	local subject = s.world:entity()
	local target = s.world:entity()
	s.world:add(subject, s.net.Replicated)
	s.world:add(target, s.net.Replicated)
	s.world:set(subject, s.defs.Health, 100)
	s.world:set(subject, pair(s.defs.Likes, target), 5)
	env.sync(env.player_a)
	local le_subject = c.net.get_client_entity(subject)
	local le_target = c.net.get_client_entity(target)
	local likes_target = pair(s.defs.Likes, target) -- captured before the target dies
	expect_equal(c.world:get(le_subject, pair(c.defs.Likes, le_target)), 5, "pair replicated before deletion")

	-- delete the target and, in the same frame, drop an unrelated component on the
	-- surviving subject
	s.world:delete(target)
	s.world:remove(subject, s.defs.Health)
	local packet = env.sync(env.player_a)

	expect_equal(packet.unreplicated[1], target, "target deletion announced via unreplicated")
	expect_equal(packet.components[likes_target], nil, "redundant pair removal skipped for the deleted target")
	-- the merged view keys a pair section by its header target, and a dead target
	-- resolves to 0 -- a leaked removal would hide under pair(Likes, 0), not the
	-- captured key above. scan the raw sections for the relation to close that gap.
	for _, section in packet.sections do
		expect(section.relation ~= s.defs.Likes, "no Likes pair section may ship, whatever its resolved target")
	end

	local health_data = packet.components[s.defs.Health]
	expect(
		health_data ~= nil and health_data.removed ~= nil and health_data.removed[1] == subject,
		"an unrelated removal on the surviving subject still ships"
	)

	expect_equal(c.world:contains(le_target), false, "target deleted on client")
	expect_equal(c.world:contains(le_subject), true, "subject survives")
	expect_equal(
		c.world:has(le_subject, pair(c.defs.Likes, le_target)),
		false,
		"pair auto-removed by the target's deletion"
	)
end)

test("unreplicating a pair's target omits the redundant pair removal while the target lives on", function(env)
	-- companion to the deleted-target case above, exercising the other skip arm.
	-- the target merely loses Replicated (it survives on the server), so its
	-- pair_second still resolves to a live, gen-qualified id rather than 0. that id
	-- is in this frame's unreplicated set, so the skip still fires: the client
	-- deletes the target's client entity wholesale, auto-removing the pair locally.
	-- the skip is scoped to the vanished target, so an unrelated removal on the same
	-- subject in the same frame still ships.
	local s, c = env.server, env.client
	local subject = s.world:entity()
	local target = s.world:entity()
	s.world:add(subject, s.net.Replicated)
	s.world:add(target, s.net.Replicated)
	s.world:set(subject, pair(s.defs.Likes, target), 5)
	s.world:set(subject, s.defs.Health, 100)
	env.sync(env.player_a)
	local le_subject = c.net.get_client_entity(subject)
	local le_target = c.net.get_client_entity(target)
	local likes_target = pair(s.defs.Likes, target) -- captured before the target is unreplicated
	expect_equal(c.world:get(le_subject, pair(c.defs.Likes, le_target)), 5, "pair replicated before unreplication")

	-- unreplicate the target and, in the same frame, drop an unrelated component on
	-- the surviving subject
	s.world:remove(target, s.net.Replicated)
	s.world:remove(subject, s.defs.Health)
	local packet = env.sync(env.player_a)

	expect_equal(packet.unreplicated[1], target, "target unreplication announced via unreplicated")
	expect_equal(packet.components[likes_target], nil, "redundant pair removal skipped for the unreplicated target")
	-- the merged view keys a pair section by its header target, so a leaked removal
	-- naming a different target would hide under a different key. scan the sections.
	for _, section in packet.sections do
		expect(section.relation ~= s.defs.Likes, "no Likes pair section may ship, whatever its resolved target")
	end

	local health_data = packet.components[s.defs.Health]
	expect(
		health_data ~= nil and health_data.removed ~= nil and health_data.removed[1] == subject,
		"an unrelated removal on the surviving subject still ships"
	)

	expect_equal(s.world:contains(target), true, "target stays alive on the server, only unreplicated")
	expect_equal(c.world:contains(le_target), false, "target's client entity deleted")
	expect_equal(c.world:contains(le_subject), true, "subject survives")
	expect_equal(
		c.world:has(le_subject, pair(c.defs.Likes, le_target)),
		false,
		"pair auto-removed by the target's deletion"
	)
	expect_equal(c.world:has(le_subject, c.defs.Health), false, "the shipped removal applied on the client")
end)

test("recycling a deleted pair's target in the same frame still skips the redundant pair removal", function(env)
	-- the skip is generation-precise, not dense-id-blind. a pure-removal pair id has no
	-- remaining live pairs, so its target resolves through retired_target_gens -- the
	-- generation captured at deindex time -- rather than through the live-tenant cache
	-- used for sends. that retired generation is the *old* target, which is exactly the
	-- one in the frame's unreplicated set, so the skip fires even though the dense id
	-- was recycled into a fresh replicated entity the same frame. the stale removal
	-- never ships at all; the client still drops the pair via the old target's own
	-- local deletion.
	local s, c = env.server, env.client
	local subject = s.world:entity()
	local target_old = s.world:entity()
	s.world:add(subject, s.net.Replicated)
	s.world:add(target_old, s.net.Replicated)
	s.world:set(subject, pair(s.defs.Likes, target_old), 5)
	env.sync(env.player_a)
	local le_subject = c.net.get_client_entity(subject)
	local le_target_old = c.net.get_client_entity(target_old)
	local likes_pair = pair(s.defs.Likes, target_old) -- dense pair id, shared with the recycled target
	expect_equal(c.world:get(le_subject, pair(c.defs.Likes, le_target_old)), 5, "pair replicated before recycle")

	-- delete the target, then recycle its id into a fresh replicated entity
	s.world:delete(target_old)
	local target_new = s.world:entity()
	expect(
		jecs.ECS_ID(target_new) == jecs.ECS_ID(target_old) and target_new ~= target_old,
		"precondition: jecs did not recycle the deleted id, scenario cannot be tested"
	)
	s.world:add(target_new, s.net.Replicated)
	local packet = env.sync(env.player_a)

	expect_equal(packet.unreplicated[1], target_old, "old target deletion announced via unreplicated")
	expect_equal(packet.replicated[1], target_new, "recycled target announced as replicated")

	expect_equal(
		packet.components[likes_pair],
		nil,
		"redundant pair removal skipped generation-precisely for the recycled dense id"
	)
	-- the merged view keys a pair section by its header target: a removal that lost
	-- the retired generation and resolved the dead target live would ship naming 0
	-- and hide under pair(Likes, 0), not the key above. scan the raw sections too.
	for _, section in packet.sections do
		expect(section.relation ~= s.defs.Likes, "no Likes pair section may ship, whatever its resolved target")
	end

	local le_target_new = c.net.get_client_entity(target_new)
	expect(
		le_target_new ~= nil and le_target_new ~= le_target_old,
		"recycled target created as a distinct client entity"
	)
	expect_equal(c.world:contains(le_target_old), false, "old target deleted on client")
	expect_equal(c.world:contains(le_subject), true, "subject survives")
	expect_equal(
		c.world:has(le_subject, pair(c.defs.Likes, le_target_old)),
		false,
		"stale pair auto-removed by the old target's deletion"
	)
end)

test("an entity with only Replicated still creates a mapped client entity", function(env)
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	local packet = env.sync(env.player_a)

	expect_equal(packet.replicated[1], e, "entity announced in packet")
	-- Replicated is bookkeeping, not data: an entity carrying nothing else ships no
	-- section at all
	expect_equal(next(packet.components), nil, "no section should ship for a bare replicated entity")
	local le = c.net.get_client_entity(e)
	expect(le ~= nil and c.world:contains(le), "client entity should exist")
end)

test("non-networked components never enter packets", function(env)
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.LocalOnly, 5)
	local packet = env.sync(env.player_a)

	-- anchor: the entity's own creation makes this a real packet, so the absence
	-- checks below cannot be the harness's blank-packet fallback
	expect_equal(packet.replicated[1], e, "the entity itself still replicates")
	expect_equal(packet.components[s.defs.LocalOnly], nil, "LocalOnly should not be in the packet")
	expect_equal(next(packet.components), nil, "LocalOnly must not ship under any other key either")
	local le = c.net.get_client_entity(e)
	expect_equal(c.world:has(le, c.defs.LocalOnly), false, "LocalOnly should not reach the client")
end)

test("changes on non-replicated entities are filtered from player packets", function(env)
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:set(e, s.defs.Health, 9)
	-- the raw map (not env.frame) so a missing player reads as nil rather than the
	-- empty-packet metatable fallback, under which every absence check here would
	-- hold whatever the server had staged
	local packets = s.net.generate_packets()

	expect_equal(packets[env.player_a], nil, "the filtered change should produce no packet at all")
	expect_equal(packets[env.player_b], nil, "and none for the second viewer either")
	expect_equal(c.net.get_client_entity(e), nil, "no client mapping should exist")
end)

-- 2) lifecycle ordering

test("adding Networked late tracks existing instance values", function(env)
	local s, c = env.server, env.client
	local late_s = s.world:component()
	local late_c = c.world:component()
	c.net.set_client_entity(late_s, late_c)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, late_s, 12)
	env.sync(env.player_a)
	local le = c.net.get_client_entity(e)
	expect_equal(c.world:has(le, late_c), false, "component should not replicate before networking")

	s.world:add(late_s, s.net.Networked)
	env.sync(env.player_a)
	expect_equal(c.world:get(le, late_c), 12, "existing value after networking")
end)

test("adding Networked to a definition already used both unpaired and paired tracks its unpaired cells", function(env)
	-- pins the jecs 0.11.0 unpaired-hook bug: a listener registered while both an unpaired and a pair record
	-- for the component already exist never fires for the unpaired id (the pairs keep firing).
	-- start_tracking_component connects a definition's hooks at the moment its tracking tag lands, so the two
	-- seeding sets below -- one unpaired, one paired, both before the tag -- are what put the registration in
	-- that position. deleting either of them as pointless is exactly what this test guards against: without
	-- them the bug is unreachable here and every assertion below passes regardless.
	local s, c = env.server, env.client
	local slot_s = s.world:component()
	local slot_c = c.world:component()
	c.net.set_client_entity(slot_s, slot_c)

	local holder = s.world:entity()
	s.world:add(holder, s.net.Replicated)
	local target = s.world:entity()
	s.world:add(target, s.net.Replicated)

	-- both of the definition's records exist before the tag connects its hooks
	s.world:set(holder, slot_s, 1)
	s.world:set(holder, pair(slot_s, target), 2)

	s.world:add(slot_s, s.net.Networked)

	-- an unpaired cell added after the tag: only the definition's added hook can stage it
	local subject = s.world:entity()
	s.world:add(subject, s.net.Replicated)
	s.world:set(subject, slot_s, 7)
	expect_equal(
		s.net.is_component_visible(subject, slot_s, env.player_a),
		true,
		"the unpaired cell staged for the viewer"
	)

	env.sync(env.player_a)
	local le_subject = c.net.get_client_entity(subject)
	expect(le_subject ~= nil, "the entity holding the new unpaired cell replicated")
	expect_equal(c.world:get(le_subject, slot_c), 7, "the unpaired cell added after the tag reached the client")

	-- the cells that predate the tag ride the tracking catch-up rather than the hooks, so they pin the
	-- seeding itself: both must still arrive
	local le_holder = c.net.get_client_entity(holder)
	local le_target = c.net.get_client_entity(target)
	expect(le_holder ~= nil and le_target ~= nil, "the seeded entities replicated too")
	expect_equal(c.world:get(le_holder, slot_c), 1, "the pre-tag unpaired cell arrived")
	expect_equal(c.world:get(le_holder, pair(slot_c, le_target)), 2, "and the pre-tag pair cell beside it")

	-- a later change to the unpaired cell rides the definition's changed hook, and its removal the removed hook
	s.world:set(subject, slot_s, 8)
	env.sync(env.player_a)
	expect_equal(c.world:get(le_subject, slot_c), 8, "a later unpaired-cell change replicated")

	s.world:remove(subject, slot_s)
	env.sync(env.player_a)
	expect_equal(c.world:has(le_subject, slot_c), false, "and its removal replicated")
end)

test("adding Replicated late tracks current components and incoming pairs", function(env)
	local s, c = env.server, env.client
	local e2 = s.world:entity()
	local e3 = s.world:entity()
	s.world:add(e2, s.net.Replicated)
	s.world:add(e3, s.net.Replicated)
	env.sync(env.player_a)

	local e1 = s.world:entity()
	s.world:set(e1, s.defs.Health, 50)
	s.world:add(e1, s.defs.Burning)
	s.world:set(e1, pair(s.defs.Likes, e2), 3)
	s.world:add(e3, pair(s.defs.Targeting, e1)) -- target not yet replicable, untracked

	-- drain: nothing about e1 may leak before it is replicated. the raw map (not
	-- env.frame) so a missing player reads as nil rather than the empty-packet
	-- metatable fallback, under which an emptiness check would hold vacuously
	local packets = s.net.generate_packets()
	expect_equal(packets[env.player_a], nil, "no packet at all should ship before replication")
	expect_equal(packets[env.player_b], nil, "and none for the second viewer either")
	expect_equal(c.net.get_client_entity(e1), nil, "entity should not reach the client yet")

	s.world:add(e1, s.net.Replicated)
	env.sync(env.player_a)

	local le1 = c.net.get_client_entity(e1)
	local le2 = c.net.get_client_entity(e2)
	local le3 = c.net.get_client_entity(e3)
	expect(le1 ~= nil, "entity mapped after late replication")
	expect_equal(c.world:get(le1, c.defs.Health), 50, "Health")
	expect_equal(c.world:has(le1, c.defs.Burning), true, "Burning")
	expect_equal(c.world:get(le1, pair(c.defs.Likes, le2)), 3, "outgoing Likes pair")
	expect_equal(c.world:has(le3, pair(c.defs.Targeting, le1)), true, "incoming Targeting pair")
end)

test("removing Networked removes existing instances on clients", function(env)
	-- the removed(Networked) hook restages every instance as hidden, and the
	-- removal mask is resolved from last_visibilities rather than a live
	-- Networked check, so prior viewers still receive the removal.
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 80)
	env.sync(env.player_a)
	local le = c.net.get_client_entity(e)
	expect_equal(c.world:get(le, c.defs.Health), 80, "client Health before un-networking")

	s.world:remove(s.defs.Health, s.net.Networked)
	env.sync(env.player_a)
	expect_equal(c.world:has(le, c.defs.Health), false, "client Health after un-networking")
	expect_equal(c.world:contains(le), true, "client entity should survive un-networking")
end)

test("removing Networked from a relation removes existing pairs on clients", function(env)
	-- same path as the removing-Networked test above, via the pair branch of the
	-- removed(Networked) hook.
	local s, c = env.server, env.client
	local e1 = s.world:entity()
	local e2 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(e2, s.net.Replicated)
	s.world:set(e1, pair(s.defs.Likes, e2), 1)
	env.sync(env.player_a)
	local le1 = c.net.get_client_entity(e1)
	local le2 = c.net.get_client_entity(e2)
	expect_equal(c.world:get(le1, pair(c.defs.Likes, le2)), 1, "client pair before un-networking")

	s.world:remove(s.defs.Likes, s.net.Networked)
	env.sync(env.player_a)
	expect_equal(c.world:has(le1, pair(c.defs.Likes, le2)), false, "client pair after un-networking")
	expect_equal(c.world:contains(le1), true, "client subject entity should survive un-networking")
end)

test("deleting a tracked relation ships pair removals naming the relation's dense id", function(env)
	-- world:delete(R) fires R's own Networked removed hook (stop_tracking_component)
	-- before jecs removes the pair(R, target) cells that used R as a relation, so the
	-- removals stage while R still resolves live. generate_packets flushes them later,
	-- once R is fully dead -- a live jecs.pair_first resolve would then name relation 0,
	-- unresolvable on the wire, so the client would keep the pair forever.
	-- retired_relation_gens (mirroring retired_target_gens) caches R's gen-qualified id
	-- at stop_tracking_component time so get_pair_group still names it correctly.
	local s, c = env.server, env.client
	local e1 = s.world:entity()
	local e2 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(e2, s.net.Replicated)
	s.world:set(e1, pair(s.defs.Likes, e2), 7)
	env.sync(env.player_a)
	local le1 = c.net.get_client_entity(e1)
	local le2 = c.net.get_client_entity(e2)
	local likes_pair = pair(s.defs.Likes, e2) -- dense pair id, captured before Likes dies
	expect_equal(c.world:get(le1, pair(c.defs.Likes, le2)), 7, "pair replicated before the relation dies")

	s.world:delete(s.defs.Likes)
	local packet = env.sync(env.player_a)

	local likes_section = packet.components[likes_pair]
	expect(likes_section ~= nil, "the removal resolves under the relation's dense pair id, not 0")
	expect_equal(likes_section.relation, jecs.ECS_ID(s.defs.Likes), "the section names the relation's dense id")
	expect(likes_section.removed ~= nil and likes_section.removed[1] == e1, "the removal names the subject entity")
	expect_equal(c.world:has(le1, pair(c.defs.Likes, le2)), false, "the client drops the pair once the relation dies")
end)

test("recycling a deleted relation's dense id in the same frame still names the dead relation", function(env)
	-- companion to "recycling a deleted pair's target in the same frame still skips the
	-- redundant pair removal" (section 5), but for the relation half: retired_relation_gens
	-- takes precedence over the live resolve, so a fresh entity recycling R's dense id
	-- before generate_packets flushes the staged removals doesn't get misnamed as R.
	local s, c = env.server, env.client
	local e1 = s.world:entity()
	local e2 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(e2, s.net.Replicated)
	s.world:set(e1, pair(s.defs.Likes, e2), 7)
	env.sync(env.player_a)
	local le1 = c.net.get_client_entity(e1)
	local le2 = c.net.get_client_entity(e2)
	local likes_pair = pair(s.defs.Likes, e2) -- dense pair id, shared with the recycled relation
	expect_equal(c.world:get(le1, pair(c.defs.Likes, le2)), 7, "pair replicated before the recycle")

	s.world:delete(s.defs.Likes)
	local new_entity = s.world:entity()
	expect(
		jecs.ECS_ID(new_entity) == jecs.ECS_ID(s.defs.Likes) and new_entity ~= s.defs.Likes,
		"precondition: jecs did not recycle the deleted relation's id, scenario cannot be tested"
	)
	local packet = env.sync(env.player_a)

	local likes_section = packet.components[likes_pair]
	expect(likes_section ~= nil, "the removal still resolves under the relation's dense pair id")
	expect_equal(
		likes_section.relation,
		jecs.ECS_ID(s.defs.Likes),
		"the section still names the dead relation, not its recycled id's new tenant"
	)
	expect(likes_section.removed ~= nil and likes_section.removed[1] == e1, "the removal names the subject entity")
	expect_equal(
		c.world:has(le1, pair(c.defs.Likes, le2)),
		false,
		"the client drops the pair despite the same-frame recycle"
	)
end)

-- 3) delta semantics and coalescing

test("delta drains: an identical second sync is empty", function(env)
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 100)
	local first = env.sync(env.player_a)

	-- anchor the drain against a first frame that actually shipped: an empty second
	-- packet proves nothing if the value never left the server in the first place
	expect_equal(first.replicated[1], e, "first packet announces the entity")
	local first_health = first.components[s.defs.Health]
	expect(
		first_health ~= nil and first_health.values ~= nil and first_health.values[1] == 100,
		"first packet carries the initial value"
	)
	local le = c.net.get_client_entity(e)
	expect_equal(c.world:get(le, c.defs.Health), 100, "client Health after the first sync")

	local packet = env.sync(env.player_a)
	expect_equal(next(packet.components), nil, "second packet should have no component data")
	expect_equal(#packet.replicated, 0, "second packet should announce nothing")
	expect_equal(#packet.unreplicated, 0, "second packet should unreplicate nothing")
	expect_equal(c.world:get(le, c.defs.Health), 100, "the drained value stays on the client")
end)

test("add then remove in one frame coalesces to nothing", function(env)
	-- the component was never visible to any client, so its add and removal net
	-- to no change in the visibility diff and produce no packet data; the client
	-- never gains the component.
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	env.sync(env.player_a)
	local le = c.net.get_client_entity(e)
	expect(le ~= nil, "the entity replicated before the coalescing frame")

	-- the unrelated Health change rides the same frame to anchor its packet as real,
	-- so the absent Burning data below cannot pass through the blank-packet fallback
	s.world:add(e, s.defs.Burning)
	s.world:remove(e, s.defs.Burning)
	s.world:set(e, s.defs.Health, 3)
	local packet = env.sync(env.player_a)

	expect_equal(packet.components[s.defs.Burning], nil, "no packet data for a never-visible component")
	expect(packet.components[s.defs.Health] ~= nil, "the unrelated change in the same frame still ships")
	expect_equal(c.world:has(le, c.defs.Burning), false, "client never gains the component")
	expect_equal(c.world:get(le, c.defs.Health), 3, "client Health")
end)

test("remove then set in one frame coalesces to the final value", function(env)
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 100)
	env.sync(env.player_a)

	s.world:remove(e, s.defs.Health)
	s.world:set(e, s.defs.Health, 70)
	local packet = env.sync(env.player_a)

	local data = packet.components[s.defs.Health]
	expect(data ~= nil and data.values ~= nil and data.values[1] == 70, "only the final value should survive")
	expect_equal(data.removed, nil, "the transient removal should be coalesced away")
	local le = c.net.get_client_entity(e)
	expect_equal(c.world:get(le, c.defs.Health), 70, "client Health")
end)

test("nulling a data component clears the client's stale value", function(env)
	-- world:add is a no-op for components the entity already has, so the
	-- reconciler must null data components via :set() instead
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 100)
	env.sync(env.player_a)
	local le = c.net.get_client_entity(e)
	expect_equal(c.world:get(le, c.defs.Health), 100, "client Health before nulling")

	-- remove + re-add in one frame coalesces to a nulled entry while the
	-- client still holds the old value
	s.world:remove(e, s.defs.Health)
	s.world:add(e, s.defs.Health)
	local packet = env.sync(env.player_a)

	local data = packet.components[s.defs.Health]
	expect(
		data ~= nil and data.nulled ~= nil and data.nulled[1] == e,
		"valueless component should travel in the nulled bucket"
	)
	expect_equal(c.world:has(le, c.defs.Health), true, "client still has the component")
	expect_equal(c.world:get(le, c.defs.Health), nil, "stale value cleared")
end)

test("replicate then unreplicate in one frame cancels out", function(env)
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:set(e, s.defs.Health, 1)
	s.world:add(e, s.net.Replicated)
	s.world:remove(e, s.net.Replicated)
	-- a second entity that keeps its tag anchors the frame's packet as real, so the
	-- absences below cannot pass through the blank-packet fallback
	local other = s.world:entity()
	s.world:add(other, s.net.Replicated)
	local packet = env.sync(env.player_a)

	expect_equal(#packet.replicated, 1, "only the entity that kept its tag is announced")
	expect_equal(packet.replicated[1], other, "no replication announced for the cancelled entity")
	expect_equal(#packet.unreplicated, 0, "no unreplication announced")
	expect_equal(next(packet.components), nil, "no component data leaks")
	expect_equal(c.net.get_client_entity(e), nil, "no client entity created")
	expect(c.net.get_client_entity(other) ~= nil, "the anchor entity did reach the client")
end)

test("unreplicate then re-replicate in one frame keeps the client entity", function(env)
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 100)
	env.sync(env.player_a)
	local le = c.net.get_client_entity(e)

	s.world:remove(e, s.net.Replicated)
	s.world:add(e, s.net.Replicated)
	-- a newcomer replicating in the same frame anchors the packet as real, so the
	-- absences below cannot pass through the blank-packet fallback
	local other = s.world:entity()
	s.world:add(other, s.net.Replicated)
	local packet = env.sync(env.player_a)

	expect_equal(#packet.replicated, 1, "only the newcomer is announced")
	expect_equal(packet.replicated[1], other, "no re-replication announced")
	expect_equal(#packet.unreplicated, 0, "no unreplication announced")
	expect_equal(next(packet.components), nil, "the round trip re-sends no value")
	expect_equal(c.world:contains(le), true, "client entity survives")
	expect_equal(c.net.get_client_entity(e), le, "mapping unchanged")
	expect_equal(c.world:get(le, c.defs.Health), 100, "client value intact")
end)

-- 4) full snapshots / late joiner

test("a late joiner bootstrapped from a full packet matches current state", function(env)
	local s = env.server
	local e1 = s.world:entity()
	local e2 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(e2, s.net.Replicated)
	s.world:set(e1, s.defs.Health, 10)
	s.world:add(e1, s.defs.Burning)
	s.world:set(e1, s.defs.Inventory, { gold = 5 })
	s.world:set(e1, s.defs.Cooldown, 10)
	s.world:set(e1, s.defs.LocalOnly, 99) -- never networked, so it must not reach the joiner
	s.world:set(e1, pair(s.defs.Likes, e2), 4)
	env.sync(env.player_a) -- drain to the original client

	-- suppressed by NetworkedOnce for deltas, but a joiner's full packet reads live
	s.world:set(e1, s.defs.Cooldown, 6)

	-- a freshly-registered viewer receives a full packet on its first frame
	local c2 = env.make_client()
	local player_c = fake_player("PlayerC")
	local packet = env.join(player_c, c2)

	local le1 = c2.net.get_client_entity(e1)
	local le2 = c2.net.get_client_entity(e2)
	expect(le1 ~= nil and le2 ~= nil, "late joiner created both entities")
	expect_equal(c2.world:get(le1, c2.defs.Health), 10, "Health")
	expect_equal(c2.world:has(le1, c2.defs.Burning), true, "Burning")
	expect_equal(c2.world:get(le1, c2.defs.Inventory).gold, 5, "Inventory")
	expect_equal(c2.world:get(le1, c2.defs.Cooldown), 6, "Cooldown reflects the current value")
	expect_equal(c2.world:get(le1, pair(c2.defs.Likes, le2)), 4, "Likes pair")
	expect_equal(c2.world:has(le1, c2.defs.LocalOnly), false, "an untagged component never replicates")

	-- a full packet is a snapshot of what is currently visible, so it carries no teardown
	expect_equal(#packet.unreplicated, 0, "a full packet unreplicates nothing")
	for _, section in packet.sections do
		expect_equal(section.removed, nil, "a full packet carries no removals")
	end
end)

-- 5) pairs

test("pairs with replicated targets replicate and resolve locally", function(env)
	local s, c = env.server, env.client
	local e1 = s.world:entity()
	local e2 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(e2, s.net.Replicated)
	s.world:set(e1, pair(s.defs.Likes, e2), 3)
	local packet = env.sync(env.player_a)

	-- pair ids only pack dense halves, so packets must carry the dense relation
	-- and target separately for the client to resolve each half locally
	local data = packet.components[pair(s.defs.Likes, e2)]
	expect(data ~= nil, "pair data in packet")
	expect_equal(data.relation, jecs.ECS_ID(s.defs.Likes), "packet carries the dense relation")
	expect_equal(data.target, jecs.ECS_ID(e2), "packet carries the dense target")

	local le1 = c.net.get_client_entity(e1)
	local le2 = c.net.get_client_entity(e2)
	expect(le1 ~= nil and le2 ~= nil, "both entities mapped")
	expect_equal(c.world:get(le1, pair(c.defs.Likes, le2)), 3, "pair value on client")
end)

test("tag pairs replicate as nulled", function(env)
	local s, c = env.server, env.client
	local e1 = s.world:entity()
	local e2 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(e2, s.net.Replicated)
	s.world:add(e1, pair(s.defs.Targeting, e2))
	local packet = env.sync(env.player_a)

	local data = packet.components[pair(s.defs.Targeting, e2)]
	expect(data ~= nil and data.nulled ~= nil and data.nulled[1] == e1, "tag pair should travel in the nulled bucket")
	local le1 = c.net.get_client_entity(e1)
	local le2 = c.net.get_client_entity(e2)
	expect_equal(c.world:has(le1, pair(c.defs.Targeting, le2)), true, "tag pair on client")
end)

test("pairs to Name-bearing mapped entities replicate", function(env)
	local s, c = env.server, env.client
	local t = s.world:entity()
	s.world:set(t, jecs.Name, "WellKnownTarget")
	local tc = c.world:entity()
	c.net.set_client_entity(t, tc)

	local e1 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:set(e1, pair(s.defs.Likes, t), 1)
	env.sync(env.player_a)

	local le1 = c.net.get_client_entity(e1)
	expect_equal(c.world:get(le1, pair(c.defs.Likes, tc)), 1, "pair to named target")
end)

test("pairs to non-replicable targets do not replicate", function(env)
	local s, c = env.server, env.client
	local t = s.world:entity() -- no Name, not replicated
	local e1 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:set(e1, pair(s.defs.Likes, t), 1)
	local packet = env.sync(env.player_a)

	-- the subject's own creation anchors the packet as real, so the absence below
	-- cannot pass through the blank-packet fallback
	expect_equal(packet.replicated[1], e1, "the subject itself still replicates")
	expect_equal(next(packet.components), nil, "pair to non-replicable target stays server-side")
	local le1 = c.net.get_client_entity(e1)
	expect(le1 ~= nil, "the subject reached the client")
	expect_equal(c.world:target(le1, c.defs.Likes), nil, "no pair is applied locally")
	expect_equal(c.net.get_client_entity(t), nil, "the non-replicable target is never mapped")
end)

test("pair value changes and removals replicate", function(env)
	local s, c = env.server, env.client
	local e1 = s.world:entity()
	local e2 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(e2, s.net.Replicated)
	s.world:set(e1, pair(s.defs.Likes, e2), 1)
	env.sync(env.player_a)
	local le1 = c.net.get_client_entity(e1)
	local le2 = c.net.get_client_entity(e2)

	s.world:set(e1, pair(s.defs.Likes, e2), 2)
	local changed = env.sync(env.player_a)
	local changed_data = changed.components[pair(s.defs.Likes, e2)]
	expect(
		changed_data ~= nil and changed_data.values ~= nil and changed_data.values[1] == 2,
		"the new pair value ships as a set entry"
	)
	expect_equal(c.world:get(le1, pair(c.defs.Likes, le2)), 2, "pair value after change")

	s.world:remove(e1, pair(s.defs.Likes, e2))
	local removed = env.sync(env.player_a)
	local removed_data = removed.components[pair(s.defs.Likes, e2)]
	expect(
		removed_data ~= nil and removed_data.removed ~= nil and removed_data.removed[1] == e1,
		"the removal ships as an explicit removed entry"
	)
	expect_equal(c.world:contains(le1), true, "the subject survives the pair removal")
	expect_equal(c.world:has(le1, pair(c.defs.Likes, le2)), false, "pair removed on client")
end)

test("replicating a target late starts replicating pairs aimed at it", function(env)
	local s, c = env.server, env.client
	local e3 = s.world:entity()
	s.world:add(e3, s.net.Replicated)
	env.sync(env.player_a)

	local e4 = s.world:entity()
	s.world:set(e3, pair(s.defs.Likes, e4), 9)
	-- the unrelated Health change anchors this frame's packet as real, so the absent
	-- pair data below cannot pass through the blank-packet fallback
	s.world:set(e3, s.defs.Health, 1)
	local packet = env.sync(env.player_a)
	expect(packet.components[s.defs.Health] ~= nil, "the unrelated change in the same frame ships")
	expect_equal(packet.components[pair(s.defs.Likes, e4)], nil, "pair untracked while target is not replicable")

	s.world:add(e4, s.net.Replicated)
	env.sync(env.player_a)
	local le3 = c.net.get_client_entity(e3)
	local le4 = c.net.get_client_entity(e4)
	expect(le4 ~= nil, "target mapped after late replication")
	expect_equal(c.world:get(le3, pair(c.defs.Likes, le4)), 9, "pair replicated once target became replicable")
end)

test("pair data with an unmapped target is skipped gracefully", function(env)
	local s, c = env.server, env.client
	local t = s.world:entity()
	s.world:set(t, jecs.Name, "UnmappedTarget") -- replicable, but never mapped on the client

	local e1 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:set(e1, pair(s.defs.Likes, t), 2)
	-- a second hookless section rides the same packet: skipping the pair section must
	-- still consume its side-array entry, or this value would decode against the wrong slot
	s.world:set(e1, s.defs.Health, 5)
	expected_warning("section's pair target")
	local packet = env.sync(env.player_a)

	expect(packet.components[pair(s.defs.Likes, t)] ~= nil, "pair data should reach the packet")
	local le1 = c.net.get_client_entity(e1)
	expect(le1 ~= nil, "reconcile should complete without error")
	expect_equal(c.world:target(le1, c.defs.Likes), nil, "the skipped pair must not be applied locally")
	expect_equal(c.world:get(le1, c.defs.Health), 5, "the rest of the packet still applies")
end)

-- 6) privacy

test("Private filters per-player packets", function(env)
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 42)
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_a] = true })

	local snapshot = env.frame()
	local packet_a = env.packet_for(snapshot, env.player_a)
	local packet_b = env.packet_for(snapshot, env.player_b)

	local data_a = packet_a.components[s.defs.Health]
	expect(data_a ~= nil and data_a.values ~= nil and data_a.values[1] == 42, "player A receives the private value")
	expect_equal(packet_b.components[s.defs.Health], nil, "player B does not receive the private value")
	expect_equal(packet_b.replicated[1], e, "entity creation itself is not private")
end)

test("a Private pair with no value is normalized to an empty filter blocking everyone", function(env)
	-- a filter is always a table, so a valueless pair(Private, component) names no state at all: the module
	-- warns and rewrites the value to an empty filter, which blocks every client from the component it was
	-- meant to gate. the normalization fails closed, which is the only direction a filter may be guessed in.
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 42)
	s.world:add(e, s.defs.Burning) -- unfiltered: the normalization must leave it alone either way

	expected_warning("cannot have a nil value")
	s.world:add(e, pair(s.net.Private, s.defs.Health)) -- no whitelist value
	expect_equal(s.world:has(e, pair(s.net.Private, s.defs.Health)), true, "the valueless pair stays present")
	local filter = s.world:get(e, pair(s.net.Private, s.defs.Health))
	expect(filter ~= nil and next(filter) == nil, "carrying an empty filter in place of the nil")
	expect_equal(table.isfrozen(filter), true, "the normalized filter is frozen like any cached one")

	local snapshot = env.frame()
	local packet_a = env.packet_for(snapshot, env.player_a)
	local packet_b = env.packet_for(snapshot, env.player_b)
	-- a per-component filter never gates entity visibility, so the entity's
	-- creation replicates either way -- which also anchors both packets as real
	-- deliveries rather than the harness's blank-packet fallback
	expect_equal(packet_a.replicated[1], e, "entity creation reaches player A")
	expect_equal(packet_b.replicated[1], e, "entity creation reaches player B")
	expect_equal(packet_a.components[s.defs.Health], nil, "player A is blocked from the value")
	expect_equal(packet_b.components[s.defs.Health], nil, "and player B is blocked too")
	expect(packet_a.components[s.defs.Burning] ~= nil, "player A still receives the unfiltered component")
	expect(packet_b.components[s.defs.Burning] ~= nil, "player B still receives the unfiltered component")
end)

test("a Private on a relation filters its pairs per player", function(env)
	local s = env.server
	local e1 = s.world:entity()
	local e2 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(e2, s.net.Replicated)
	s.world:set(e1, pair(s.defs.Likes, e2), 1)
	s.world:set(e1, pair(s.net.Private, s.defs.Likes), { [env.player_a] = true })

	local pair_id = pair(s.defs.Likes, e2)
	local snapshot = env.frame()
	local data_a = env.packet_for(snapshot, env.player_a).components[pair_id]
	expect(data_a ~= nil and data_a.values ~= nil and data_a.values[1] == 1, "player A receives the pair value")

	local packet_b = env.packet_for(snapshot, env.player_b)
	-- the entities themselves still replicate to B -- this anchors B's packet as
	-- real, so the nil below can't pass through the blank-packet fallback
	expect(table.find(packet_b.replicated, e1) ~= nil, "player B still receives the subject")
	expect(table.find(packet_b.replicated, e2) ~= nil, "player B still receives the target")
	expect_equal(packet_b.components[pair_id], nil, "player B does not receive the pair")
end)

test("two clients end-to-end see only their own visibility", function(env)
	local s, c = env.server, env.client
	local c2 = env.make_client()
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 42)
	s.world:add(e, s.defs.Burning)
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_a] = true })

	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, env.player_a)) -- main client plays as A
	env.apply(env.packet_for(snapshot, env.player_b), c2) -- c2 plays as B

	local le_a = c.net.get_client_entity(e)
	local le_b = c2.net.get_client_entity(e)
	expect(le_a ~= nil and le_b ~= nil, "both clients created the entity")
	expect_equal(c.world:get(le_a, c.defs.Health), 42, "A sees the private value")
	expect_equal(c2.world:has(le_b, c2.defs.Health), false, "B does not see the private value")
	expect_equal(c.world:has(le_a, c.defs.Burning), true, "A sees the public tag")
	expect_equal(c2.world:has(le_b, c2.defs.Burning), true, "B sees the public tag")
end)

-- 7) NetworkedOnce and force_replicate

test("NetworkedOnce replicates the initial value but not changes", function(env)
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Cooldown, 5)
	env.sync(env.player_a)
	local le = c.net.get_client_entity(e)
	expect_equal(c.world:get(le, c.defs.Cooldown), 5, "initial value")

	-- the Health change rides the same frame to anchor its packet as real, so the
	-- absent Cooldown data below cannot pass through the blank-packet fallback
	s.world:set(e, s.defs.Cooldown, 3)
	s.world:set(e, s.defs.Health, 7)
	local packet = env.sync(env.player_a)
	expect_equal(packet.components[s.defs.Cooldown], nil, "change should be suppressed")
	expect(packet.components[s.defs.Health] ~= nil, "a tracked component in the same frame still ships")
	expect_equal(c.world:get(le, c.defs.Cooldown), 5, "client value unchanged")
	expect_equal(c.world:get(le, c.defs.Health), 7, "client Health")
end)

test("force_replicate pushes the current value of a NetworkedOnce component", function(env)
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Cooldown, 5)
	env.sync(env.player_a)
	local le = c.net.get_client_entity(e)

	s.world:set(e, s.defs.Cooldown, 3)
	s.net.force_replicate(e, s.defs.Cooldown)
	local packet = env.sync(env.player_a)
	local data = packet.components[s.defs.Cooldown]
	expect(data ~= nil and data.values ~= nil and data.values[1] == 3, "the push ships the current value")
	expect_equal(c.world:get(le, c.defs.Cooldown), 3, "forced value arrived")

	-- the push is one-shot, not a mode switch: the component still tracks no changes
	s.world:set(e, s.defs.Cooldown, 1)
	env.sync(env.player_a)
	expect_equal(c.world:get(le, c.defs.Cooldown), 3, "client value unchanged after the unforced change")
end)

test("force_replicate on a missing component is a silent no-op when never visible", function(env)
	-- the component was never visible to the client, so there is nothing to
	-- remove; force_replicate produces no packet data.
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	env.sync(env.player_a)
	local le = c.net.get_client_entity(e)

	s.net.force_replicate(e, s.defs.Cooldown)
	-- an unrelated change rides the same frame so the packet is a real one: with nothing else to send the
	-- frame would omit A, and the harness's blank-packet fallback would satisfy the absence below vacuously
	s.world:set(e, s.defs.Health, 4)
	local packet = env.sync(env.player_a)
	expect(packet.components[s.defs.Health] ~= nil, "precondition: the anchoring change makes this a real packet")
	expect_equal(packet.components[s.defs.Cooldown], nil, "missing never-visible component produces no data")
	expect_equal(c.world:has(le, c.defs.Cooldown), false, "and no Cooldown cell reaches the client")
end)

test("NetworkedOnce removals replicate", function(env)
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Cooldown, 5)
	env.sync(env.player_a)
	local le = c.net.get_client_entity(e)
	expect_equal(c.world:get(le, c.defs.Cooldown), 5, "precondition: the initial value replicated")

	s.world:remove(e, s.defs.Cooldown)
	local packet = env.sync(env.player_a)
	local data = packet.components[s.defs.Cooldown]
	expect(data ~= nil and data.removed ~= nil and data.removed[1] == e, "the removal ships as a removed entry")
	expect_equal(c.world:has(le, c.defs.Cooldown), false, "removal arrived despite NetworkedOnce")
	expect_equal(c.world:contains(le), true, "and the entity itself survives")
end)

test("NetworkedOnce on a relation suppresses pair changes but not initial values or removals", function(env)
	-- Likes is already Networked in make_env, and the two tags are exclusive, so
	-- this exercises a fresh relation carrying only NetworkedOnce instead.
	local s, c = env.server, env.client
	local rel_s = s.world:component()
	local rel_c = c.world:component()
	c.net.set_client_entity(rel_s, rel_c)
	s.world:add(rel_s, s.net.NetworkedOnce)

	local e1 = s.world:entity()
	local e2 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(e2, s.net.Replicated)
	s.world:set(e1, pair(rel_s, e2), 1)
	env.sync(env.player_a)
	local le1 = c.net.get_client_entity(e1)
	local le2 = c.net.get_client_entity(e2)
	expect_equal(c.world:get(le1, pair(rel_c, le2)), 1, "initial pair value replicates")

	s.world:set(e1, pair(rel_s, e2), 2)
	local packet = env.sync(env.player_a)
	expect_equal(next(packet.components), nil, "pair change should be suppressed")
	expect_equal(c.world:get(le1, pair(rel_c, le2)), 1, "client pair value unchanged")

	s.world:remove(e1, pair(rel_s, e2))
	local removal = env.sync(env.player_a)
	local removal_data = removal.components[pair(rel_s, e2)]
	expect(
		removal_data ~= nil and removal_data.removed ~= nil and removal_data.removed[1] == e1,
		"the removal ships as a removed entry naming the subject"
	)
	expect_equal(c.world:has(le1, pair(rel_c, le2)), false, "removal arrived despite NetworkedOnce")
end)

test("removing NetworkedOnce stops tracking and removes existing instances on clients", function(env)
	-- the mirror of "removing Networked removes existing instances on clients" (section 1) for the other tag:
	-- all three tracking tags' removed hooks funnel into the same owner check, so this pins a NetworkedOnce
	-- owner's genuine removal being recognized as one and reaching stop_tracking_component at all.
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Cooldown, 5)
	env.sync(env.player_a)
	local le = c.net.get_client_entity(e)
	expect_equal(c.world:get(le, c.defs.Cooldown), 5, "client Cooldown before un-networking")

	s.world:remove(s.defs.Cooldown, s.net.NetworkedOnce)
	env.sync(env.player_a)
	expect_equal(c.world:has(le, c.defs.Cooldown), false, "client Cooldown after un-networking")
	expect_equal(c.world:contains(le), true, "client entity should survive un-networking")

	-- and the tracking is gone rather than merely flushed: a fresh cell no longer ships its initial value,
	-- which under NetworkedOnce is the only value that ever would
	local other = s.world:entity()
	s.world:add(other, s.net.Replicated)
	s.world:set(other, s.defs.Cooldown, 9)
	local packet = env.sync(env.player_a)
	-- the new entity's creation anchors the packet as a real one, so the absence below is not the harness's
	-- blank-packet fallback answering for a frame that carried nothing at all
	expect_equal(packet.replicated[1], other, "precondition: the packet carries the new entity's creation")
	expect_equal(packet.components[s.defs.Cooldown], nil, "the untracked component ships nothing afterwards")
	local le_other = c.net.get_client_entity(other)
	expect(le_other ~= nil, "the new entity reconciled")
	expect_equal(c.world:has(le_other, c.defs.Cooldown), false, "and no Cooldown reached the client")
end)

test("guard: the exclusivity undo leaves a Networked relation's pair tracking intact", function(env)
	-- the same undo the ordered-pair exclusivity block in section 26 covers, but with a relation as the
	-- incumbent, which is where an unrecognized undo does the most damage: stop_tracking_component stages a
	-- removal for every live pair using the relation and withdraws its announced name, so a misread undo would
	-- drop the pairs from every viewer outright rather than only silencing later changes.
	local s, c = env.server, env.client
	local e1 = s.world:entity()
	local e2 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(e2, s.net.Replicated)
	s.world:set(e1, pair(s.defs.Likes, e2), 1)
	env.sync(env.player_a)
	local le1 = c.net.get_client_entity(e1)
	local le2 = c.net.get_client_entity(e2)
	expect_equal(c.world:get(le1, pair(c.defs.Likes, le2)), 1, "precondition: the pair replicated")

	expect_error(function()
		s.world:add(s.defs.Likes, s.net.NetworkedOnce)
	end, "adding NetworkedOnce to a Networked relation", "are exclusive")
	expect_equal(s.world:has(s.defs.Likes, s.net.NetworkedOnce), false, "NetworkedOnce removed by the guard")
	expect_equal(s.world:has(s.defs.Likes, s.net.Networked), true, "the incumbent tag is left in place")

	local packet = env.sync(env.player_a)
	expect_equal(next(packet.components), nil, "the refused add staged no pair removal")
	expect_equal(c.world:get(le1, pair(c.defs.Likes, le2)), 1, "the client keeps the pair")

	s.world:set(e1, pair(s.defs.Likes, e2), 2)
	env.sync(env.player_a)
	expect_equal(c.world:get(le1, pair(c.defs.Likes, le2)), 2, "the relation's change tracking survived the undo")
end)

-- 8) entity mapping

test("server/client mapping round-trips", function(env)
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	env.sync(env.player_a)

	local le = c.net.get_client_entity(e)
	expect(le ~= nil, "mapping exists")
	expect_equal(c.net.get_server_entity(le), e, "client to server")
	expect_equal(c.world:has(le, c.net.Imported), true, "client entity tagged Imported")
	expect_equal(s.world:has(e, s.net.Replicated), true, "server reports replicated")
end)

test("set_client_entity rejects remapping a live server id", function(env)
	local s, c = env.server, env.client
	local spare = c.world:entity()
	expect_error(function()
		c.net.set_client_entity(s.defs.Health, spare)
	end, "remapping a live server id", "is already mapped to a client entity")

	-- the refusal is total: the incumbent mapping stands and the rejected client entity gained nothing
	expect_equal(c.net.get_client_entity(s.defs.Health), c.defs.Health, "the incumbent mapping is untouched")
	expect_equal(c.net.get_server_entity(spare), nil, "the rejected client entity has no mapping")
	expect_equal(c.world:has(spare, c.net.Imported), false, "and was not tagged Imported")

	-- and the guard is specific to the live-remapping case: an unmapped server id still maps normally
	local fresh = s.world:entity()
	c.net.set_client_entity(fresh, spare)
	expect_equal(c.net.get_client_entity(fresh), spare, "an unmapped server id maps normally")
	expect_equal(c.world:has(spare, c.net.Imported), true, "and the client entity is tagged Imported")
end)

test("a pre-mapped creation adopts the prepared client entity (client-side prediction)", function(env)
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 77)

	-- the client predicts the entity before its creation arrives: a local
	-- stand-in mapped to the server's gen-qualified id via the public method
	local stand_in = c.world:entity()
	c.net.set_client_entity(e, stand_in)

	env.sync(env.player_a)

	expect_equal(c.net.get_client_entity(e), stand_in, "the creation adopted the prepared mapping")
	expect_equal(c.world:get(stand_in, c.defs.Health), 77, "the replicated value landed on the stand-in")
	expect_equal(c.net.get_server_entity(stand_in), e, "the reverse mapping still points at the server id")

	-- no spare client entity was created for the id: the stand-in is the only
	-- Imported entity bound to it
	local bound = 0
	for client_entity in c.world:each(c.net.Imported) do
		if c.net.get_server_entity(client_entity) == e then
			bound += 1
			expect_equal(client_entity, stand_in, "only the stand-in is bound to the server id")
		end
	end
	expect_equal(bound, 1, "exactly one client entity is bound to the server id")
end)

test("re-reconciling a creation for an already-adopted mapping is a silent no-op", function(env)
	-- previously this path warned per already-mapped entity; the prediction
	-- flow makes it routine, so it must stay silent and idempotent
	local s = env.server
	local c2 = env.make_client()
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 12)

	local stand_in = c2.world:entity()
	c2.net.set_client_entity(e, stand_in)

	local player_c = fake_player("PlayerC")
	local packet = env.join(player_c, c2) -- the joiner's full packet carries e's creation

	-- anchor the creation entry: every assertion below resolves through the prepared mapping, so without it
	-- the test would pass on a packet that never carried a creation for e at all
	expect_equal(packet.replicated[1], e, "precondition: the full packet carries the creation entry")
	expect_equal(c2.net.get_client_entity(e), stand_in, "the full packet adopted the prepared mapping")
	expect_equal(c2.world:get(stand_in, c2.defs.Health), 12, "the value landed on the stand-in")

	env.apply(packet, c2) -- a second full packet replays the same creation entry

	expect_equal(c2.net.get_client_entity(e), stand_in, "the mapping survives the replayed creation")
	expect_equal(c2.net.get_server_entity(stand_in), e, "the reverse mapping is untouched")
	expect_equal(c2.world:get(stand_in, c2.defs.Health), 12, "the value is unchanged")
end)

test("recycled server ids resolve to the new entity", function(env)
	local s, c = env.server, env.client
	local e1 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:set(e1, s.defs.Health, 1)
	env.sync(env.player_a)
	local le1 = c.net.get_client_entity(e1)

	s.world:delete(e1)
	local e2 = s.world:entity()
	expect(
		jecs.ECS_ID(e2) == jecs.ECS_ID(e1) and e2 ~= e1,
		"precondition: jecs did not recycle the deleted id, scenario cannot be tested"
	)
	s.world:add(e2, s.net.Replicated)
	s.world:set(e2, s.defs.Health, 2)
	env.sync(env.player_a)

	expect_equal(c.world:contains(le1), false, "old client entity deleted")
	local le2 = c.net.get_client_entity(e2)
	expect(le2 ~= nil and le2 ~= le1, "new client entity created")
	expect_equal(c.world:get(le2, c.defs.Health), 2, "new entity value")
	expect_equal(
		c.net.get_client_entity(e1),
		nil,
		"old-gen lookup no longer resolves to the recycled dense id's new tenant"
	)
end)

test("a stale client entity reference resolves no server mapping across a dense-id recycle", function(env)
	-- the reverse map keys by the client entity's *dense* id, so a recycled dense slot already holds the next
	-- tenant's mapping; get_server_entity's generation-aware liveness guard is what keeps a caller's stale
	-- reference from being handed it
	local s, c = env.server, env.client
	local e1 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:set(e1, s.defs.Health, 1)
	env.sync(env.player_a)

	local stale_ref = c.net.get_client_entity(e1)
	expect(stale_ref ~= nil, "precondition: the first server entity is mapped to a client entity")

	-- the deletion ends the mapping and kills the client entity, freeing its dense id
	s.world:delete(e1)
	env.sync(env.player_a)
	expect_equal(c.world:contains(stale_ref), false, "the client entity died with the server entity")

	local e2 = s.world:entity()
	s.world:add(e2, s.net.Replicated)
	s.world:set(e2, s.defs.Health, 2)
	env.sync(env.player_a)

	-- exactly one client entity was freed, so jecs's free list hands its dense id to the next creation
	local le2 = c.net.get_client_entity(e2)
	expect(le2 ~= nil, "the second server entity is mapped to a fresh client entity")
	expect(
		jecs.ECS_ID(le2) == jecs.ECS_ID(stale_ref) and le2 ~= stale_ref,
		"precondition: the client did not recycle the freed dense id, scenario cannot be tested"
	)

	expect_equal(
		c.net.get_server_entity(stale_ref),
		nil,
		"the stale reference resolves nothing, not the dense slot's new tenant's mapping"
	)
	expect_equal(c.net.get_server_entity(le2), e2, "the live client entity still resolves its own server id")
end)

test("locally cascade-deleting an imported entity tears down its mapping", function(env)
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	env.sync(env.player_a)
	local le = c.net.get_client_entity(e)

	-- a purely local parent; deleting it cascade-deletes the imported child
	local lp = c.world:entity()
	c.world:add(le, pair(jecs.ChildOf, lp))
	c.world:delete(lp)

	expect_equal(c.world:contains(le), false, "imported entity cascade-deleted locally")
	expect_equal(c.net.get_client_entity(e), nil, "mapping torn down by the Imported removal hook")
	expect_equal(c.net.get_server_entity(le), nil, "and the reverse mapping went with it")
end)

-- 9) client deletion semantics (safe_delete)

test("unreplicating a parent detaches imported children instead of deleting them", function(env)
	local s, c = env.server, env.client
	local p = s.world:entity()
	local ch = s.world:entity()
	s.world:add(p, s.net.Replicated)
	s.world:add(ch, s.net.Replicated)
	s.world:add(ch, pair(jecs.ChildOf, p))
	env.sync(env.player_a)

	local lp = c.net.get_client_entity(p)
	local lc = c.net.get_client_entity(ch)
	expect_equal(c.world:has(lc, pair(jecs.ChildOf, lp)), true, "child pair replicated")

	s.world:remove(p, s.net.Replicated)
	env.sync(env.player_a)

	expect_equal(c.world:contains(lp), false, "parent deleted on client")
	expect_equal(c.net.get_client_entity(p), nil, "the deleted parent's mapping is torn down with it")
	expect_equal(c.world:contains(lc), true, "imported child survives")
	expect_equal(c.net.get_client_entity(ch), lc, "child mapping intact")
	expect_equal(c.world:has(lc, pair(jecs.ChildOf, lp)), false, "child detached from the deleted parent")
end)

test("local dependents are deleted with their imported parent", function(env)
	local s, c = env.server, env.client
	local p = s.world:entity()
	s.world:add(p, s.net.Replicated)
	env.sync(env.player_a)
	local lp = c.net.get_client_entity(p)

	-- a client-only entity hanging off the imported one (e.g. a visual)
	local lx = c.world:entity()
	c.world:add(lx, pair(jecs.ChildOf, lp))

	s.world:remove(p, s.net.Replicated)
	env.sync(env.player_a)

	expect_equal(c.world:contains(lp), false, "parent deleted on client")
	expect_equal(c.world:contains(lx), false, "local dependent deleted with it")
end)

test("imported dependents of deleted local dependents are detached", function(env)
	local s, c = env.server, env.client
	local p = s.world:entity()
	local q = s.world:entity()
	s.world:add(p, s.net.Replicated)
	s.world:add(q, s.net.Replicated)
	env.sync(env.player_a)
	local lp = c.net.get_client_entity(p)
	local lq = c.net.get_client_entity(q)

	-- imported <- local <- imported chain
	local lx = c.world:entity()
	c.world:add(lx, pair(jecs.ChildOf, lp))
	c.world:add(lq, pair(jecs.ChildOf, lx))

	s.world:remove(p, s.net.Replicated)
	env.sync(env.player_a)

	expect_equal(c.world:contains(lp), false, "parent deleted on client")
	expect_equal(c.world:contains(lx), false, "local dependent deleted")
	expect_equal(c.world:contains(lq), true, "imported grandchild survives")
	expect_equal(c.net.get_client_entity(q), lq, "grandchild mapping intact")
	expect_equal(c.world:has(lq, pair(jecs.ChildOf, lx)), false, "grandchild detached")
end)

test("cyclical local relations with imported dependents delete cleanly", function(env)
	local s, c = env.server, env.client
	local p = s.world:entity()
	local q = s.world:entity()
	s.world:add(p, s.net.Replicated)
	s.world:add(q, s.net.Replicated)
	env.sync(env.player_a)
	local lp = c.net.get_client_entity(p)
	local lq = c.net.get_client_entity(q)

	-- a custom (OnDeleteTarget, Delete) relation, local to the client, used to
	-- form a cycle between two purely-local entities
	local R = c.world:entity()
	c.world:add(R, pair(jecs.OnDeleteTarget, jecs.Delete))

	local a = c.world:entity()
	local b = c.world:entity()
	c.world:add(a, pair(jecs.ChildOf, lp)) -- local dependency on the imported parent
	c.world:add(a, pair(R, b))
	c.world:add(b, pair(R, a)) -- cycle: a -> b -> a

	-- an imported entity hanging off a cycle member
	c.world:add(lq, pair(R, a))

	s.world:remove(p, s.net.Replicated)
	env.sync(env.player_a)

	expect_equal(c.world:contains(lp), false, "parent deleted on client")
	expect_equal(c.world:contains(a), false, "cycle member a deleted")
	expect_equal(c.world:contains(b), false, "cycle member b deleted")
	expect_equal(c.world:contains(lq), true, "imported dependent of the cycle survives")
	expect_equal(c.net.get_client_entity(q), lq, "imported dependent mapping intact")
	expect_equal(c.world:has(lq, pair(R, a)), false, "imported dependent detached from the deleted cycle member")
end)

-- 10) overrides

test("changed overrides replace set/add and receive nil for nulled", function(env)
	local s, c = env.server, env.client
	local health_calls = {}
	local burning_calls = {}
	c.net.set_changed_override(c.defs.Health, function(entity, value)
		table.insert(health_calls, { entity = entity, value = value })
	end)
	c.net.set_changed_override(c.defs.Burning, function(entity, value)
		table.insert(burning_calls, { entity = entity, value = value })
	end)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 9)
	s.world:add(e, s.defs.Burning)
	-- an unoverridden component rides the same packet: overrides are keyed per component, not a global switch
	s.world:set(e, s.defs.Inventory, { "axe" })
	env.sync(env.player_a)

	local le = c.net.get_client_entity(e)
	expect_equal(#health_calls, 1, "changed override call count")
	expect_equal(health_calls[1].entity, le, "override entity")
	expect_equal(health_calls[1].value, 9, "override value")
	expect_equal(c.world:has(le, c.defs.Health), false, "default set suppressed")

	expect_equal(#burning_calls, 1, "nulled override call count")
	expect_equal(burning_calls[1].entity, le, "nulled override entity")
	expect_equal(burning_calls[1].value, nil, "nulled entries pass nil")
	expect_equal(c.world:has(le, c.defs.Burning), false, "default add suppressed")

	local inventory = c.world:get(le, c.defs.Inventory)
	expect(inventory ~= nil and inventory[1] == "axe", "an unoverridden component still applies by default")
end)

test("removed overrides replace remove", function(env)
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 9)
	env.sync(env.player_a)
	local le = c.net.get_client_entity(e)

	local calls = {}
	c.net.set_removed_override(c.defs.Health, function(entity)
		table.insert(calls, entity)
	end)
	s.world:remove(e, s.defs.Health)
	env.sync(env.player_a)

	expect_equal(#calls, 1, "removed override call count")
	expect_equal(calls[1], le, "override entity")
	expect_equal(c.world:get(le, c.defs.Health), 9, "default remove suppressed")
end)

test("wildcard pair overrides apply per-relation", function(env)
	local s, c = env.server, env.client
	local calls = {}
	c.net.set_changed_override(pair(c.defs.Likes, jecs.Wildcard), function(entity, value)
		table.insert(calls, { entity = entity, value = value })
	end)

	local e1 = s.world:entity()
	local e2 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(e2, s.net.Replicated)
	s.world:set(e1, pair(s.defs.Likes, e2), 7)
	env.sync(env.player_a)

	local le1 = c.net.get_client_entity(e1)
	local le2 = c.net.get_client_entity(e2)
	expect_equal(#calls, 1, "override call count")
	expect_equal(calls[1].entity, le1, "override entity")
	expect_equal(calls[1].value, 7, "override value")
	expect_equal(c.world:has(le1, pair(c.defs.Likes, le2)), false, "default pair set suppressed")

	-- the registration keys off the relation, not "any pair": another networked relation's pair on the same
	-- subject reaches the default apply path untouched
	s.world:add(e1, pair(s.defs.Targeting, e2))
	env.sync(env.player_a)
	expect_equal(#calls, 1, "another relation's pair does not reach the Likes override")
	expect_equal(c.world:has(le1, pair(c.defs.Targeting, le2)), true, "and applies by default instead")

	-- removed overrides also key off the wildcard relation; seed the client
	-- pair directly (the changed override above suppresses any real set) so a
	-- suppressed default remove is actually observable
	local removed_calls = {}
	c.net.set_removed_override(pair(c.defs.Likes, jecs.Wildcard), function(entity)
		table.insert(removed_calls, entity)
	end)
	c.world:set(le1, pair(c.defs.Likes, le2), 7)
	s.world:remove(e1, pair(s.defs.Likes, e2))
	env.sync(env.player_a)

	expect_equal(#removed_calls, 1, "removed override call count")
	expect_equal(removed_calls[1], le1, "removed override entity")
	expect_equal(c.world:has(le1, pair(c.defs.Likes, le2)), true, "default pair remove suppressed")
	expect_equal(#calls, 1, "and the removal never dispatched to the changed override")
end)

test("override getters return registrations and nil clears them", function(env)
	local s, c = env.server, env.client
	local function noop() end

	c.net.set_changed_override(c.defs.Health, noop)
	expect_equal(c.net.get_changed_override(c.defs.Health), noop, "changed getter")
	c.net.set_changed_override(c.defs.Health, nil)
	expect_equal(c.net.get_changed_override(c.defs.Health), nil, "changed getter after clear")

	c.net.set_removed_override(pair(c.defs.Likes, jecs.Wildcard), noop)
	expect_equal(
		c.net.get_removed_override(pair(c.defs.Likes, jecs.Wildcard)),
		noop,
		"removed getter (wildcard normalized)"
	)
	-- the getters answer for the exact normalized key only: a concrete pair never reports the relation-level
	-- registration reconciliation would fall back to for it
	expect_equal(
		c.net.get_removed_override(pair(c.defs.Likes, c.world:entity())),
		nil,
		"a concrete pair reports no relation fallback"
	)
	c.net.set_removed_override(pair(c.defs.Likes, jecs.Wildcard), nil)
	expect_equal(c.net.get_removed_override(pair(c.defs.Likes, jecs.Wildcard)), nil, "removed getter after clear")

	-- cleared overrides restore default reconciliation
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 2)
	env.sync(env.player_a)
	local le = c.net.get_client_entity(e)
	expect_equal(c.world:get(le, c.defs.Health), 2, "default behavior restored")
end)

-- 11) guard rails (each triggers an intentional error)

test("guard: Networked is rejected on Replicated entities", function(env)
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 30)
	env.sync(env.player_a)
	local le = c.net.get_client_entity(e)
	expect(le ~= nil, "the entity replicated before the refused add")

	expect_error(function()
		s.world:add(e, s.net.Networked)
	end, "adding Networked to a Replicated entity", "cannot add Networked to replicated entities")
	expect_equal(s.world:has(e, s.net.Networked), false, "Networked removed by the guard before erroring")

	-- the guard removes the tag it just added, so the removed hook fires as an undo: nothing about the
	-- entity's replication may move because of it
	local packet = env.sync(env.player_a)
	expect_equal(#packet.unreplicated, 0, "the refused add announced no deletion")
	expect_equal(next(packet.components), nil, "and staged no change of any kind")
	expect_equal(c.world:contains(le), true, "the client entity survives the refusal")
	expect_equal(c.world:get(le, c.defs.Health), 30, "its replicated value is untouched")

	-- and the frames after it replicate exactly as they would have without the refusal
	s.world:set(e, s.defs.Health, 31)
	s.world:add(e, s.defs.Burning)
	env.sync(env.player_a)
	expect_equal(c.world:get(le, c.defs.Health), 31, "a later change still replicates")
	expect_equal(c.world:has(le, c.defs.Burning), true, "and so does a later add")
end)

test("guard: Networked is rejected on a Replicated entity doubling as a component id", function(env)
	-- jecs lets any entity serve as a component id, so a Replicated entity can key cells on other entities
	-- besides holding its own. the refused add's undo runs the removed hook for an id whose tracking never
	-- started, and stop_tracking_component walks world:each(component) -- so an unrecognized undo would
	-- stage a removal for every cell keyed by the holder, on entities that never left the schema they
	-- replicate under.
	local s, c = env.server, env.client
	local holder = s.world:entity()
	local subject = s.world:entity()
	s.world:add(holder, s.net.Replicated)
	s.world:add(subject, s.net.Replicated)
	s.world:set(holder, s.defs.Health, 40)
	s.world:set(subject, s.defs.Health, 41)
	s.world:add(subject, holder) -- the holder as a plain, never-networked component id
	env.sync(env.player_a)

	local le_holder = c.net.get_client_entity(holder)
	local le_subject = c.net.get_client_entity(subject)
	expect(le_holder ~= nil and le_subject ~= nil, "both entities replicated before the refused add")
	expect_equal(c.world:has(le_subject, le_holder), false, "the untracked cell itself never replicated")

	expect_error(function()
		s.world:add(holder, s.net.Networked)
	end, "adding Networked to a Replicated component id", "cannot add Networked to replicated entities")
	expect_equal(s.world:has(holder, s.net.Networked), false, "Networked removed by the guard before erroring")
	expect_equal(s.world:has(subject, holder), true, "the cell the holder keys survives the refusal")

	local packet = env.sync(env.player_a)
	expect_equal(#packet.unreplicated, 0, "the refused add announced no deletion")
	expect_equal(next(packet.components), nil, "and staged no removal for the cells the holder keys")
	expect_equal(c.world:contains(le_holder), true, "the holder survives the refusal")
	expect_equal(c.world:contains(le_subject), true, "so does the entity whose cell it keys")

	s.world:set(holder, s.defs.Health, 42)
	s.world:set(subject, s.defs.Health, 43)
	env.sync(env.player_a)
	expect_equal(c.world:get(le_holder, c.defs.Health), 42, "the holder keeps replicating")
	expect_equal(c.world:get(le_subject, c.defs.Health), 43, "and so does the entity whose cell it keys")
	-- the refusal left the holder unnetworked, so no later frame may leak the cell it keys either
	expect_equal(c.world:has(le_subject, le_holder), false, "the cell the holder keys still never replicates")
end)

test("guard: Replicated is rejected on Networked components", function(env)
	local s, c = env.server, env.client
	expect_error(function()
		s.world:add(s.defs.Health, s.net.Replicated)
	end, "adding Replicated to a Networked component", "Networked components cannot be replicated")
	expect_equal(s.world:has(s.defs.Health, s.net.Replicated), false, "Replicated removed by the guard before erroring")
	expect_equal(s.world:has(s.defs.Health, s.net.Networked), true, "the tracking tag the guard named survives")

	-- a real gameplay entity in the same frame anchors the packet, so the replicated list below reads as the
	-- definition's absence rather than as an absent packet
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 30)
	local packet = env.sync(env.player_a)
	expect_equal(#packet.replicated, 1, "only the gameplay entity is announced as replicated")
	expect_equal(packet.replicated[1], e, "and it is the one that actually carries Replicated")

	-- the definition still tracks, too: a guard that stripped the tracking tag instead of the refused add would
	-- leave the world in exactly the state the two checks above describe
	local le = c.net.get_client_entity(e)
	expect(le ~= nil, "the gameplay entity replicated")
	expect_equal(c.world:get(le, c.defs.Health), 30, "the refused definition still replicates its values")
end)

test("guard: Replicated is rejected on NetworkedUnreliable components, and the error names that tag", function(env)
	-- the refusal names whichever tracking tag owns the definition, so a reader is told which of the three to
	-- look for rather than always being pointed at Networked
	local s = env.server
	local Position = s.world:component()
	s.world:add(Position, s.net.NetworkedUnreliable)
	expect_error(function()
		s.world:add(Position, s.net.Replicated)
	end, "adding Replicated to a NetworkedUnreliable component", "NetworkedUnreliable components cannot be replicated")
	expect_equal(s.world:has(Position, s.net.Replicated), false, "Replicated removed by the guard before erroring")
	expect_equal(s.world:has(Position, s.net.NetworkedUnreliable), true, "the tag the error named survives")

	-- a real gameplay entity in the same frame anchors the packet, so the replicated list reads as the
	-- definition's absence rather than as an absent packet
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	local packet = env.sync(env.player_a)
	expect_equal(#packet.replicated, 1, "only the gameplay entity is announced as replicated")
	expect_equal(packet.replicated[1], e, "and it is the one that actually carries Replicated")
end)

test("guard: Replicated cannot be used as a pair", function(env)
	local s, c = env.server, env.client
	local e = s.world:entity()
	local t = s.world:entity()
	expect_error(function()
		s.world:add(e, pair(s.net.Replicated, t))
	end, "adding Replicated as a pair", "Replicated is not meant to be paired")
	expect_equal(s.world:has(e, s.net.Replicated), false, "pair add did not mark the entity replicated")
	expect_equal(s.world:has(e, pair(s.net.Replicated, t)), false, "the pair was removed by the guard before erroring")
	local packet = env.sync(env.player_a)
	expect_equal(#packet.replicated, 0, "nothing announced as replicated")

	-- the refusal leaves nothing behind: the same entity still replicates once it is marked properly
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 12)
	local packet2 = env.sync(env.player_a)
	expect_equal(packet2.replicated[1], e, "the entity is announced once it carries Replicated itself")
	local le = c.net.get_client_entity(e)
	expect(le ~= nil, "the entity replicated after the refusal")
	expect_equal(c.world:get(le, c.defs.Health), 12, "and its values reconcile")
end)

test("guard: Imported is rejected on non-imported entities", function(env)
	local c = env.client
	local le = c.world:entity()
	expect_error(function()
		c.world:add(le, c.net.Imported)
	end, "adding Imported to a non-imported entity", "cannot be added to entities with no server mapping")
	expect_equal(c.world:has(le, c.net.Imported), false, "Imported removed by the guard before erroring")
	expect_equal(c.net.get_server_entity(le), nil, "the refusal invented no mapping")

	-- and the guard admits what it is meant to: set_client_entity's own add of the tag must pass it
	local mapped = c.world:entity()
	c.net.set_client_entity(424242, mapped)
	expect_equal(c.world:has(mapped, c.net.Imported), true, "a mapped entity is allowed to carry Imported")
end)

-- 12) misc

test("packets referencing unknown server ids reconcile as a no-op", function(env)
	local s, c = env.server, env.client
	local bogus = 999983

	-- hand-encodes a hookless section into the packet buffer at offset (see
	-- finalize_section), returning the offset just past it. only ever emits
	-- an ids list, a removed list, or both -- never nulled -- so counts are
	-- narrow (u16) and written in has_ids/has_removed order. no inline
	-- values, so no length prefix -- the section's size follows from its
	-- counts (see the layout).
	local function write_section(data, offset, component, ids, removed)
		local ids_count = if ids then #ids else 0
		local removed_count = if removed then #removed else 0
		local flags = 0
		local list_count = 0
		if ids_count > 0 then
			flags += flag_has_ids
			list_count += 1
		end
		if removed_count > 0 then
			flags += flag_has_removed
			list_count += 1
		end
		local size = 1 + id_width + list_count * 2 + (ids_count + removed_count) * id_width
		buffer.writeu8(data, offset, flags)
		write_id(data, offset + 1, component)
		local cursor = offset + 1 + id_width
		if ids_count > 0 then
			buffer.writeu16(data, cursor, ids_count)
			cursor += 2
		end
		if removed_count > 0 then
			buffer.writeu16(data, cursor, removed_count)
			cursor += 2
		end
		if ids then
			for _, id in ids do
				write_id(data, cursor, id)
				cursor += id_width
			end
		end
		if removed then
			for _, id in removed do
				write_id(data, cursor, id)
				cursor += id_width
			end
		end
		return offset + size
	end

	-- hand-assembles the flat packet buffer (see src/wire.luau): the version
	-- byte, one unreplicated id, nothing replicated, then two sections
	-- back-to-back
	local section_size = 1 + id_width + 2 + id_width -- flags + component + one count + one id
	local data = buffer.create(version_width + 5 + 2 + id_width + section_size + section_size)
	buffer.writeu8(data, 0, wire_version) -- version
	buffer.writeu32(data, version_width, 0) -- packet_frame
	buffer.writeu8(data, version_width + 4, packet_flag_unreplicated) -- flags
	buffer.writeu16(data, version_width + 5, 1) -- unreplicated_count
	write_id(data, version_width + 7, bogus)
	local offset = version_width + 7 + id_width
	offset = write_section(data, offset, s.defs.Health, { bogus }, nil)
	write_section(data, offset, bogus + 1, nil, { bogus })

	local packet = { data = data, values = { { 1 } } }

	-- read the hand-encoding back through the authoritative decoder before reconciling it: a layout change this
	-- assembly no longer matches has to fail here, rather than quietly leave the reconcile below with nothing
	-- to skip
	local decoded = decode_packet(packet)
	expect_equal(#decoded.sections, 2, "both hand-written sections decode")
	expect_equal(decoded.unreplicated[1], bogus, "the unknown id rides the unreplicated list")
	expect_equal(decoded.sections[1].component, s.defs.Health, "the first section names a mapped component")
	expect_equal(decoded.sections[1].ids[1], bogus, "addressed to the unknown entity")
	expect_equal(decoded.sections[2].component, bogus + 1, "the second section names an unmapped component")
	expect_equal(decoded.sections[2].removed[1], bogus, "removing the unknown entity")

	expected_warning("section's component") -- the second section's component (bogus + 1) has no client mapping
	c.net.reconcile_packet(packet)
	expect_equal(c.net.get_client_entity(bogus), nil, "no mapping created for the unknown id")
	expect_equal(c.net.get_client_entity(bogus + 1), nil, "nor for the unmapped component id")
	local applied = 0
	for _ in c.world:each(c.defs.Health) do
		applied += 1
	end
	expect_equal(applied, 0, "and the section's side-array value landed on nothing")

	-- and the client is not wedged by either skip: an ordinary packet still reconciles after it
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 8)
	env.sync(env.player_a)
	local le = c.net.get_client_entity(e)
	expect(le ~= nil, "the entity created after the unknown-id packet still replicated")
	expect_equal(c.world:get(le, c.defs.Health), 8, "and its value applied")
end)

test("reconcile_packet errors loudly on a wire format version mismatch", function(env)
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 1)

	local packet = env.frame()[env.player_a]
	buffer.writeu8(packet.data, 0, wire_version + 1)
	expect_error(function()
		c.net.reconcile_packet(packet)
	end, "reconciling a packet with a mismatched wire format version", "wire format version")
	expect_equal(c.net.get_client_entity(e), nil, "the refused packet applied nothing, not even its entity list")

	-- the byte is the only thing wrong with it: restored, the very same packet reconciles, so the refusal above
	-- is the version check firing rather than a reconcile that errors on anything
	buffer.writeu8(packet.data, 0, wire_version)
	c.net.reconcile_packet(packet)
	local le = c.net.get_client_entity(e)
	expect(le ~= nil, "the restored packet created the entity")
	expect_equal(c.world:get(le, c.defs.Health), 1, "and applied its value")
end)

test("get_packet_frame errors loudly on a wire format version mismatch", function(env)
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 1)

	local packet = env.frame()[env.player_a]
	-- the intact packet reads back first, so the refusal below is the version check firing rather than a reader
	-- that errors on everything
	expect_equal(c.net.get_packet_frame(packet), packet.frame, "the frame reads back before the corruption")
	buffer.writeu8(packet.data, 0, wire_version + 1)
	expect_error(function()
		c.net.get_packet_frame(packet)
	end, "getting the packet frame of a packet with a mismatched wire format version", "wire format version")
end)

test("decode_packet errors loudly on a wire format version mismatch", function(env)
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 1)

	local packet = env.frame()[env.player_a]
	-- the intact packet decodes first, so the refusal below is the version check firing rather than a decoder
	-- that errors on everything
	expect(decode_packet(packet).components[s.defs.Health] ~= nil, "the packet decodes before the corruption")
	buffer.writeu8(packet.data, 0, wire_version + 1)
	expect_error(function()
		decode_packet(packet)
	end, "decoding a packet with a mismatched wire format version", "wire format version")
end)

-- 13) whitelist editing and visibility corrections

test("whitelist values are frozen against in-place mutation", function(env)
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 1)
	local whitelist = { [env.player_a] = true }
	s.world:set(e, pair(s.net.Private, s.defs.Health), whitelist)

	expect_equal(table.isfrozen(whitelist), true, "value frozen on set")
	expect_error(function()
		whitelist[env.player_b] = true
	end, "in-place mutation", "readonly table")

	-- re-setting an already-frozen value must not error
	s.world:set(e, pair(s.net.Private, s.defs.Health), whitelist)

	-- and it must not be skipped as a no-op either: the filter the re-set installs is still the one in force
	local snapshot = env.frame()
	local packet_a = env.packet_for(snapshot, env.player_a)
	local packet_b = env.packet_for(snapshot, env.player_b)
	local data_a = packet_a.components[s.defs.Health]
	expect(data_a ~= nil and data_a.values ~= nil and data_a.values[1] == 1, "the frozen whitelist admits A")
	expect_equal(#packet_b.replicated, 1, "B receives the entity creation")
	expect_equal(packet_b.components[s.defs.Health], nil, "and the frozen whitelist still blocks B")
end)

test("assigning a whitelist naming only an unregistered player blocks everyone", function(env)
	-- an unregistered player has no slot, so its bit never enters the mask.
	-- sanitize_privacy silently skips and prunes them from the cached table
	-- instead of erroring, leaving the whitelist equivalent to an empty one.
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 42)

	local stranger = fake_player("Stranger") -- never passed to add_client
	expected_warning("untracked client(s)! they were pruned from it")
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [stranger] = true })

	local snapshot = env.frame()
	local packet_a = env.packet_for(snapshot, env.player_a)
	expect_equal(#packet_a.replicated, 1, "the entity itself still replicates to player A")
	expect_equal(packet_a.components[s.defs.Health], nil, "player A blocked")
	expect_equal(env.packet_for(snapshot, env.player_b).components[s.defs.Health], nil, "player B blocked")
	env.apply(packet_a)
	local le = c.net.get_client_entity(e)
	expect(le ~= nil, "player A's client holds the entity")
	expect_equal(c.world:has(le, c.defs.Health), false, "without the blocked component")

	-- the prune persists: edit_component_privacy clones the cached (already-pruned) table,
	-- so the stranger never reappears through the copy-on-write edit path.
	s.net.edit_component_privacy(e, s.defs.Health, env.player_a, true)
	env.apply(env.packet_for(env.frame(), env.player_a))
	local final = s.world:get(e, pair(s.net.Private, s.defs.Health))
	expect_equal(final[stranger], nil, "stranger pruned from the persisted whitelist")
	expect_equal(final[env.player_a], true, "player_a present in the persisted whitelist")
	expect_equal(c.world:get(le, c.defs.Health), 42, "and the admitted player receives the value")
end)

test("allowing a player edits copy-on-write, leaving the old value untouched", function(env)
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 1)
	local original = { [env.player_a] = true }
	s.world:set(e, pair(s.net.Private, s.defs.Health), original)

	s.net.edit_component_privacy(e, s.defs.Health, env.player_b, true)

	expect_equal(original[env.player_b], nil, "old value not mutated")
	local current = s.world:get(e, pair(s.net.Private, s.defs.Health))
	expect(current ~= original, "a fresh value was set")
	expect_equal(current[env.player_a], true, "existing entries carried over")
	expect_equal(current[env.player_b], true, "player added")
	expect_equal(table.isfrozen(current), true, "new value frozen")
end)

test("allowing a player sends the newly allowed player the current value", function(env)
	local s = env.server
	local c2 = env.make_client()
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 42)
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_a] = true })

	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, env.player_a))
	env.apply(env.packet_for(snapshot, env.player_b), c2)
	local le_b = c2.net.get_client_entity(e)
	expect_equal(c2.world:has(le_b, c2.defs.Health), false, "B blocked before the edit")

	s.net.edit_component_privacy(e, s.defs.Health, env.player_b, true)
	local snapshot2 = env.frame()
	expect_equal(env.packet_for(snapshot2, env.player_a).components[s.defs.Health], nil, "A receives nothing")
	env.apply(env.packet_for(snapshot2, env.player_b), c2)
	expect_equal(c2.world:get(le_b, c2.defs.Health), 42, "B received the current value")
end)

test("disallowing a player removes the data from the revoked player's client", function(env)
	local s, c = env.server, env.client
	local c2 = env.make_client()
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 42)
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_a] = true, [env.player_b] = true })

	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, env.player_a))
	env.apply(env.packet_for(snapshot, env.player_b), c2)
	local le_a = c.net.get_client_entity(e)
	local le_b = c2.net.get_client_entity(e)
	expect_equal(c2.world:get(le_b, c2.defs.Health), 42, "B sees the value before the edit")

	s.net.edit_component_privacy(e, s.defs.Health, env.player_b, false)
	local snapshot2 = env.frame()
	env.apply(env.packet_for(snapshot2, env.player_a))
	env.apply(env.packet_for(snapshot2, env.player_b), c2)
	expect_equal(c.world:get(le_a, c.defs.Health), 42, "A keeps the value")
	expect_equal(c2.world:has(le_b, c2.defs.Health), false, "B's stale value removed")
	-- only the component was revoked, so the absence above must not be a dead entity reading as one
	expect_equal(c2.world:contains(le_b), true, "B's client entity survives the component revocation")
end)

test("redundant allow/disallow edits are no-ops", function(env)
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 1)
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_a] = true })

	env.frame()

	local before = s.world:get(e, pair(s.net.Private, s.defs.Health))
	s.net.edit_component_privacy(e, s.defs.Health, env.player_a, true) -- already allowed
	s.net.edit_component_privacy(e, s.defs.Health, env.player_b, false) -- already absent
	expect_equal(s.world:get(e, pair(s.net.Private, s.defs.Health)), before, "whitelist value unchanged")

	local snapshot2 = env.frame()
	expect_equal(next(env.packet_for(snapshot2, env.player_a).components), nil, "no data for A")
	expect_equal(next(env.packet_for(snapshot2, env.player_b).components), nil, "no data for B")

	-- silence alone would also describe a filter the no-op edits quietly dropped from the caches, so make the
	-- filter speak: the next value change still reaches exactly the whitelisted player
	s.world:set(e, s.defs.Health, 2)
	local snapshot3 = env.frame()
	local data_a = env.packet_for(snapshot3, env.player_a).components[s.defs.Health]
	expect(data_a ~= nil and data_a.values ~= nil and data_a.values[1] == 2, "A still receives changes")
	expect_equal(env.packet_for(snapshot3, env.player_b).components[s.defs.Health], nil, "B is still blocked")
end)

test("editing with no filter configured: allow warns and does nothing, disallow creates a blacklist", function(env)
	-- with no filter configured there is nothing to allow into, so allowing
	-- still warns and no-ops; but disallowing is unambiguous (no filter admits
	-- everyone), so it now starts a single-client blacklist instead of warning.
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 1)
	env.sync(env.player_a)

	expected_warning("cannot allow a client without a whitelist")
	s.net.edit_component_privacy(e, s.defs.Health, env.player_b, true)
	expect_equal(s.world:has(e, pair(s.net.Private, s.defs.Health)), false, "no filter created by the allow")

	s.net.edit_component_privacy(e, s.defs.Health, env.player_a, false)
	local created = s.world:get(e, pair(s.net.Private, s.defs.Health))
	expect(created ~= nil, "the disallow starts a blacklist rather than warning")
	expect_equal(created[env.player_a], false, "the disallowed client is named")
	expect_equal(next(created, next(created)), nil, "the blacklist names exactly one client")
	expect_equal(table.isfrozen(created), true, "the new blacklist is frozen")

	-- and it takes effect with blacklist polarity: the named client loses the value, everyone else keeps it
	local snapshot = env.frame()
	local data_a = env.packet_for(snapshot, env.player_a).components[s.defs.Health]
	expect(data_a ~= nil and data_a.removed ~= nil and data_a.removed[1] == e, "A's value is revoked")
	expect_equal(env.packet_for(snapshot, env.player_b).components[s.defs.Health], nil, "B is untouched")
	env.apply(env.packet_for(snapshot, env.player_a))
	local le = c.net.get_client_entity(e)
	expect(le ~= nil, "A's client still holds the entity")
	expect_equal(c.world:has(le, c.defs.Health), false, "with the revoked component gone")
end)

test("allowing a player on an empty whitelist starts from blocking everyone", function(env)
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 7)
	s.world:set(e, pair(s.net.Private, s.defs.Health), {}) -- empty: blocks everyone

	local snapshot = env.frame()
	local packet_a = env.packet_for(snapshot, env.player_a)
	expect_equal(#packet_a.replicated, 1, "the entity itself replicates to A")
	expect_equal(packet_a.components[s.defs.Health], nil, "but the empty filter blocks A")
	expect_equal(env.packet_for(snapshot, env.player_b).components[s.defs.Health], nil, "and blocks B")
	env.apply(packet_a)
	local le = c.net.get_client_entity(e)
	expect(le ~= nil, "A's client holds the entity")
	expect_equal(c.world:has(le, c.defs.Health), false, "without the blocked component")

	s.net.edit_component_privacy(e, s.defs.Health, env.player_a, true)
	local snapshot2 = env.frame()
	local data_a = env.packet_for(snapshot2, env.player_a).components[s.defs.Health]
	expect(data_a ~= nil and data_a.values ~= nil and data_a.values[1] == 7, "A receives the value")
	expect_equal(env.packet_for(snapshot2, env.player_b).components[s.defs.Health], nil, "B still blocked")
	env.apply(env.packet_for(snapshot2, env.player_a))
	expect_equal(c.world:get(le, c.defs.Health), 7, "and applies it")
end)

test("allowing a player on a relation sends existing pair values to the newly allowed player", function(env)
	local s = env.server
	local c2 = env.make_client()
	local e1 = s.world:entity()
	local e2 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(e2, s.net.Replicated)
	s.world:set(e1, pair(s.defs.Likes, e2), 4)
	s.world:set(e1, pair(s.net.Private, s.defs.Likes), { [env.player_a] = true })

	local snapshot = env.frame()
	local data_a = env.packet_for(snapshot, env.player_a).components[pair(s.defs.Likes, e2)]
	expect(data_a ~= nil and data_a.values ~= nil and data_a.values[1] == 4, "the whitelisted player has it")
	env.apply(env.packet_for(snapshot, env.player_b), c2)
	local le1 = c2.net.get_client_entity(e1)
	local le2 = c2.net.get_client_entity(e2)
	expect(le1 ~= nil and le2 ~= nil, "B holds both entities: only the relation is filtered")
	expect_equal(c2.world:has(le1, pair(c2.defs.Likes, le2)), false, "B blocked before the edit")

	s.net.edit_component_privacy(e1, s.defs.Likes, env.player_b, true)
	env.apply(env.packet_for(env.frame(), env.player_b), c2)
	expect_equal(c2.world:get(le1, pair(c2.defs.Likes, le2)), 4, "B received the pair value")
end)

test("disallowing a player on a relation removes existing pairs from the revoked player's client", function(env)
	local s, c = env.server, env.client
	local c2 = env.make_client()
	local e1 = s.world:entity()
	local e2 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(e2, s.net.Replicated)
	s.world:set(e1, pair(s.defs.Likes, e2), 4)
	s.world:set(e1, pair(s.net.Private, s.defs.Likes), { [env.player_a] = true, [env.player_b] = true })

	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, env.player_a))
	env.apply(env.packet_for(snapshot, env.player_b), c2)
	local le1_a = c.net.get_client_entity(e1)
	local le2_a = c.net.get_client_entity(e2)
	local le1 = c2.net.get_client_entity(e1)
	local le2 = c2.net.get_client_entity(e2)
	expect_equal(c.world:get(le1_a, pair(c.defs.Likes, le2_a)), 4, "A sees the pair before the edit")
	expect_equal(c2.world:get(le1, pair(c2.defs.Likes, le2)), 4, "B sees the pair before the edit")

	s.net.edit_component_privacy(e1, s.defs.Likes, env.player_b, false)
	local snapshot2 = env.frame()
	env.apply(env.packet_for(snapshot2, env.player_a))
	env.apply(env.packet_for(snapshot2, env.player_b), c2)
	expect_equal(c2.world:has(le1, pair(c2.defs.Likes, le2)), false, "B's pair removed")
	expect_equal(c2.world:contains(le1), true, "B's client entity should survive the pair revocation")
	expect_equal(c.world:get(le1_a, pair(c.defs.Likes, le2_a)), 4, "A keeps the pair the edit did not name")
	expect_equal(s.world:get(e1, pair(s.defs.Likes, e2)), 4, "server pair untouched")
end)

test("wholesale whitelist replacement diffs into per-player sends and removals", function(env)
	local s, c = env.server, env.client
	local c2 = env.make_client()
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 9)
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_a] = true })

	local snapshot = env.frame()
	local first_a = env.packet_for(snapshot, env.player_a)
	local first_b = env.packet_for(snapshot, env.player_b)
	local first_data = first_a.components[s.defs.Health]
	expect(first_data ~= nil and first_data.values ~= nil and first_data.values[1] == 9, "A holds it first")
	expect_equal(first_b.components[s.defs.Health], nil, "B does not")
	env.apply(first_a)
	env.apply(first_b, c2)
	local le_a = c.net.get_client_entity(e)
	local le_b = c2.net.get_client_entity(e)
	expect(le_a ~= nil and le_b ~= nil, "both clients hold the entity itself")

	-- A revoked and B granted in a single replacement
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_b] = true })
	local snapshot2 = env.frame()
	local data_a = env.packet_for(snapshot2, env.player_a).components[s.defs.Health]
	local data_b = env.packet_for(snapshot2, env.player_b).components[s.defs.Health]
	expect(data_a ~= nil and data_a.removed ~= nil and data_a.removed[1] == e, "A receives a removal")
	expect(data_b ~= nil and data_b.values ~= nil and data_b.values[1] == 9, "B receives the value")
	env.apply(env.packet_for(snapshot2, env.player_a))
	env.apply(env.packet_for(snapshot2, env.player_b), c2)
	expect_equal(c.world:has(le_a, c.defs.Health), false, "so A loses it end to end")
	expect_equal(c.world:contains(le_a), true, "keeping the entity the component rode on")
	expect_equal(c2.world:get(le_b, c2.defs.Health), 9, "while B gains it end to end")
end)

test("setting a whitelist's value to nil narrows the component to nobody", function(env)
	-- a whitelist set to nil is not a removed whitelist but an emptied one, and an empty filter blocks
	-- everyone: the client the whitelist admitted loses the component rather than the excluded ones gaining it.
	local s, c = env.server, env.client
	local c2 = env.make_client()
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 5)
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_a] = true })

	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, env.player_a))
	env.apply(env.packet_for(snapshot, env.player_b), c2)
	local le_a = c.net.get_client_entity(e)
	local le_b = c2.net.get_client_entity(e)
	expect_equal(c.world:get(le_a, c.defs.Health), 5, "A, whitelisted, sees the value before the edit")
	expect_equal(c2.world:has(le_b, c2.defs.Health), false, "B, excluded, does not")

	expected_warning("cannot have a nil value")
	s.world:set(e, pair(s.net.Private, s.defs.Health), nil)
	expect_equal(s.world:has(e, pair(s.net.Private, s.defs.Health)), true, "the filter was emptied, not removed")
	expect_equal(s.net.is_component_visible(e, s.defs.Health, env.player_a), false, "so A loses the component")
	expect_equal(s.net.is_component_visible(e, s.defs.Health, env.player_b), false, "and B never gains it")

	local snapshot2 = env.frame()
	local packet_a = env.packet_for(snapshot2, env.player_a)
	local packet_b = env.packet_for(snapshot2, env.player_b)
	local data_a = packet_a.components[s.defs.Health]
	expect(data_a ~= nil and data_a.removed ~= nil and data_a.removed[1] == e, "A, the admitted one, is sent a removal")
	expect_equal(packet_b.components[s.defs.Health], nil, "B, already blocked, is sent nothing")
	env.apply(packet_a)
	env.apply(packet_b, c2)
	expect_equal(c.world:has(le_a, c.defs.Health), false, "A loses the value end to end")
	expect_equal(c.world:contains(le_a), true, "keeping the entity the component rode on")
	expect_equal(c2.world:has(le_b, c2.defs.Health), false, "and B still holds nothing")
end)

test("adding a whitelist pair revokes the data from players outside it", function(env)
	local s, c = env.server, env.client
	local c2 = env.make_client()
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 5)

	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, env.player_a))
	env.apply(env.packet_for(snapshot, env.player_b), c2)
	local le_b = c2.net.get_client_entity(e)
	expect_equal(c2.world:get(le_b, c2.defs.Health), 5, "B sees the public value")

	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_a] = true })
	local snapshot2 = env.frame()
	local packet_b = env.packet_for(snapshot2, env.player_b)
	local data_b = packet_b.components[s.defs.Health]
	expect(data_b ~= nil and data_b.removed ~= nil and data_b.removed[1] == e, "B is sent the removal")
	-- A stayed admitted, so A's mask never moved: the edit costs A no traffic at all
	expect_equal(env.packet_for(snapshot2, env.player_a).components[s.defs.Health], nil, "A is sent nothing")
	env.apply(env.packet_for(snapshot2, env.player_a))
	env.apply(packet_b, c2)
	expect_equal(c.world:get(c.net.get_client_entity(e), c.defs.Health), 5, "A keeps the value")
	expect_equal(c2.world:has(le_b, c2.defs.Health), false, "B's now-private value removed")
	expect_equal(c2.world:contains(le_b), true, "B's client entity should survive the revocation")
end)

test("removing a whitelist pair sends the current value to players outside it", function(env)
	local s, c = env.server, env.client
	local c2 = env.make_client()
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 5)
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_a] = true })

	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, env.player_a))
	env.apply(env.packet_for(snapshot, env.player_b), c2)
	local le_a = c.net.get_client_entity(e)
	local le_b = c2.net.get_client_entity(e)

	-- changes while B is excluded never reach B -- but they do reach A, which is what makes the
	-- exclusion meaningful rather than the change simply never having shipped to anyone
	s.world:set(e, s.defs.Health, 6)
	local mid = env.frame()
	env.apply(env.packet_for(mid, env.player_a))
	env.apply(env.packet_for(mid, env.player_b), c2)
	expect_equal(c.world:get(le_a, c.defs.Health), 6, "A receives the change")
	expect_equal(c2.world:has(le_b, c2.defs.Health), false, "B still blocked")

	s.world:remove(e, pair(s.net.Private, s.defs.Health))
	local packet_b = env.packet_for(env.frame(), env.player_b)
	local data_b = packet_b.components[s.defs.Health]
	expect(
		data_b ~= nil and data_b.values ~= nil and data_b.values[1] == 6,
		"B is sent the current value, not the one it held when it was excluded"
	)
	env.apply(packet_b, c2)
	expect_equal(c2.world:get(le_b, c2.defs.Health), 6, "B receives the current value once public")
end)

test("whitelists added before Replicated filter from the first packet", function(env)
	local s = env.server
	local c2 = env.make_client()

	local e = s.world:entity()
	s.world:set(e, s.defs.Health, 5)
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_a] = true })
	s.world:add(e, s.net.Replicated)

	local snapshot = env.frame()
	local data_a = env.packet_for(snapshot, env.player_a).components[s.defs.Health]
	expect(data_a ~= nil and data_a.values ~= nil and data_a.values[1] == 5, "A receives the value")
	-- B's packet is anchored by the entity creation: the entity-level gate is open, so the missing
	-- Health is the per-component filter's doing rather than B having received no packet at all
	local packet_b = env.packet_for(snapshot, env.player_b)
	expect_equal(packet_b.replicated[1], e, "B receives the entity creation")
	expect_equal(packet_b.components[s.defs.Health], nil, "B's packet carries no Health section")
	env.apply(packet_b, c2)
	local le_b = c2.net.get_client_entity(e)
	expect(le_b ~= nil, "B's client entity was created")
	expect_equal(c2.world:has(le_b, c2.defs.Health), false, "B never receives the private value")
end)

test("a whitelist grant is delivered exactly once", function(env)
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 5)
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_a] = true })

	local snapshot = env.frame()
	env.packet_for(snapshot, env.player_a)
	env.packet_for(snapshot, env.player_b)

	s.net.edit_component_privacy(e, s.defs.Health, env.player_b, true)
	local first = env.packet_for(env.frame(), env.player_b)
	local data_b = first.components[s.defs.Health]
	expect(data_b ~= nil and data_b.values ~= nil and data_b.values[1] == 5, "grant delivered")
	expect_equal(data_b.ids[1], e, "the grant names the whitelisted entity")
	expect_equal(data_b.values[2], nil, "exactly one value entry")
	local second = env.packet_for(env.frame(), env.player_b)
	expect_equal(next(second.components), nil, "grant not delivered twice")
end)

test("unreplicating an entity the same frame as a revocation deletes it wholesale", function(env)
	local s = env.server
	local c2 = env.make_client()
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 5)
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_a] = true, [env.player_b] = true })

	local snapshot = env.frame()
	env.packet_for(snapshot, env.player_a)
	env.apply(env.packet_for(snapshot, env.player_b), c2)
	local le_b = c2.net.get_client_entity(e)
	expect_equal(c2.world:get(le_b, c2.defs.Health), 5, "B holds the private value before the teardown")

	-- a revocation and an unreplication in the same frame: the entity is torn
	-- down wholesale, taking the stale value with it. any same-frame removal of
	-- Health is harmless -- reconcile deletes the entity before reaching it.
	s.net.edit_component_privacy(e, s.defs.Health, env.player_b, false)
	s.world:remove(e, s.net.Replicated)
	local packet_b = env.packet_for(env.frame(), env.player_b)
	expect_equal(packet_b.unreplicated[1], e, "unreplication announced")
	expect_equal(#packet_b.unreplicated, 1, "exactly the one entity")
	env.apply(packet_b, c2)
	expect_equal(c2.world:contains(le_b), false, "B's entity deleted wholesale")
	expect_equal(c2.net.get_client_entity(e), nil, "and its mapping torn down with it")
end)

test("a revocation merges into the same component data as a value change", function(env)
	local s = env.server
	local e1 = s.world:entity()
	local e2 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(e2, s.net.Replicated)
	s.world:set(e1, s.defs.Health, 1)
	s.world:set(e2, s.defs.Health, 2)
	s.world:set(e1, pair(s.net.Private, s.defs.Health), { [env.player_a] = true, [env.player_b] = true })

	local snapshot = env.frame()
	env.packet_for(snapshot, env.player_a)
	env.packet_for(snapshot, env.player_b)

	-- same frame: a public change on e2 and a revocation on e1
	s.world:set(e2, s.defs.Health, 3)
	s.net.edit_component_privacy(e1, s.defs.Health, env.player_b, false)

	local snapshot2 = env.frame()
	local data_b = env.packet_for(snapshot2, env.player_b).components[s.defs.Health]
	expect(data_b ~= nil, "component data present")
	expect(data_b.ids ~= nil and data_b.ids[1] == e2 and data_b.values[1] == 3, "value change delivered")
	expect(data_b.removed ~= nil and data_b.removed[1] == e1, "revocation merged into the same component data")
	expect_equal(data_b.removed[2], nil, "B loses only the revoked cell")
	expect_equal(data_b.ids[2], nil, "and is sent only the changed one")

	-- A kept its grant, so the revocation is B's alone: A sees the value change and nothing else
	local data_a = env.packet_for(snapshot2, env.player_a).components[s.defs.Health]
	expect(
		data_a ~= nil and data_a.ids ~= nil and data_a.ids[1] == e2 and data_a.values[1] == 3,
		"A receives the public value change"
	)
	expect_equal(data_a.removed, nil, "A receives no revocation")
end)

test("a same-frame value change after allowing a player is sent once with the final value", function(env)
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 1)
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_a] = true })

	local snapshot = env.frame()
	env.packet_for(snapshot, env.player_a)
	env.packet_for(snapshot, env.player_b)

	s.net.edit_component_privacy(e, s.defs.Health, env.player_b, true)
	s.world:set(e, s.defs.Health, 2)
	local data_b = env.packet_for(env.frame(), env.player_b).components[s.defs.Health]
	expect(data_b ~= nil and data_b.values ~= nil, "B receives a value")
	expect_equal(data_b.values[1], 2, "the latest value")
	expect_equal(data_b.values[2], nil, "exactly one value entry")
	expect_equal(data_b.ids[2], nil, "no duplicate ids")
	expect_equal(data_b.removed, nil, "and no removal riding alongside the grant")
end)

test("allowing a player on a NetworkedOnce component sends the value at packet time", function(env)
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Cooldown, 5)
	s.world:set(e, pair(s.net.Private, s.defs.Cooldown), { [env.player_a] = true })

	local snapshot = env.frame()
	env.packet_for(snapshot, env.player_a)
	env.packet_for(snapshot, env.player_b)

	s.net.edit_component_privacy(e, s.defs.Cooldown, env.player_b, true)
	s.world:set(e, s.defs.Cooldown, 3) -- suppressed by NetworkedOnce, but resolved at drain
	local snapshot2 = env.frame()
	local data_b = env.packet_for(snapshot2, env.player_b).components[s.defs.Cooldown]
	expect(
		data_b ~= nil and data_b.values ~= nil and data_b.values[1] == 3,
		"B receives the live value, not the value at edit time"
	)
	-- the other half of the claim: the change itself stays untracked, so A -- already admitted, and
	-- still holding the stale 5 -- is sent nothing at all
	expect_equal(
		env.packet_for(snapshot2, env.player_a).components[s.defs.Cooldown],
		nil,
		"the NetworkedOnce change never reaches the already-admitted player"
	)
end)

test("same-frame whitelist churn resolves to the final state", function(env)
	local s = env.server
	local c2 = env.make_client()
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 8)
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_a] = true, [env.player_b] = true })

	local snapshot = env.frame()
	env.packet_for(snapshot, env.player_a)
	env.apply(env.packet_for(snapshot, env.player_b), c2)
	local le_b = c2.net.get_client_entity(e)

	s.net.edit_component_privacy(e, s.defs.Health, env.player_b, false)
	s.net.edit_component_privacy(e, s.defs.Health, env.player_b, true)
	-- an unrelated public change in the same frame anchors B's packet as a real one, so the absent
	-- Health section below cannot be an artifact of B receiving no packet at all
	s.world:set(e, s.defs.Inventory, { "anchor" })
	local packet_b = env.packet_for(env.frame(), env.player_b)
	env.apply(packet_b, c2)
	-- a whitelist toggled and reverted in one frame clears the staged entry
	-- entirely (see set_visibility in src/server.luau), so B's packet should
	-- carry no Health section at all this frame, not merely no removal
	expect_equal(packet_b.components[s.defs.Health], nil, "no Health section for a player that ended the frame allowed")
	expect(packet_b.components[s.defs.Inventory] ~= nil, "the anchoring change did reach B")
	expect_equal(c2.world:get(le_b, c2.defs.Health), 8, "B's value intact")
end)

test("a whitelist edit during a same-frame replication bounce still corrects", function(env)
	local s, c = env.server, env.client
	local c2 = env.make_client()
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 10)
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_a] = true, [env.player_b] = true })

	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, env.player_a))
	env.apply(env.packet_for(snapshot, env.player_b), c2)
	local le_b = c2.net.get_client_entity(e)
	expect_equal(c2.world:get(le_b, c2.defs.Health), 10, "B sees the value before the bounce")

	-- unreplicate -> edit -> re-replicate within one frame: clients never
	-- observe the bounce, so the revocation must still reach B
	s.world:remove(e, s.net.Replicated)
	s.net.edit_component_privacy(e, s.defs.Health, env.player_b, false)
	s.world:add(e, s.net.Replicated)

	local snapshot2 = env.frame()
	local packet_b = env.packet_for(snapshot2, env.player_b)
	expect_equal(#packet_b.unreplicated, 0, "the bounce is never announced to B")
	expect_equal(#packet_b.replicated, 0, "nor re-announced to B as a creation")
	local data_b = packet_b.components[s.defs.Health]
	expect(data_b ~= nil and data_b.removed ~= nil and data_b.removed[1] == e, "B receives the revocation")
	env.apply(env.packet_for(snapshot2, env.player_a))
	env.apply(packet_b, c2)
	expect_equal(c2.world:contains(le_b), true, "B's entity survives the bounce")
	expect_equal(c2.world:has(le_b, c2.defs.Health), false, "B's stale value removed")
	expect_equal(c.world:get(c.net.get_client_entity(e), c.defs.Health), 10, "A keeps the value")
end)

test("a pair removed before a same-frame relation disallow still revokes", function(env)
	local s = env.server
	local c2 = env.make_client()
	local e1 = s.world:entity()
	local e2 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(e2, s.net.Replicated)
	s.world:set(e1, pair(s.defs.Likes, e2), 4)
	s.world:set(e1, pair(s.net.Private, s.defs.Likes), { [env.player_a] = true, [env.player_b] = true })

	local snapshot = env.frame()
	env.packet_for(snapshot, env.player_a)
	env.apply(env.packet_for(snapshot, env.player_b), c2)
	local le1 = c2.net.get_client_entity(e1)
	local le2 = c2.net.get_client_entity(e2)
	expect_equal(c2.world:get(le1, pair(c2.defs.Likes, le2)), 4, "B sees the pair before the edit")

	-- the pair was already removed when the disallow runs, so the disallow
	-- restages nothing; the removal still reaches B because its mask comes from
	-- the last-sent visibility (which included B), not the current whitelist
	s.world:remove(e1, pair(s.defs.Likes, e2))
	s.net.edit_component_privacy(e1, s.defs.Likes, env.player_b, false)

	local snapshot2 = env.frame()
	local packet_b = env.packet_for(snapshot2, env.player_b)
	local data_b = packet_b.components[pair(s.defs.Likes, e2)]
	expect(data_b ~= nil and data_b.removed ~= nil and data_b.removed[1] == e1, "B is sent the explicit removal")
	-- A stayed whitelisted, so the removal reaching A as well is what shows the mask came from the
	-- last-sent visibility rather than from the post-edit whitelist
	local data_a = env.packet_for(snapshot2, env.player_a).components[pair(s.defs.Likes, e2)]
	expect(data_a ~= nil and data_a.removed ~= nil and data_a.removed[1] == e1, "A is sent it too")
	env.apply(packet_b, c2)
	expect_equal(c2.world:has(le1, pair(c2.defs.Likes, le2)), false, "B's stale pair removed")
end)

test("a value change and a same-cell revocation split into value and removal", function(env)
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 1)
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_a] = true, [env.player_b] = true })
	env.frame() -- both see Health = 1

	-- same frame, same cell: a value change plus a revocation of B. the value
	-- defers to the post-merge mask (A only) while B's removal comes from the
	-- visibility diff, so the two split cleanly within one component group.
	s.world:set(e, s.defs.Health, 2)
	s.net.edit_component_privacy(e, s.defs.Health, env.player_b, false)

	local snapshot = env.frame()
	local data_a = env.packet_for(snapshot, env.player_a).components[s.defs.Health]
	expect(data_a ~= nil and data_a.values ~= nil and data_a.values[1] == 2, "A receives the new value")
	expect_equal(data_a.removed, nil, "A receives no removal")

	local data_b = env.packet_for(snapshot, env.player_b).components[s.defs.Health]
	expect(data_b ~= nil and data_b.removed ~= nil and data_b.removed[1] == e, "B receives the removal")
	expect_equal(data_b.values, nil, "B receives no value")
end)

-- 14) player slots, recycling, and visibility queries

test("a removed player receives no further packets while others continue", function(env)
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 100)
	env.frame() -- drain the initial change for both standard players

	s.net.remove_client(env.player_b)

	s.world:set(e, s.defs.Health, 55)
	-- the raw map (not env.frame) so a missing player reads as nil rather than the
	-- empty-packet metatable fallback
	local packets = s.net.generate_packets()
	expect_equal(packets[env.player_b], nil, "removed player gets no packet at all")

	local data_a = decode_packet(packets[env.player_a]).components[s.defs.Health]
	expect(data_a ~= nil and data_a.values ~= nil and data_a.values[1] == 55, "remaining player still receives changes")
end)

test("removing a pending player before allocation is a clean no-op", function(env)
	local s = env.server
	local pending = fake_player("Pending")
	s.net.add_client(pending)
	s.net.remove_client(pending) -- removed while still pending, before a slot exists

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 1)

	local packets = s.net.generate_packets()
	expect_equal(packets[pending], nil, "pending-then-removed player never gets a packet")
	expect(packets[env.player_a] ~= nil, "existing players are unaffected")
	expect(packets[env.player_b] ~= nil, "both of them")
	local decoded_a = decode_packet(packets[env.player_a])
	expect_equal(decoded_a.replicated[1], e, "and still receive the new entity")
	local data_a = decoded_a.components[s.defs.Health]
	expect(data_a ~= nil and data_a.values ~= nil and data_a.values[1] == 1, "with its value")
end)

test("whitelisting a still-pending player is honored once they're allocated", function(env)
	-- a whitelist naming a joiner who is registered but not yet allocated a slot
	-- (still pending) is kept rather than pruned: sanitize_privacy skips their
	-- bit for now, and allocate_client grants it at slot allocation, right before
	-- full_packet resolves the joiner's first snapshot from the caches.
	local s = env.server
	local pending = fake_player("Pending")
	s.net.add_client(pending)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 77)
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [pending] = true })

	local packets = env.frame() -- allocates pending and builds its full packet
	local data = packets[pending].components[s.defs.Health]
	expect(
		data ~= nil and data.values ~= nil and data.values[1] == 77,
		"the newly-allocated player receives the whitelisted value in their first packet"
	)
	-- A's packet is anchored by the entity creation, so the missing Health section below is the
	-- whitelist's doing rather than A having received nothing at all
	local packet_a = packets[env.player_a]
	expect_equal(packet_a.replicated[1], e, "a player outside the whitelist still receives the entity")
	expect_equal(packet_a.components[s.defs.Health], nil, "a player outside the whitelist still does not receive it")
end)

test("removing a pending client prunes them from a cached whitelist set while they were pending", function(env)
	local s = env.server
	local pending = fake_player("Pending")
	s.net.add_client(pending) -- pending, never allocated

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 3)
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [pending] = true }) -- pending clients are kept in the cache

	s.net.remove_client(pending) -- removed while still pending, before any generate

	-- pending re-registers under the same identity and properly joins later;
	-- without the departure prune they would still be cached and admitted
	local c2 = env.make_client()
	local packet = env.join(pending, c2)
	expect_equal(packet.replicated[1], e, "the rejoined client still receives the public entity")
	expect_equal(packet.components[s.defs.Health], nil, "the rejoined client does not receive the gated component")
	local le = c2.net.get_client_entity(e)
	expect_equal(c2.world:has(le, c2.defs.Health), false, "the rejoined client's entity never gains Health")
end)

test("a recycled slot delivers a correct full packet to its new occupant", function(env)
	local s = env.server
	local e1 = s.world:entity()
	local e2 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(e2, s.net.Replicated)
	s.world:set(e1, s.defs.Health, 70)
	s.world:add(e1, s.defs.Burning)
	s.world:set(e1, pair(s.defs.Likes, e2), 3)
	env.frame() -- player B observes the full state

	-- B leaves, freeing its slot; a new player reuses that exact bit
	s.net.remove_client(env.player_b)
	local c2 = env.make_client()
	local player_c = fake_player("PlayerC")
	env.join(player_c, c2)

	local le1 = c2.net.get_client_entity(e1)
	local le2 = c2.net.get_client_entity(e2)
	expect(le1 ~= nil and le2 ~= nil, "recycled-slot joiner created both entities")
	expect_equal(c2.world:get(le1, c2.defs.Health), 70, "Health in the full packet")
	expect_equal(c2.world:has(le1, c2.defs.Burning), true, "tag in the full packet")
	expect_equal(c2.world:get(le1, pair(c2.defs.Likes, le2)), 3, "pair in the full packet")
end)

test("recycling a player slot clears the prior occupant's whitelist grant", function(env)
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 42)
	-- private to B only
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_b] = true })
	env.frame() -- B sees the private value

	-- B leaves, then a fresh player reuses B's freed bit. the slot's stale
	-- whitelist bit must be cleared so the newcomer does not inherit the grant.
	-- C reusing B's bit rather than some other slot is structurally guaranteed
	-- by lowest-first allocation -- only B's bit is free below the fresh tail.
	s.net.remove_client(env.player_b)
	local c2 = env.make_client()
	local player_c = fake_player("PlayerC")
	local packet_c = env.join(player_c, c2)

	expect_equal(packet_c.replicated[1], e, "C still receives the public entity creation")
	expect_equal(packet_c.components[s.defs.Health], nil, "C must not inherit B's private grant")
	local le = c2.net.get_client_entity(e)
	expect_equal(c2.world:has(le, c2.defs.Health), false, "C's client never gains the private value")

	-- the slot's last-sent words must be swept too, not just its allow words: with B's stale bit
	-- still marked, granting C would diff as no change and the value would never ship at all
	s.net.edit_component_privacy(e, s.defs.Health, player_c, true)
	local granted = env.sync(player_c, c2)
	local data_c = granted.components[s.defs.Health]
	expect(data_c ~= nil and data_c.values ~= nil and data_c.values[1] == 42, "the grant reaches the new occupant")
	expect_equal(c2.world:get(le, c2.defs.Health), 42, "C's client gains the value")
end)

test("a whitelist naming a departed client no longer admits them on rejoin", function(env)
	local s = env.server
	local c2 = env.make_client()
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 1)
	s.world:set(e, s.net.Private, { [env.player_a] = true, [env.player_b] = true })

	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, env.player_a))
	env.apply(env.packet_for(snapshot, env.player_b), c2)
	expect(env.client.net.get_client_entity(e) ~= nil, "A sees the gated entity before the departure")
	expect(c2.net.get_client_entity(e) ~= nil, "B sees the gated entity before departing")

	-- B departs with no edit to the whitelist in between, then rejoins under a
	-- fresh client world -- without the departure prune B would still be cached
	-- and admitted on their new full packet
	s.net.remove_client(env.player_b)
	local c3 = env.make_client()
	local packet_b = env.join(env.player_b, c3)
	expect_equal(#packet_b.replicated, 0, "the rejoined client does not receive the gated entity")
	expect_equal(next(packet_b.components), nil, "nor any of its data")
	expect_equal(c3.net.get_client_entity(e), nil, "the rejoined client never creates the gated entity")
	expect_equal(s.net.is_entity_visible(e, env.player_b), false, "and the server agrees they cannot see it")

	-- A's visibility is unaffected throughout
	s.world:set(e, s.defs.Health, 2)
	env.sync(env.player_a)
	local le_a = env.client.net.get_client_entity(e)
	expect_equal(env.client.world:get(le_a, env.client.defs.Health), 2, "A still receives updates to the gated entity")
end)

test("a per-component whitelist naming a departed client no longer admits them on rejoin", function(env)
	local s = env.server
	local c2 = env.make_client()
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 1)
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_a] = true, [env.player_b] = true })

	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, env.player_a))
	env.apply(env.packet_for(snapshot, env.player_b), c2)
	local le_a = env.client.net.get_client_entity(e)
	local le_b = c2.net.get_client_entity(e)
	expect_equal(env.client.world:get(le_a, env.client.defs.Health), 1, "A sees Health before the departure")
	expect_equal(c2.world:get(le_b, c2.defs.Health), 1, "B sees Health before departing")

	-- B departs with no edit to the whitelist in between, then rejoins under a
	-- fresh client world -- without the departure prune B would still be cached
	-- and admitted on their new full packet
	s.net.remove_client(env.player_b)
	local c3 = env.make_client()
	local packet_b = env.join(env.player_b, c3)
	expect_equal(packet_b.replicated[1], e, "the rejoined client still receives the public entity")
	expect_equal(packet_b.components[s.defs.Health], nil, "the rejoined client does not receive the gated component")
	local le_b2 = c3.net.get_client_entity(e)
	expect_equal(c3.world:has(le_b2, c3.defs.Health), false, "the rejoined client's entity never gains Health")

	-- A's visibility is unaffected throughout
	s.world:set(e, s.defs.Health, 2)
	env.sync(env.player_a)
	expect_equal(env.client.world:get(le_a, env.client.defs.Health), 2, "A still receives updates to Health")
end)

-- shared by the shard-boundary tests below: fills the server with `count`
-- additional filler players beyond the two standard ones (players never given
-- a client world; only their server-side slots matter for shard math),
-- draining one frame so they're all allocated. the env already holds 2 slots
-- (players A and B), so join_fillers(env, 30) fills shard 1 to its 32-client
-- capacity, opening the door for a 33rd player to land in shard 2.
local function join_fillers(env, count)
	for i = 1, count do
		env.server.net.add_client(fake_player(`Filler{i}`))
	end
	env.frame()
end

-- like join_fillers, but hands back the filler player objects so a test can
-- remove specific ones later -- duplecs keys clients by table identity, so a
-- later fake_player(name) call with the same name is a different table and
-- would not match. used by the shard compaction tests, which shrink a
-- population by removing named fillers rather than filling it.
local function join_named_fillers(env, count)
	local fillers = table.create(count)
	for i = 1, count do
		local filler = fake_player(`Filler{i}`)
		fillers[i] = filler
		env.server.net.add_client(filler)
	end
	env.frame()
	return fillers
end

test("the 33rd player opens shard 2 and receives a correct full packet", function(env)
	local s = env.server
	join_fillers(env, 30) -- shard 1 now holds its full 32 (A, B, and 30 fillers)

	local e1 = s.world:entity()
	local e2 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(e2, s.net.Replicated)
	s.world:set(e1, s.defs.Health, 10)
	s.world:add(e1, s.defs.Burning)
	s.world:set(e1, pair(s.defs.Likes, e2), 4)
	env.frame() -- the 32 existing players observe the initial state

	-- allocation never fails regardless of how many shards are already full:
	-- the 33rd player opens shard 2 and gets a normal full packet
	local c2 = env.make_client()
	local overflow = fake_player("Overflow")
	env.join(overflow, c2)

	-- pin the placement the rest of the test rests on: without it a change to the shard capacity or to the
	-- allocation order would quietly reduce this to a second single-shard test that still passes
	expect_equal(s.net._client_shard(env.player_a), 1, "the standard players stay in shard 1")
	expect_equal(s.net._client_shard(overflow), 2, "the 33rd player really did open shard 2")

	local le1 = c2.net.get_client_entity(e1)
	local le2 = c2.net.get_client_entity(e2)
	expect(le1 ~= nil and le2 ~= nil, "the shard-2 joiner's full packet created both entities")
	expect_equal(c2.world:get(le1, c2.defs.Health), 10, "Health in the full packet")
	expect_equal(c2.world:has(le1, c2.defs.Burning), true, "tag in the full packet")
	expect_equal(c2.world:get(le1, pair(c2.defs.Likes, le2)), 4, "pair in the full packet")

	-- a broadcast change now reaches shard 1 and shard 2 in the same pass
	s.world:set(e1, s.defs.Health, 20)
	local snapshot = env.frame()
	local data_a = env.packet_for(snapshot, env.player_a).components[s.defs.Health]
	local data_overflow = env.packet_for(snapshot, overflow).components[s.defs.Health]
	expect(data_a ~= nil and data_a.values[1] == 20, "shard 1 receives the change")
	expect(data_overflow ~= nil and data_overflow.values[1] == 20, "shard 2 receives the same change in one pass")
end)

test("a component whitelist naming one player per shard delivers to exactly those two", function(env)
	local s = env.server
	join_fillers(env, 30) -- shard 1 now holds its full 32 (A, B, and 30 fillers)

	local allowed = fake_player("ShardOneAllowed")
	local blocked = fake_player("ShardOneBlocked")
	s.net.add_client(allowed)
	s.net.add_client(blocked)
	env.frame() -- both land in shard 2, the first shard with room
	-- pin the placement, or a capacity change would quietly collapse this into a single-shard test
	expect_equal(s.net._client_shard(env.player_a), 1, "the whitelisted pair straddles two shards: A in shard 1")
	expect_equal(s.net._client_shard(allowed), 2, "and the other whitelisted player in shard 2")
	expect_equal(s.net._client_shard(blocked), 2, "with the unlisted shard-2 player beside them")

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 5)
	env.frame() -- every allocated player in both shards observes Health publicly

	-- narrow Health to one player per shard; everyone else currently seeing it
	-- loses it
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_a] = true, [allowed] = true })
	local snapshot = env.frame()

	-- the two "no change" assertions below only mean something against a cell the whitelisted players still
	-- hold: silently revoking them would produce exactly the same empty packets
	expect_equal(
		s.net.was_component_visible(e, s.defs.Health, env.player_a),
		true,
		"shard 1's whitelisted player still holds the cell"
	)
	expect_equal(
		s.net.was_component_visible(e, s.defs.Health, allowed),
		true,
		"shard 2's whitelisted player still holds the cell"
	)

	expect_equal(
		env.packet_for(snapshot, env.player_a).components[s.defs.Health],
		nil,
		"shard 1's whitelisted player sees no change (already visible)"
	)
	expect_equal(
		env.packet_for(snapshot, allowed).components[s.defs.Health],
		nil,
		"shard 2's whitelisted player sees no change (already visible)"
	)

	local data_b = env.packet_for(snapshot, env.player_b).components[s.defs.Health]
	expect(
		data_b ~= nil and data_b.removed ~= nil and data_b.removed[1] == e,
		"shard 1's unlisted player receives a removal"
	)
	local data_blocked = env.packet_for(snapshot, blocked).components[s.defs.Health]
	expect(
		data_blocked ~= nil and data_blocked.removed ~= nil and data_blocked.removed[1] == e,
		"shard 2's unlisted player receives a removal"
	)
end)

test("an entity-level whitelist behaves the same across shards", function(env)
	local s = env.server
	join_fillers(env, 30) -- shard 1 now holds its full 32 (A, B, and 30 fillers)

	local allowed = fake_player("ShardOneAllowed")
	local blocked = fake_player("ShardOneBlocked")
	s.net.add_client(allowed)
	s.net.add_client(blocked)
	env.frame() -- both land in shard 2, the first shard with room
	-- pin the placement, or a capacity change would quietly collapse this into a single-shard test
	expect_equal(s.net._client_shard(env.player_a), 1, "the whitelisted pair straddles two shards: A in shard 1")
	expect_equal(s.net._client_shard(allowed), 2, "and the other whitelisted player in shard 2")
	expect_equal(s.net._client_shard(blocked), 2, "with the unlisted shard-2 player beside them")

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 42)
	s.world:add(e, s.defs.Burning)
	-- set alongside creation, so the entity is private from its very first frame
	s.world:set(e, s.net.Private, { [env.player_a] = true, [allowed] = true })

	local snapshot = env.frame()
	local packet_a = env.packet_for(snapshot, env.player_a)
	local packet_b = env.packet_for(snapshot, env.player_b)
	local packet_allowed = env.packet_for(snapshot, allowed)
	local packet_blocked = env.packet_for(snapshot, blocked)

	expect_equal(packet_a.replicated[1], e, "shard 1's whitelisted player receives the entity creation")
	local data_a = packet_a.components[s.defs.Health]
	expect(data_a ~= nil and data_a.values ~= nil and data_a.values[1] == 42, "shard 1 receives the Health value")
	local tag_a = packet_a.components[s.defs.Burning]
	expect(tag_a ~= nil and tag_a.nulled ~= nil and tag_a.nulled[1] == e, "shard 1 receives the tag too")

	expect_equal(packet_allowed.replicated[1], e, "shard 2's whitelisted player receives the entity creation")
	local data_allowed = packet_allowed.components[s.defs.Health]
	expect(
		data_allowed ~= nil and data_allowed.values ~= nil and data_allowed.values[1] == 42,
		"shard 2 receives the Health value"
	)
	local tag_allowed = packet_allowed.components[s.defs.Burning]
	expect(
		tag_allowed ~= nil and tag_allowed.nulled ~= nil and tag_allowed.nulled[1] == e,
		"shard 2 receives the tag too"
	)

	expect_equal(#packet_b.replicated, 0, "shard 1's unlisted player never gets the entity")
	expect_equal(next(packet_b.components), nil, "shard 1's unlisted player receives no component data")
	expect_equal(#packet_blocked.replicated, 0, "shard 2's unlisted player never gets the entity")
	expect_equal(next(packet_blocked.components), nil, "shard 2's unlisted player receives no component data")
	-- the two packets above are the blank-packet fallback, which reads empty whether the entity was gated out
	-- or the frame simply produced nothing; the server-side gate is what makes them a real exclusion
	expect_equal(s.net.is_entity_visible(e, env.player_b), false, "shard 1's unlisted player is gated out")
	expect_equal(s.net.is_entity_visible(e, blocked), false, "shard 2's unlisted player is gated out")
end)

test(
	"a recycled slot in a high shard delivers a clean full packet without the prior occupant's whitelist grant",
	function(env)
		-- mirrors the two shard-1 recycling tests above, folded into one since they
		-- share the same setup: a correct full packet for public data, and no
		-- inherited grant for a whitelist scoped to the departed occupant.
		local s = env.server
		join_fillers(env, 30) -- shard 1 now holds its full 32 (A, B, and 30 fillers)

		-- two shard-2 occupants, so removing one leaves the shard open -- exercising
		-- slot reuse rather than the shard's wholesale empty-and-reopen path
		local z1 = fake_player("Z1")
		local z2 = fake_player("Z2")
		s.net.add_client(z1)
		s.net.add_client(z2)
		env.frame() -- both land in shard 2, the first shard with room
		expect_equal(s.net._client_shard(z1), 2, "Z1 landed in shard 2")
		expect_equal(s.net._client_shard(z2), 2, "Z2 landed in shard 2 beside it")

		local e1 = s.world:entity()
		local e2 = s.world:entity()
		s.world:add(e1, s.net.Replicated)
		s.world:add(e2, s.net.Replicated)
		s.world:set(e1, s.defs.Health, 70)
		s.world:add(e1, s.defs.Burning)
		s.world:set(e1, pair(s.defs.Likes, e2), 3)
		-- Health is further gated to Z2 only, so Z2's shard-2 bit is the one whose
		-- whitelist word is under test
		s.world:set(e1, pair(s.net.Private, s.defs.Health), { [z2] = true })
		env.frame() -- Z1 and Z2 observe the current state (Z1 without Health)
		-- the grant has to exist before "must not inherit it" says anything
		expect_equal(
			s.net.was_component_visible(e1, s.defs.Health, z2),
			true,
			"the departing occupant really did hold the private grant"
		)
		expect_equal(s.net.was_component_visible(e1, s.defs.Health, z1), false, "and its shard-mate never did")

		-- Z2 leaves, freeing its shard-2 bit; a fresh player reuses that exact slot
		s.net.remove_client(z2)
		local c2 = env.make_client()
		local newcomer = fake_player("Newcomer")
		env.join(newcomer, c2)
		-- Z1 keeps shard 2 open, so this really is bit reuse inside a live shard rather than a reopen
		expect_equal(s.net._client_shard(z1), 2, "Z1 kept shard 2 open across the departure")
		expect_equal(s.net._client_shard(newcomer), 2, "the newcomer allocated back into the live shard 2")

		local le1 = c2.net.get_client_entity(e1)
		local le2 = c2.net.get_client_entity(e2)
		expect(le1 ~= nil and le2 ~= nil, "recycled shard-2 joiner created both entities")
		expect_equal(c2.world:has(le1, c2.defs.Health), false, "newcomer must not inherit Z2's private grant")
		expect_equal(c2.world:has(le1, c2.defs.Burning), true, "tag in the full packet")
		expect_equal(c2.world:get(le1, pair(c2.defs.Likes, le2)), 3, "pair in the full packet")
	end
)

test("a shard that empties reopens cleanly for its next occupant", function(env)
	local s = env.server
	join_fillers(env, 30) -- shard 1 now holds its full 32 (A, B, and 30 fillers)

	local c2 = env.make_client()
	local overflow = fake_player("Overflow")
	env.join(overflow, c2) -- opens shard 2 as its sole occupant
	expect_equal(s.net._client_shard(overflow), 2, "the 33rd player opened shard 2")

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 1)
	env.frame() -- shard 1 and shard 2 both observe Health = 1

	-- Overflow leaves as shard 2's only occupant, so its mask trees are dropped
	-- wholesale rather than merely freeing a bit
	s.net.remove_client(overflow)
	expect_equal(s.net._client_shard(overflow), nil, "the departing sole occupant gives the shard up entirely")

	s.world:set(e, s.defs.Health, 2)
	local closed = env.frame() -- a frame with shard 2 closed
	-- dropping a shard's trees must leave the shards below it untouched
	local data_closed = env.packet_for(closed, env.player_a).components[s.defs.Health]
	expect(data_closed ~= nil and data_closed.values[1] == 2, "shard 1 keeps receiving deltas while 2 is closed")
	s.world:set(e, s.defs.Health, 3)
	env.frame() -- a second frame with shard 2 still closed

	-- a fresh player reopens shard 2 at the same bit Overflow vacated
	local c3 = env.make_client()
	local newcomer = fake_player("Newcomer")
	local packet = env.join(newcomer, c3)
	expect_equal(s.net._client_shard(newcomer), 2, "the joiner reopened shard 2 rather than finding room below")

	expect_equal(packet.replicated[1], e, "the reopened shard's joiner still gets the entity")
	local data = packet.components[s.defs.Health]
	expect(data ~= nil and data.values ~= nil and data.values[1] == 3, "the full packet carries the latest value")

	-- subsequent deltas keep working for the reopened shard
	s.world:set(e, s.defs.Health, 4)
	local snapshot = env.frame()
	local data2 = env.packet_for(snapshot, newcomer).components[s.defs.Health]
	expect(data2 ~= nil and data2.values ~= nil and data2.values[1] == 4, "deltas continue to reach the reopened shard")
end)

test("a broadcast shares one section across every shard", function(env)
	local s = env.server
	join_fillers(env, 30) -- shard 1 now holds its full 32 (A, B, and 30 fillers)

	local c2 = env.make_client()
	local cross = fake_player("Cross")
	env.join(cross, c2) -- opens shard 2
	-- the whole claim is that Cross sits in a *different* shard; unpinned, the identity assertions below would
	-- hold just as well if it had landed beside A
	expect_equal(s.net._client_shard(env.player_a), 1, "A sits in shard 1")
	expect_equal(s.net._client_shard(cross), 2, "Cross sits in shard 2")

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 17)

	-- raw packets (no deep copy) so reference identity is observable: a
	-- broadcast cell's send mask spans every occupied shard, so it accumulates
	-- into one section key (see append_mask_key in duplecs). the section is
	-- stamped into each client's own packet buffer, but its hookless values
	-- array reaches every client -- regardless of shard -- by reference.
	local packets = s.net.generate_packets()
	local values_a = packets[env.player_a].values and packets[env.player_a].values[1]
	-- anchored, so the two identity assertions below cannot pass as nil == nil
	expect(values_a ~= nil, "shard 1's players receive a hookless values array")
	expect_equal(values_a[1], 17, "the shared array carries the value")
	local values_b = packets[env.player_b].values[1]
	local values_cross = packets[cross].values[1]

	expect_equal(values_b, values_a, "same-shard players share one section's values table")
	expect_equal(values_cross, values_a, "a different shard shares the very same values table")
	expect_equal(
		decode_packet(packets[cross]).sections[1].values[1],
		decode_packet(packets[env.player_a]).sections[1].values[1],
		"content matches across shards"
	)

	-- reconciling each into its own client world proves the effect is identical
	env.client.net.reconcile_packet(deep_copy(packets[env.player_a]))
	c2.net.reconcile_packet(deep_copy(packets[cross]))
	local le = env.client.net.get_client_entity(e)
	local le_cross = c2.net.get_client_entity(e)
	expect_equal(env.client.world:get(le, env.client.defs.Health), 17, "shard 1 client reconciles the value")
	expect_equal(c2.world:get(le_cross, c2.defs.Health), 17, "shard 2 client reconciles the same value")
end)

test("a component whitelist naming one player per shard shares one section across shards", function(env)
	local s = env.server
	join_fillers(env, 30) -- shard 1 now holds its full 32 (A, B, and 30 fillers)

	local cross = fake_player("Cross")
	s.net.add_client(cross)
	env.frame() -- opens shard 2 with cross as its sole occupant
	expect_equal(s.net._client_shard(cross), 2, "Cross really is a shard apart from the other whitelisted player")

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 5)
	-- narrow Health to one player per shard before anyone has ever seen it, so
	-- the send lands as a fresh delivery in both whitelisted players' packets
	-- rather than a no-op against an already-visible cell
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_a] = true, [cross] = true })

	local packets = s.net.generate_packets()
	local values_a = packets[env.player_a].values and packets[env.player_a].values[1]
	expect(values_a ~= nil, "shard 1's whitelisted player receives a section")
	expect_equal(packets[cross].values[1], values_a, "shard 2's whitelisted player shares the exact same values table")
	expect_equal(values_a[1], 5, "the shared section carries the value")

	local decoded_b = decode_packet(packets[env.player_b])
	expect_equal(#decoded_b.sections, 0, "shard 1's unlisted player receives no component data")
	-- and that empty section list is a real packet, not an absence: only the component is gated here, so the
	-- entity itself still arrives
	expect_equal(decoded_b.replicated[1], e, "shard 1's unlisted player still receives the entity creation")
end)

test("mixed masks don't leak across a broadcast and a cross-shard whitelist in one frame", function(env)
	local s = env.server
	join_fillers(env, 30) -- shard 1 now holds its full 32 (A, B, and 30 fillers)

	local cross = fake_player("Cross")
	s.net.add_client(cross)
	env.frame() -- opens shard 2 with cross as its sole occupant
	expect_equal(s.net._client_shard(cross), 2, "the whitelisted pair really does straddle two shards")

	local e1 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:set(e1, s.defs.Health, 1)
	env.frame() -- everyone observes the initial broadcast value

	local e2 = s.world:entity()
	s.world:add(e2, s.net.Replicated)
	s.world:set(e2, s.defs.Inventory, { gold = 1 })
	s.world:set(e2, pair(s.net.Private, s.defs.Inventory), { [env.player_a] = true, [cross] = true })

	-- change the broadcast value and stand up the whitelisted one in the same frame
	s.world:set(e1, s.defs.Health, 2)

	local packets = s.net.generate_packets()
	local packet_a = decode_packet(packets[env.player_a])
	local packet_b = decode_packet(packets[env.player_b])
	local packet_cross = decode_packet(packets[cross])

	expect_equal(#packet_a.sections, 2, "the whitelisted player receives both the broadcast and the private section")
	expect_equal(#packet_cross.sections, 2, "the other-shard whitelisted player also receives both sections")
	expect_equal(#packet_b.sections, 1, "an unlisted player only receives the broadcast section")
	-- e2 is public at the entity level, so the unlisted player's packet is a real one carrying its creation --
	-- only the component inside it is gated
	expect_equal(packet_b.replicated[1], e2, "the unlisted player still receives the private component's entity")

	local function find_section(packet, component)
		for _, section in packet.sections do
			if section.component == component then
				return section
			end
		end
		return nil
	end

	local health_a = find_section(packet_a, s.defs.Health)
	local health_b = find_section(packet_b, s.defs.Health)
	local health_cross = find_section(packet_cross, s.defs.Health)
	expect(health_a ~= nil and health_b ~= nil and health_cross ~= nil, "every player has a Health section")
	expect_equal(health_a.values[1], 2, "the broadcast section carries the changed value")
	expect_equal(
		health_b.values,
		health_a.values,
		"the broadcast section's values are shared by reference between a whitelisted and an unlisted player"
	)
	expect_equal(health_cross.values, health_a.values, "the broadcast section's values are shared across shards too")

	local inventory_a = find_section(packet_a, s.defs.Inventory)
	local inventory_cross = find_section(packet_cross, s.defs.Inventory)
	expect(inventory_a ~= nil, "the whitelisted player receives the Inventory section")
	expect(inventory_cross ~= nil, "the other-shard whitelisted player receives it too")
	expect_equal(inventory_a.values[1].gold, 1, "the private section carries its own value, not the broadcast's")
	expect_equal(
		inventory_cross.values,
		inventory_a.values,
		"the whitelisted Inventory section's values are shared across shards"
	)
	expect_equal(
		find_section(packet_b, s.defs.Inventory),
		nil,
		"the unlisted player never receives the Inventory section"
	)
end)

test("removing a cross-shard-whitelisted component shares one removed section across shards", function(env)
	local s = env.server
	join_fillers(env, 30) -- shard 1 now holds its full 32 (A, B, and 30 fillers)

	local c2 = env.make_client()
	local cross = fake_player("Cross")
	env.join(cross, c2) -- opens shard 2
	expect_equal(s.net._client_shard(cross), 2, "the two whitelisted players really are a shard apart")

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 9)
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_a] = true, [cross] = true })

	-- both whitelisted players observe the initial value; reconcile into their
	-- client worlds so the entity exists locally before the removal below
	local first_frame = env.frame()
	env.client.net.reconcile_packet(first_frame[env.player_a])
	c2.net.reconcile_packet(first_frame[cross])
	local le = env.client.net.get_client_entity(e)
	local le_cross = c2.net.get_client_entity(e)
	-- anchor the starting state: the absence checks at the end would pass just as well against a client that
	-- never received the value in the first place
	expect_equal(env.client.world:get(le, env.client.defs.Health), 9, "shard 1's player holds the value first")
	expect_equal(c2.world:get(le_cross, c2.defs.Health), 9, "shard 2's player holds the value first")

	-- removing the component (rather than the whitelist) drops it for exactly
	-- its prior viewers -- the two shards' whitelisted players -- while the
	-- rest of the population, who never saw it, observes no change at all
	s.world:remove(e, s.defs.Health)

	local packets = s.net.generate_packets()
	local decoded_a = decode_packet(packets[env.player_a])
	local removed_a = decoded_a.sections[1].removed
	expect(removed_a ~= nil and removed_a[1] == e, "shard 1's whitelisted player receives the removal")
	expect_equal(#decoded_a.sections, 1, "shard 1's packet carries exactly one section")
	local decoded_cross = decode_packet(packets[cross])
	local removed_cross = decoded_cross.sections[1].removed
	expect(removed_cross ~= nil and removed_cross[1] == e, "shard 2's whitelisted player receives the removal")
	expect_equal(#decoded_cross.sections, 1, "shard 2's packet carries exactly one section")
	expect_equal(packets[env.player_b], nil, "an unlisted player never had the component, so receives no packet")

	-- a removal-only section carries no values side array, so sharing the
	-- built section by reference across shards is otherwise unobservable;
	-- byte-equality of the two packets is the proxy for it
	expect_equal(
		buffer.tostring(packets[cross].data),
		buffer.tostring(packets[env.player_a].data),
		"both players receive the same removed section, stamped identically"
	)

	env.client.net.reconcile_packet(deep_copy(packets[env.player_a]))
	c2.net.reconcile_packet(deep_copy(packets[cross]))
	expect_equal(env.client.world:has(le, env.client.defs.Health), false, "shard 1 client reconciles the removal")
	expect_equal(c2.world:has(le_cross, c2.defs.Health), false, "shard 2 client reconciles the removal")
end)

test("a same-frame value change and a cross-shard revocation split correctly", function(env)
	local s = env.server
	local fillers = join_named_fillers(env, 30) -- shard 1 fills to 32 (A, B, and 30 fillers)

	local cross = fake_player("Cross")
	local cross_ally = fake_player("CrossAlly")
	s.net.add_client(cross)
	s.net.add_client(cross_ally)
	env.frame() -- shard 2 opens with cross and cross_ally
	-- both the revoked pair and the surviving pair have to straddle the boundary for the split to mean anything
	expect_equal(s.net._client_shard(fillers[1]), 1, "the filler about to be revoked sits in shard 1")
	expect_equal(s.net._client_shard(cross), 2, "the other revoked player sits in shard 2")
	expect_equal(s.net._client_shard(cross_ally), 2, "and the surviving shard-2 player beside them")

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 5)
	env.frame() -- everyone observes the initial broadcast value

	-- narrow to everyone except one filler (shard 1) and Cross (shard 2), while
	-- changing the value in the same frame -- exercises the deferred-send path:
	-- a cell whose value and visibility both change in one frame emits only its
	-- removals during the visibility resolve, deferring its send to the value
	-- resolve so every remaining viewer gets the new value exactly once.
	local revoked_filler = fillers[1]
	local allowed = {}
	for i = 2, 30 do
		allowed[fillers[i]] = true
	end
	allowed[env.player_a] = true
	allowed[env.player_b] = true
	allowed[cross_ally] = true
	s.world:set(e, s.defs.Health, 6)
	s.world:set(e, pair(s.net.Private, s.defs.Health), allowed)

	local packets = s.net.generate_packets()

	local decoded_filler = decode_packet(packets[revoked_filler])
	local removed_filler = decoded_filler.sections[1].removed
	expect(removed_filler ~= nil and removed_filler[1] == e, "the revoked shard-1 player receives a removal")
	local removed_cross = decode_packet(packets[cross]).sections[1].removed
	expect(removed_cross ~= nil and removed_cross[1] == e, "the revoked shard-2 player receives a removal")
	-- a removal-only section carries no values array, so the shared build is
	-- only observable as identically-stamped packet bytes
	expect_equal(
		buffer.tostring(packets[cross].data),
		buffer.tostring(packets[revoked_filler].data),
		"both revoked players share the same removed section, stamped identically"
	)

	local decoded_a = decode_packet(packets[env.player_a])
	expect_equal(#decoded_filler.sections, 1, "the revoked player receives only the removal, not the value")
	expect_equal(#decoded_a.sections, 1, "an unrevoked player receives the value exactly once")

	-- "exactly once" is a claim about the section's contents too: a deferred send that also emitted during the
	-- visibility resolve would list the cell twice inside this one section
	local section_a = decoded_a.sections[1]
	expect_equal(#section_a.ids, 1, "the value section names the cell exactly once")
	expect_equal(section_a.ids[1], e, "and it is the cell whose value changed")
	expect_equal(section_a.removed, nil, "an unrevoked player receives no removal alongside the value")
	local value_a = section_a.values[1]
	expect_equal(value_a, 6, "shard 1's remaining players receive the new value")
	local value_cross_ally = decode_packet(packets[cross_ally]).sections[1].values[1]
	expect_equal(value_cross_ally, 6, "shard 2's remaining player receives the new value")
	expect_equal(
		packets[cross_ally].values[1],
		packets[env.player_a].values[1],
		"both remaining players share the same value section's values table"
	)
end)

test("whitelisting a still-pending player who allocates into shard 2 is honored in their first packet", function(env)
	-- mirrors "whitelisting a still-pending player is honored once they're
	-- allocated" above, but with shard 1 already full so the pending player's
	-- grant must survive allocation into a freshly-opened shard 2.
	local s = env.server
	join_fillers(env, 30) -- shard 1 now holds its full 32 (A, B, and 30 fillers)

	local pending = fake_player("PendingHigh")
	s.net.add_client(pending)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 77)
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [pending] = true })

	local packets = env.frame() -- allocates pending into shard 2 and builds its full packet
	expect_equal(s.net._client_shard(pending), 2, "the pending player really did allocate into a fresh shard 2")
	local data = packets[pending].components[s.defs.Health]
	expect(
		data ~= nil and data.values ~= nil and data.values[1] == 77,
		"the shard-2 joiner receives the whitelisted value in their first packet"
	)
	-- the shard-1 negative below would ride the blank-packet fallback unless that packet is real, and it is:
	-- the entity is public, only the component is gated
	expect_equal(packets[env.player_a].replicated[1], e, "a shard-1 player still receives the entity itself")
	expect_equal(
		packets[env.player_a].components[s.defs.Health],
		nil,
		"a shard-1 player outside the whitelist still does not receive it"
	)
end)

test("a value visible to three players scatters to each one", function(env)
	local s = env.server
	local c3 = env.make_client()
	local player_c = fake_player("PlayerC")
	env.join(player_c, c3) -- C is allocated a third slot; its (empty) full packet drains here

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 99)

	-- all three players already hold slots, so the value reaches each through the
	-- per-bit scatter rather than a full packet
	local snapshot = env.frame()
	for _, player in { env.player_a, env.player_b, player_c } do
		local data = env.packet_for(snapshot, player).components[s.defs.Health]
		expect(
			data ~= nil and data.values ~= nil and data.values[1] == 99,
			"all three players should receive the scattered value"
		)
	end
end)

test("is_component_visible reflects replication, networking, and whitelists", function(env)
	local s = env.server
	local e = s.world:entity()
	s.world:set(e, s.defs.Health, 1)

	expect_equal(s.net.is_component_visible(e, s.defs.Health, env.player_a), false, "hidden before replication")

	s.world:add(e, s.net.Replicated)
	expect_equal(s.net.is_component_visible(e, s.defs.Health, env.player_a), true, "visible once replicated")
	expect_equal(
		s.net.is_component_visible(e, s.defs.Health, env.player_b),
		true,
		"visible to everyone without a whitelist"
	)

	s.world:set(e, s.defs.LocalOnly, 9)
	expect_equal(
		s.net.is_component_visible(e, s.defs.LocalOnly, env.player_a),
		false,
		"non-networked component is never visible"
	)
	-- the contrast that makes the miss above about networking rather than about a cell nothing ever staged: a
	-- second component added the same way on the same entity, differing only in carrying Networked
	s.world:add(e, s.defs.Burning)
	expect_equal(
		s.net.is_component_visible(e, s.defs.Burning, env.player_a),
		true,
		"a networked component on the same entity is visible"
	)

	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_a] = true })
	expect_equal(s.net.is_component_visible(e, s.defs.Health, env.player_a), true, "A still allowed by the whitelist")
	expect_equal(s.net.is_component_visible(e, s.defs.Health, env.player_b), false, "B filtered by the whitelist")
	expect_equal(
		s.net.is_component_visible(e, s.defs.Burning, env.player_b),
		true,
		"the per-component filter gates only its own key"
	)

	local stranger = fake_player("Stranger")
	expect_equal(s.net.is_component_visible(e, s.defs.Health, stranger), false, "unregistered player sees nothing")

	-- and the other end of "reflects replication": unreplicating takes the whitelisted client's cell away too
	s.world:remove(e, s.net.Replicated)
	expect_equal(s.net.is_component_visible(e, s.defs.Health, env.player_a), false, "hidden again once unreplicated")
end)

test("was_entity_visible and was_component_visible report false for untracked and pending clients", function(env)
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 1)
	env.frame() -- flush, so the falses below are about tracking rather than about nothing having been sent yet

	-- the control: without it every assertion in this test would hold for an allocated client too, since a
	-- last-sent mask nobody has been sent against reads empty for everyone
	expect_equal(s.net.was_entity_visible(e, env.player_a), true, "an allocated client does hold the entity")
	expect_equal(
		s.net.was_component_visible(e, s.defs.Health, env.player_a),
		true,
		"an allocated client does hold the component"
	)

	local stranger = fake_player("Stranger") -- never passed to add_client
	expect_equal(s.net.was_entity_visible(e, stranger), false, "untracked client has no last-sent existence")
	expect_equal(
		s.net.was_component_visible(e, s.defs.Health, stranger),
		false,
		"untracked client has no last-sent component"
	)

	local pending = fake_player("Pending")
	s.net.add_client(pending) -- registered but not yet allocated a slot
	expect_equal(s.net.is_client_tracked(pending), true, "the pending joiner is registered all the same")
	expect_equal(s.net.was_entity_visible(e, pending), false, "pending client has no last-sent existence")
	expect_equal(
		s.net.was_component_visible(e, s.defs.Health, pending),
		false,
		"pending client has no last-sent component"
	)
end)

test(
	"was_entity_visible and was_component_visible agree with the is_ variants once a packet has been sent",
	function(env)
		local s = env.server
		local e = s.world:entity()
		s.world:add(e, s.net.Replicated)
		s.world:set(e, s.defs.Health, 1)
		env.frame() -- flushes the staged creation into player_a's last-sent mask

		expect_equal(s.net.is_entity_visible(e, env.player_a), true, "is_entity_visible true once replicated")
		expect_equal(s.net.was_entity_visible(e, env.player_a), true, "was_entity_visible agrees after a flush")
		expect_equal(
			s.net.is_component_visible(e, s.defs.Health, env.player_a),
			true,
			"is_component_visible true once replicated"
		)
		expect_equal(
			s.net.was_component_visible(e, s.defs.Health, env.player_a),
			true,
			"was_component_visible agrees after a flush"
		)

		-- the other direction, so "agree" is more than "both answer true": unreplicating and flushing again
		-- clears the entity and its cells from the last-sent mask alongside the current one
		s.world:remove(e, s.net.Replicated)
		env.frame()
		expect_equal(s.net.is_entity_visible(e, env.player_a), false, "is_entity_visible false once unreplicated")
		expect_equal(s.net.was_entity_visible(e, env.player_a), false, "was_entity_visible agrees after that flush")
		expect_equal(
			s.net.is_component_visible(e, s.defs.Health, env.player_a),
			false,
			"is_component_visible false once unreplicated"
		)
		expect_equal(
			s.net.was_component_visible(e, s.defs.Health, env.player_a),
			false,
			"was_component_visible agrees after that flush"
		)
	end
)

test("is_component_visible reflects a staged privacy edit ahead of was_component_visible", function(env)
	-- the distinguishing behavior between the two: is_component_visible reads the
	-- cell staged this frame (or the last-sent mask if untouched), while
	-- was_component_visible reads only the last-sent mask, so a privacy edit
	-- staged without a generate_packets call diverges the two until the next flush.
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 1)
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_b] = true }) -- A excluded
	env.frame() -- flush the initial hidden state into A's last-sent mask

	-- B is the control throughout: without a client the cell is genuinely live for, every false below would
	-- also hold for a cell nothing ever staged
	expect_equal(s.net.was_component_visible(e, s.defs.Health, env.player_b), true, "B holds the cell all along")

	expect_equal(s.net.is_component_visible(e, s.defs.Health, env.player_a), false, "hidden by the whitelist")
	expect_equal(
		s.net.was_component_visible(e, s.defs.Health, env.player_a),
		false,
		"matches the last-sent hidden packet"
	)

	s.net.edit_component_privacy(e, s.defs.Health, env.player_a, true) -- stage a reveal, no flush yet
	expect_equal(s.net.is_component_visible(e, s.defs.Health, env.player_a), true, "is_ reflects the staged reveal")
	expect_equal(
		s.net.was_component_visible(e, s.defs.Health, env.player_a),
		false,
		"was_ still reflects the prior hidden packet"
	)
	expect_equal(s.net.is_component_visible(e, s.defs.Health, env.player_b), true, "B's standing is untouched")

	env.frame() -- flush the reveal
	expect_equal(
		s.net.was_component_visible(e, s.defs.Health, env.player_a),
		true,
		"was_ catches up once the reveal is sent"
	)

	s.net.edit_component_privacy(e, s.defs.Health, env.player_a, false) -- stage a hide, no flush yet
	expect_equal(s.net.is_component_visible(e, s.defs.Health, env.player_a), false, "is_ reflects the staged hide")
	expect_equal(
		s.net.was_component_visible(e, s.defs.Health, env.player_a),
		true,
		"was_ still reflects the prior visible packet"
	)
	expect_equal(s.net.is_component_visible(e, s.defs.Health, env.player_b), true, "and B is still untouched")
end)

test(
	"is_entity_visible reflects a staged privacy edit ahead of was_entity_visible, gating was_component_visible too",
	function(env)
		-- entity-level counterpart of the above, plus the subset invariant: a false
		-- was_entity_visible implies was_component_visible is false for every
		-- component, exactly like is_entity_visible gates is_component_visible.
		local s = env.server
		local e = s.world:entity()
		s.world:add(e, s.net.Replicated)
		s.world:set(e, s.defs.Health, 1)
		s.world:set(e, s.net.Private, { [env.player_b] = true }) -- A excluded from the whole entity
		env.frame() -- flush the initial hidden state into A's last-sent mask

		-- B is the control: without a client the entity is genuinely live for, A's falses would hold just as
		-- well for an entity nothing ever staged
		expect_equal(s.net.was_entity_visible(e, env.player_b), true, "B holds the entity all along")

		expect_equal(s.net.is_entity_visible(e, env.player_a), false, "A gated out of the whole entity")
		expect_equal(s.net.was_entity_visible(e, env.player_a), false, "matches the last-sent hidden packet")
		expect_equal(
			s.net.was_component_visible(e, s.defs.Health, env.player_a),
			false,
			"component gated by the entity-level miss too"
		)

		s.net.edit_entity_privacy(e, env.player_a, true) -- stage a reveal, no flush yet
		expect_equal(s.net.is_entity_visible(e, env.player_a), true, "is_ reflects the staged reveal")
		expect_equal(s.net.was_entity_visible(e, env.player_a), false, "was_ still reflects the prior hidden packet")
		expect_equal(
			s.net.was_component_visible(e, s.defs.Health, env.player_a),
			false,
			"component still gated by the stale existence entry"
		)

		env.frame() -- flush the reveal
		expect_equal(s.net.was_entity_visible(e, env.player_a), true, "was_ catches up once the reveal is sent")
		expect_equal(
			s.net.was_component_visible(e, s.defs.Health, env.player_a),
			true,
			"component catches up alongside existence"
		)

		s.net.edit_entity_privacy(e, env.player_a, false) -- stage a hide, no flush yet
		expect_equal(s.net.is_entity_visible(e, env.player_a), false, "is_ reflects the staged hide")
		expect_equal(s.net.was_entity_visible(e, env.player_a), true, "was_ still reflects the prior visible packet")
		expect_equal(
			s.net.is_component_visible(e, s.defs.Health, env.player_a),
			false,
			"and the current-mask component follows the staged hide, the is_ side of the same gating"
		)
		expect_equal(s.net.was_entity_visible(e, env.player_b), true, "B is untouched by A's edits throughout")
	end
)

test("is_client_tracked covers the whole add_client/remove_client lifecycle, pending joiners included", function(env)
	local s = env.server
	local joiner = fake_player("Joiner")
	expect_equal(s.net.is_client_tracked(joiner), false, "a never-added client is untracked")

	s.net.add_client(joiner)
	-- the pending window is the one place tracking and visibility disagree: the client is registered (privacy
	-- filters may already name them) but has no slot, so the point queries and the client walks skip them
	expect_equal(s.net.is_client_tracked(joiner), true, "tracked immediately, while still pending")
	expect_equal(s.net._client_shard(joiner), nil, "and slotless until the join resolves")

	env.frame() -- allocates the joiner's slot at the tail of the pass
	expect_equal(s.net.is_client_tracked(joiner), true, "still tracked once allocated")
	expect(s.net._client_shard(joiner) ~= nil, "the joiner really did get a slot")

	s.net.remove_client(joiner)
	expect_equal(s.net.is_client_tracked(joiner), false, "untracked once an allocated slot is freed")
	expect_equal(s.net._client_shard(joiner), nil, "and the slot went with them")

	s.net.add_client(joiner) -- rejoin under the same identity, pending again
	expect_equal(s.net.is_client_tracked(joiner), true, "tracked again after a rejoin")

	s.net.remove_client(joiner) -- cancel the pending join before it ever allocates
	expect_equal(s.net.is_client_tracked(joiner), false, "untracked once a still-pending join is cancelled")

	s.net.add_client(joiner) -- a rejoin after a cancellation reads like one after a departure
	expect_equal(s.net.is_client_tracked(joiner), true, "tracked again after a cancelled join too")

	expect_equal(s.net.is_client_tracked(env.player_a), true, "the standard players are unaffected throughout")
	expect_equal(s.net.is_client_tracked(env.player_b), true, "the standard players are unaffected throughout")
end)

-- shared by the client-enumerator tests below: drains one of the two client iterators into a set and asserts it
-- holds exactly `expected`. enumeration order is slot order, an internal detail callers must not lean on, so
-- every assertion here is set equality; a client enumerating twice fails too, since a slot owns one bit of one
-- shard word.
local function expect_client_set(iterator, expected, label)
	local seen = {}
	local count = 0
	for client in iterator do
		expect(seen[client] == nil, `{label}: {client.Name} enumerated more than once`)
		seen[client] = true
		count += 1
	end
	for _, client in expected do
		expect(seen[client] == true, `{label}: {client.Name} did not enumerate`)
	end
	expect_equal(count, #expected, `{label}: enumerated client count`)
end

test("get_clients_seeing enumerates exactly the clients a replicated entity is visible to", function(env)
	local s = env.server
	-- a third slot, so the expected set is wider than the standard pair. like the shard fillers this player never
	-- gets a client world; only their server-side slot matters here.
	local player_c = fake_player("PlayerC")
	s.net.add_client(player_c)
	env.frame()

	local unreplicated = s.world:entity()
	s.world:set(unreplicated, s.defs.Health, 1) -- never given Replicated, so it is visible to nobody
	expect_client_set(s.net.get_clients_seeing(unreplicated), {}, "an unreplicated entity yields nothing")

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 1)
	expect_client_set(
		s.net.get_clients_seeing(e),
		{ env.player_a, env.player_b, player_c },
		"a public entity enumerates every tracked client"
	)

	-- and the walk reads the current words rather than accumulating: unreplicating empties it again
	s.world:remove(e, s.net.Replicated)
	expect_client_set(s.net.get_clients_seeing(e), {}, "an entity that stops replicating stops enumerating")
end)

test("get_clients_seeing respects the entity-level privacy filter", function(env)
	local s = env.server
	local whitelisted = s.world:entity()
	s.world:add(whitelisted, s.net.Replicated)
	s.world:set(whitelisted, s.defs.Health, 1)
	s.world:set(whitelisted, s.net.Private, { [env.player_b] = true }) -- entity-level whitelist naming B alone
	expect_client_set(s.net.get_clients_seeing(whitelisted), { env.player_b }, "only the whitelisted client")

	-- an empty Private caches as an empty existence mask, so nobody is admitted at all
	local blocked = s.world:entity()
	s.world:add(blocked, s.net.Replicated)
	s.world:set(blocked, s.defs.Health, 1)
	s.world:set(blocked, s.net.Private, {})
	expect_client_set(s.net.get_clients_seeing(blocked), {}, "an empty Private admits nobody")
end)

test("a pending joiner never enumerates, even when they will be admitted once allocated", function(env)
	local s = env.server
	local pending = fake_player("Pending")
	s.net.add_client(pending) -- registered, but slotless until the next generate_packets

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 1)
	s.world:set(e, s.net.Private, { [env.player_a] = true, [pending] = true }) -- the pending grant is kept, not pruned

	expect_equal(s.net.is_client_tracked(pending), true, "the joiner is tracked while pending")
	expect_client_set(s.net.get_clients_seeing(e), { env.player_a }, "the pending joiner has no bit to enumerate")
	expect_client_set(s.net.get_clients_last_seeing(e), {}, "nothing has been sent to anyone yet")

	local snapshot = env.frame() -- allocates the joiner, grants their whitelist bit, and builds their full packet
	expect_client_set(
		s.net.get_clients_seeing(e),
		{ env.player_a, pending },
		"the joiner enumerates once their slot exists"
	)
	expect_client_set(
		s.net.get_clients_last_seeing(e),
		{ env.player_a, pending },
		"the full packet the joiner received counts as sent"
	)

	-- anchor the last-sent walk against the wire: "counts as sent" only means something if the joiner's full
	-- packet actually carried the creation and its value, rather than a bit being written into a mask
	local packet_pending = env.packet_for(snapshot, pending)
	expect(table.find(packet_pending.replicated, e) ~= nil, "the joiner's full packet creates the entity")
	local data_pending = packet_pending.components[s.defs.Health]
	expect(
		data_pending ~= nil and data_pending.values ~= nil and data_pending.values[1] == 1,
		"the joiner's full packet carries the Health value"
	)
end)

test("get_clients_seeing reflects a staged hide while get_clients_last_seeing holds the sent set", function(env)
	-- the enumeration counterpart of the is_/was_entity_visible split: get_clients_seeing reads the existence word
	-- staged this frame (falling back to the last-sent one per shard), get_clients_last_seeing only the last-sent
	-- word, so a hide staged without a generate_packets call diverges the two until the next flush.
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 1)
	env.frame() -- flush the creation into both standard players' last-sent masks

	local both = { env.player_a, env.player_b }
	expect_client_set(s.net.get_clients_seeing(e), both, "both clients see the flushed entity")
	expect_client_set(s.net.get_clients_last_seeing(e), both, "and both hold it")

	s.world:set(e, s.net.Private, {}) -- empty: gates the existence for everyone, staged only
	expect_client_set(s.net.get_clients_seeing(e), {}, "the staged hide empties the current set")
	expect_client_set(s.net.get_clients_last_seeing(e), both, "the clients still hold the entity")

	local snapshot = env.frame() -- flush the hide
	expect_client_set(s.net.get_clients_seeing(e), {}, "the two agree once the hide is sent")
	expect_client_set(s.net.get_clients_last_seeing(e), {}, "the sent set catches up")

	-- anchor the emptied sent set against the wire: the clients stop holding the entity because they were told to
	-- delete it, not because a mask was cleared behind their backs
	expect_equal(env.packet_for(snapshot, env.player_a).unreplicated[1], e, "A was told to delete the entity")
	expect_equal(env.packet_for(snapshot, env.player_b).unreplicated[1], e, "B was told to delete the entity")
end)

test("a staged creation enumerates in get_clients_seeing before it enumerates in get_clients_last_seeing", function(env)
	-- the reverse direction of the split above: the reveal is staged, so the current walk already yields the
	-- clients the entity is about to reach while the last-sent walk still yields nobody.
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 1)

	local both = { env.player_a, env.player_b }
	expect_client_set(s.net.get_clients_seeing(e), both, "the staged creation is already visible")
	expect_client_set(s.net.get_clients_last_seeing(e), {}, "but nobody holds it yet")

	local snapshot = env.frame() -- flush the creation
	expect_client_set(s.net.get_clients_seeing(e), both, "the two agree once the creation is sent")
	expect_client_set(s.net.get_clients_last_seeing(e), both, "both clients now hold it")

	-- anchor the sent set against the wire: both clients hold the entity because the creation reached them, not
	-- because their bit was written into the last-sent mask
	expect(table.find(env.packet_for(snapshot, env.player_a).replicated, e) ~= nil, "A received the creation")
	expect(table.find(env.packet_for(snapshot, env.player_b).replicated, e) ~= nil, "B received the creation")
end)

test("a client removed since the last flush never enumerates from their slot's stale bits", function(env)
	-- remove_client leaves the freed slot's bits standing in the persistent masks (the next joiner to reuse the
	-- bit clears them), so both walks band each shard's word with the allocated word rather than trusting the
	-- mask alone -- a departed client must stop enumerating immediately, without waiting for a generate_packets.
	local s = env.server
	-- a third slot, and a departure below a survivor: remove_client also drops the slot -> client entry, so a
	-- walk trusting the mask alone resolves the stale bit to nil and just stops -- which removing the highest
	-- slot could never tell apart from the bit being masked off, so the lowest slot is the one that departs.
	local player_c = fake_player("PlayerC")
	s.net.add_client(player_c)
	env.frame()

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 1)
	env.frame() -- all three players now hold the entity, bits set in both masks

	s.net.remove_client(env.player_a) -- the lowest allocated slot, and no generate_packets in between
	expect_client_set(
		s.net.get_clients_seeing(e),
		{ env.player_b, player_c },
		"the departed client's stale bit is masked off"
	)
	expect_client_set(
		s.net.get_clients_last_seeing(e),
		{ env.player_b, player_c },
		"the last-sent walk masks it off too"
	)
end)

test("both client enumerators walk every shard and honor a filter narrowing across them", function(env)
	local s = env.server
	local fillers = join_named_fillers(env, 30) -- shard 1 now holds its full 32 (A, B, and 30 fillers)

	local overflow = fake_player("Overflow")
	s.net.add_client(overflow)
	env.frame() -- the 33rd client opens shard 2
	expect_equal(s.net._client_shard(overflow), 2, "the overflow client landed in shard 2")

	local everyone = { env.player_a, env.player_b, overflow }
	for _, filler in fillers do
		table.insert(everyone, filler)
	end

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 1)
	env.frame()
	expect_client_set(s.net.get_clients_seeing(e), everyone, "all 33 clients enumerate across both shards")
	expect_client_set(s.net.get_clients_last_seeing(e), everyone, "the last-sent walk covers both shards too")

	-- one named client per shard: the shard-2 word must narrow alongside the shard-1 one rather than being
	-- skipped or taken wholesale
	s.world:set(e, s.net.Private, { [env.player_a] = true, [overflow] = true })
	expect_client_set(s.net.get_clients_seeing(e), { env.player_a, overflow }, "one whitelisted client per shard")
	expect_client_set(s.net.get_clients_last_seeing(e), everyone, "everyone still holds it until the flush")

	env.frame() -- flush the whitelist, revoking the entity from every unnamed client in both shards
	local pair_across_shards = { env.player_a, overflow }
	expect_client_set(s.net.get_clients_last_seeing(e), pair_across_shards, "the sent set narrows in both shards")

	s.net.edit_entity_privacy(e, overflow, false) -- drop the shard-2 client, staged only
	expect_client_set(s.net.get_clients_seeing(e), { env.player_a }, "the excluded shard-2 client stops enumerating")
	expect_client_set(
		s.net.get_clients_last_seeing(e),
		pair_across_shards,
		"the shard-2 client still holds it until the next flush"
	)

	env.frame() -- flush the exclusion
	expect_client_set(s.net.get_clients_last_seeing(e), { env.player_a }, "the sent set catches up in both shards")
end)

test(
	"the client enumerators agree with is_entity_visible and was_entity_visible over every tracked client",
	function(env)
		local s = env.server
		local player_c = fake_player("PlayerC")
		s.net.add_client(player_c)

		local e = s.world:entity()
		s.world:add(e, s.net.Replicated)
		s.world:set(e, s.defs.Health, 1)
		s.world:set(e, s.net.Private, { [env.player_a] = true, [player_c] = true }) -- B excluded outright
		env.frame() -- allocates C and flushes the whitelisted state

		-- a pending client (tracked, no slot) and a staged narrowing, so the mixed setup exercises every answer the
		-- two point queries can give: A visible in both, B in neither, C only in the last-sent one, pending nowhere
		local pending = fake_player("Pending")
		s.net.add_client(pending)
		s.net.edit_entity_privacy(e, player_c, false)

		local expected_seeing = {}
		local expected_last_seeing = {}
		for _, client in { env.player_a, env.player_b, player_c, pending } do
			if s.net.is_entity_visible(e, client) then
				table.insert(expected_seeing, client)
			end
			if s.net.was_entity_visible(e, client) then
				table.insert(expected_last_seeing, client)
			end
		end

		-- the comparison is only meaningful if the two point queries disagree here -- and only sound if they
		-- disagree about the clients the setup names, since two identically-wrong answers would still match
		expect_equal(#expected_seeing, 1, "only A passes the narrowed whitelist")
		expect(table.find(expected_seeing, env.player_a) ~= nil, "and the one still seeing it is A")
		expect_equal(#expected_last_seeing, 2, "A and C hold the entity from the flushed frame")
		expect(table.find(expected_last_seeing, env.player_a) ~= nil, "A is one of the two holding it")
		expect(table.find(expected_last_seeing, player_c) ~= nil, "C is the other, until the narrowing flushes")

		expect_client_set(s.net.get_clients_seeing(e), expected_seeing, "get_clients_seeing matches is_entity_visible")
		expect_client_set(
			s.net.get_clients_last_seeing(e),
			expected_last_seeing,
			"get_clients_last_seeing matches was_entity_visible"
		)
	end
)

-- 15) entity-level (whole-entity) whitelists

test("entity-level whitelist makes entity creation itself private", function(env)
	-- an un-paired Private gates the entity's very existence, the outer gate above
	-- the per-component whitelists. unlike a paired whitelist (which lets the entity
	-- create publicly and only hides one component), here the creation itself is
	-- private: an excluded player gets no entity and therefore no components at all.
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 42)
	s.world:add(e, s.defs.Burning)
	s.world:set(e, s.net.Private, { [env.player_a] = true })

	local snapshot = env.frame()
	local packet_a = env.packet_for(snapshot, env.player_a)
	local packet_b = env.packet_for(snapshot, env.player_b)

	expect_equal(packet_a.replicated[1], e, "A receives the entity creation")
	local data_a = packet_a.components[s.defs.Health]
	expect(data_a ~= nil and data_a.values ~= nil and data_a.values[1] == 42, "A receives the Health value")
	expect_equal(#packet_b.replicated, 0, "B never gets the entity")
	expect_equal(next(packet_b.components), nil, "B receives no component data")
end)

test("two clients see an entity-private entity only if whitelisted", function(env)
	-- end-to-end version of the above: the included client creates the whole entity,
	-- the excluded client never creates it at all.
	local s, c = env.server, env.client
	local c2 = env.make_client()
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 42)
	s.world:add(e, s.defs.Burning)
	s.world:set(e, s.net.Private, { [env.player_a] = true })

	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, env.player_a)) -- main client plays as A
	env.apply(env.packet_for(snapshot, env.player_b), c2) -- c2 plays as B

	local le_a = c.net.get_client_entity(e)
	expect(le_a ~= nil and c.world:contains(le_a), "A created the entity")
	expect_equal(c.world:get(le_a, c.defs.Health), 42, "A sees the Health value")
	expect_equal(c.world:has(le_a, c.defs.Burning), true, "A sees the tag")
	expect_equal(c2.net.get_client_entity(e), nil, "B never created the entity")
end)

test("a valueless entity Private is normalized to an empty filter blocking everyone", function(env)
	-- the entity-level counterpart of the paired normalization: an unpaired un-paired
	-- Private carrying no value warns, the value is rewritten to an empty filter,
	-- and the entity replicates to nobody rather than to everyone.
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 5)
	-- an ungated neighbour anchors both packets as real deliveries: without it a
	-- fully blocked entity leaves both clients packetless, and the absences below
	-- would read off the harness's blank-packet fallback instead
	local neighbour = s.world:entity()
	s.world:add(neighbour, s.net.Replicated)

	expected_warning("cannot have a nil value")
	s.world:add(e, s.net.Private) -- valueless: normalized
	expect_equal(s.world:has(e, s.net.Private), true, "the valueless filter stays on the entity")
	local filter = s.world:get(e, s.net.Private)
	expect(filter ~= nil and next(filter) == nil, "carrying an empty filter in place of the nil")
	expect_equal(table.isfrozen(filter), true, "the normalized filter is frozen like any cached one")

	local snapshot = env.frame()
	local packet_a = env.packet_for(snapshot, env.player_a)
	local packet_b = env.packet_for(snapshot, env.player_b)

	expect(table.find(packet_a.replicated, neighbour) ~= nil, "A's packet is real, not the blank fallback")
	expect(table.find(packet_b.replicated, neighbour) ~= nil, "B's packet is real, not the blank fallback")
	expect_equal(table.find(packet_a.replicated, e), nil, "A never receives the entity creation")
	expect_equal(table.find(packet_b.replicated, e), nil, "B does not either")
	expect_equal(s.net.is_entity_visible(e, env.player_a), false, "A is blocked by the normalized filter")
	expect_equal(s.net.is_entity_visible(e, env.player_b), false, "and so is B")
end)

test("adding an unpaired Private over a populated whitelist changes nothing at all", function(env)
	-- jecs's add returns early when the entity already holds the component, without firing the hooks duplecs
	-- listens on -- so a valueless add over an existing filter neither warns nor strips: the whitelist is left
	-- standing, admitting exactly the clients it names. that silent survival is half of why the valueless add
	-- is refused in the first place, so it is pinned here rather than left to be discovered.
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 5)
	local whitelist = { [env.player_a] = true }
	s.world:set(e, s.net.Private, whitelist)

	s.world:add(e, s.net.Private) -- no hook fires: no warning, and nothing to strip
	expect_equal(s.world:get(e, s.net.Private), whitelist, "the whitelist value survives the add by reference")

	local snapshot = env.frame()
	expect_equal(env.packet_for(snapshot, env.player_a).replicated[1], e, "A, whitelisted, still receives the entity")
	expect_equal(#env.packet_for(snapshot, env.player_b).replicated, 0, "B stays blocked by the surviving whitelist")
	expect_equal(s.net.is_entity_visible(e, env.player_a), true, "A is admitted by the filter the add left in place")
	expect_equal(s.net.is_entity_visible(e, env.player_b), false, "and B is not")
end)

test("entity whitelist is the outer gate over per-component whitelists", function(env)
	-- the entity whitelist and the per-component whitelist intersect: a player must
	-- pass both to see a gated component, but only the entity whitelist to see the
	-- entity and its public components. narrowing the entity whitelist below a player
	-- revokes the whole entity from them.
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 10)
	s.world:add(e, s.defs.Burning)
	s.world:set(e, s.net.Private, { [env.player_a] = true, [env.player_b] = true })
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_a] = true })

	local snapshot = env.frame()
	local packet_a = env.packet_for(snapshot, env.player_a)
	local packet_b = env.packet_for(snapshot, env.player_b)
	expect_equal(packet_a.replicated[1], e, "A gets the entity")
	local health_a = packet_a.components[s.defs.Health]
	expect(
		health_a ~= nil and health_a.values ~= nil and health_a.values[1] == 10,
		"A gets the gated Health, value and all"
	)
	expect(packet_a.components[s.defs.Burning] ~= nil, "A gets the public Burning")
	expect_equal(packet_b.replicated[1], e, "B gets the entity (allowed by the entity whitelist)")
	expect_equal(packet_b.components[s.defs.Health], nil, "B is filtered from the gated Health")
	expect(packet_b.components[s.defs.Burning] ~= nil, "B gets the public Burning")

	-- narrowing the entity whitelist to A revokes the whole entity from B, and from nobody else
	s.world:set(e, s.net.Private, { [env.player_a] = true })
	local snapshot2 = env.frame()
	expect_equal(env.packet_for(snapshot2, env.player_b).unreplicated[1], e, "B loses the whole entity")
	expect_equal(#env.packet_for(snapshot2, env.player_a).unreplicated, 0, "A keeps it through the narrowing")
end)

test("a nil per-component value empties that gate with the entity-level filter above it left standing", function(env)
	-- the normalization is scoped to the id that carried the nil: the per-component gate is emptied and its
	-- component reaches nobody, while the entity-level filter goes on gating the entity exactly as before.
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 10)
	s.world:set(e, s.net.Private, { [env.player_a] = true, [env.player_b] = true })
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_a] = true })

	local snapshot = env.frame()
	expect_equal(env.packet_for(snapshot, env.player_b).replicated[1], e, "B is admitted to the entity")
	expect_equal(env.packet_for(snapshot, env.player_b).components[s.defs.Health], nil, "but gated out of Health")

	expected_warning("cannot have a nil value")
	s.world:set(e, pair(s.net.Private, s.defs.Health), nil)
	expect_equal(s.world:has(e, pair(s.net.Private, s.defs.Health)), true, "only the per-component pair is emptied")
	expect_equal(s.world:has(e, s.net.Private), true, "the entity-level filter is untouched")
	expect_equal(s.net.is_component_visible(e, s.defs.Health, env.player_a), false, "so A loses the component")
	expect_equal(s.net.is_component_visible(e, s.defs.Health, env.player_b), false, "and B never gains it")
	expect_equal(s.net.is_entity_visible(e, env.player_b), true, "while the entity itself still reaches B")

	local snapshot2 = env.frame()
	local data_a = env.packet_for(snapshot2, env.player_a).components[s.defs.Health]
	expect(data_a ~= nil and data_a.removed ~= nil and data_a.removed[1] == e, "A, the admitted one, is sent a removal")

	-- and the surviving gate still gates: a client the entity-level whitelist never named sees nothing at all
	local player_c = fake_player("OuterGateOutsider")
	env.join(player_c, env.make_client())
	expect_equal(s.net.is_entity_visible(e, player_c), false, "the entity-level filter still blocks an unnamed client")
end)

test("a pair only replicates to players who can see its target", function(env)
	-- a pair cell is gated by the target's own entity-level visibility, so a player
	-- who cannot see the target never receives a pair aimed at it -- even though the
	-- public subject still replicates to them.
	local s = env.server
	local subject = s.world:entity()
	local target = s.world:entity()
	s.world:add(subject, s.net.Replicated)
	s.world:add(target, s.net.Replicated)
	s.world:set(subject, pair(s.defs.Likes, target), 7)
	s.world:set(target, s.net.Private, { [env.player_a] = true })

	local pair_id = pair(s.defs.Likes, target)
	local snapshot = env.frame()
	local packet_a = env.packet_for(snapshot, env.player_a)
	local packet_b = env.packet_for(snapshot, env.player_b)

	local pair_a = packet_a.components[pair_id]
	expect(pair_a ~= nil and pair_a.values ~= nil and pair_a.values[1] == 7, "A receives the pair and its value")
	expect(table.find(packet_a.replicated, target) ~= nil, "A receives the target")
	expect_equal(packet_b.components[pair_id], nil, "B does not receive the pair")
	expect_equal(table.find(packet_b.replicated, target), nil, "B does not receive the target")
	expect(table.find(packet_b.replicated, subject) ~= nil, "B still receives the public subject")
end)

test("granting a player on the target's entity whitelist starts replicating pairs aimed at it", function(env)
	-- restage_pairs_targeting re-runs when the target's entity whitelist changes, so
	-- granting a player the target also delivers the pairs aimed at it.
	local s = env.server
	local c2 = env.make_client()
	local subject = s.world:entity()
	local target = s.world:entity()
	s.world:add(subject, s.net.Replicated)
	s.world:add(target, s.net.Replicated)
	s.world:set(subject, pair(s.defs.Likes, target), 7)
	s.world:set(target, s.net.Private, { [env.player_a] = true })

	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, env.player_a)) -- main client plays as A
	env.apply(env.packet_for(snapshot, env.player_b), c2) -- c2 plays as B
	expect(c2.net.get_client_entity(subject) ~= nil, "B has the subject")
	expect_equal(c2.net.get_client_entity(target), nil, "B lacks the target before the grant")

	s.net.edit_entity_privacy(target, env.player_b, true)
	env.apply(env.packet_for(env.frame(), env.player_b), c2)
	local le_subject = c2.net.get_client_entity(subject)
	local le_target = c2.net.get_client_entity(target)
	expect(le_target ~= nil, "B now has the target")
	expect_equal(c2.world:get(le_subject, pair(c2.defs.Likes, le_target)), 7, "B received the pair")
end)

test("allowing a player on an empty entity whitelist reveals the entity", function(env)
	-- an empty entity whitelist blocks everyone; allowing a player via
	-- edit_entity_privacy is the copy-on-write path to start admitting players one at a time.
	local s = env.server
	local c2 = env.make_client()
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 7)
	s.world:set(e, s.net.Private, {}) -- empty: blocks everyone

	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, env.player_b), c2)
	expect_equal(c2.net.get_client_entity(e), nil, "B blocked before the grant")

	s.net.edit_entity_privacy(e, env.player_b, true)
	local packet_b = env.packet_for(env.frame(), env.player_b)
	expect_equal(packet_b.replicated[1], e, "B now receives the entity creation")
	local data_b = packet_b.components[s.defs.Health]
	expect(data_b ~= nil and data_b.values ~= nil and data_b.values[1] == 7, "B receives the Health value")
	env.apply(packet_b, c2)
	expect_equal(c2.world:get(c2.net.get_client_entity(e), c2.defs.Health), 7, "B's client gains the value")

	-- one player at a time: the grant admits exactly the named client rather than reopening the empty whitelist
	expect_equal(s.net.is_entity_visible(e, env.player_a), false, "A is still blocked after the grant")
end)

test("disallowing a player for an entity removes the entity wholesale", function(env)
	-- revoking a player from the entity whitelist deletes the whole entity from them,
	-- via the per-player unreplicated list.
	local s, c = env.server, env.client
	local c2 = env.make_client()
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 42)
	s.world:set(e, s.net.Private, { [env.player_a] = true, [env.player_b] = true })

	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, env.player_a))
	env.apply(env.packet_for(snapshot, env.player_b), c2)
	local le_a = c.net.get_client_entity(e)
	local le_b = c2.net.get_client_entity(e)
	expect(le_a ~= nil and c.world:contains(le_a), "A has the entity before the edit")
	expect(le_b ~= nil and c2.world:contains(le_b), "B has the entity before the edit")

	s.net.edit_entity_privacy(e, env.player_b, false)
	local snapshot2 = env.frame()
	local packet_b = env.packet_for(snapshot2, env.player_b)
	expect_equal(packet_b.unreplicated[1], e, "B is told to delete the entity")
	env.apply(packet_b, c2)
	expect_equal(c2.world:contains(le_b), false, "B's entity deleted wholesale")

	-- the revoke is per-client, not a drop of the whole filter: A's frame carries no delete, so A's entity lives
	env.apply(env.packet_for(snapshot2, env.player_a))
	expect_equal(c.world:contains(le_a), true, "A keeps the entity")
end)

test("allowing a player for an entity edits copy-on-write", function(env)
	-- entity whitelist edits clone -> mutate -> freeze -> world:set, mirroring the
	-- paired component-level allow, so the prior value is never mutated in place.
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 1)
	local original = { [env.player_a] = true }
	s.world:set(e, s.net.Private, original)

	s.net.edit_entity_privacy(e, env.player_b, true)

	expect_equal(original[env.player_b], nil, "old value not mutated")
	local current = s.world:get(e, s.net.Private)
	expect(current ~= original, "a fresh value was set")
	expect_equal(current[env.player_a], true, "existing entries carried over")
	expect_equal(current[env.player_b], true, "player added")
	expect_equal(table.isfrozen(current), true, "new value frozen")
end)

test("redundant entity-level allow/disallow edits are no-ops", function(env)
	-- the entity whitelist editors short-circuit when the player's membership already
	-- matches, so no fresh value is set and no per-player churn is produced.
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 1)
	s.world:set(e, s.net.Private, { [env.player_a] = true })

	local snapshot = env.frame()
	expect_equal(env.packet_for(snapshot, env.player_a).replicated[1], e, "A holds the entity before the edits")
	expect_equal(#env.packet_for(snapshot, env.player_b).replicated, 0, "B is excluded before the edits")

	local before = s.world:get(e, s.net.Private)
	s.net.edit_entity_privacy(e, env.player_a, true) -- already allowed
	s.net.edit_entity_privacy(e, env.player_b, false) -- already absent
	expect_equal(s.world:get(e, s.net.Private), before, "whitelist value unchanged")

	local snapshot2 = env.frame()
	local packet_a = env.packet_for(snapshot2, env.player_a)
	local packet_b = env.packet_for(snapshot2, env.player_b)
	expect_equal(next(packet_a.components), nil, "no data for A")
	expect_equal(#packet_a.unreplicated, 0, "the redundant allow does not revoke A")
	expect_equal(#packet_b.unreplicated, 0, "no unreplicate churn for B")
	expect_equal(#packet_b.replicated, 0, "the redundant disallow does not admit B")
end)

test("an entity whitelist added before Replicated filters from the first packet", function(env)
	-- caching the entity whitelist before Replicated is added means the entity's first
	-- existence diff is already narrowed, so an excluded player never sees the entity.
	local s = env.server
	local c2 = env.make_client()
	local e = s.world:entity()
	s.world:set(e, s.defs.Health, 5)
	s.world:set(e, s.net.Private, { [env.player_a] = true })
	s.world:add(e, s.net.Replicated)

	local snapshot = env.frame()
	local packet_a = env.packet_for(snapshot, env.player_a)
	expect_equal(packet_a.replicated[1], e, "A receives the entity")
	local data_a = packet_a.components[s.defs.Health]
	expect(data_a ~= nil and data_a.values ~= nil and data_a.values[1] == 5, "A receives the value")

	local packet_b = env.packet_for(snapshot, env.player_b)
	expect_equal(#packet_b.replicated, 0, "B never sees the entity")
	env.apply(packet_b, c2)
	expect_equal(c2.net.get_client_entity(e), nil, "B's client never creates it")
end)

test("adding an entity whitelist to a public entity revokes it from excluded players", function(env)
	-- a public entity gated mid-life loses its existence for every excluded player; the
	-- per-player existence diff turns the mask drop into a wholesale delete.
	local s, c = env.server, env.client
	local c2 = env.make_client()
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 5)

	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, env.player_a))
	env.apply(env.packet_for(snapshot, env.player_b), c2)
	local le_a = c.net.get_client_entity(e)
	local le_b = c2.net.get_client_entity(e)
	expect(le_a ~= nil and le_b ~= nil, "both clients have the entity")

	s.world:set(e, s.net.Private, { [env.player_a] = true })
	local snapshot2 = env.frame()
	env.apply(env.packet_for(snapshot2, env.player_a))
	env.apply(env.packet_for(snapshot2, env.player_b), c2)
	expect_equal(c.world:contains(le_a), true, "A's entity survives")
	expect_equal(c2.world:contains(le_b), false, "B's entity is gone")
end)

test("removing an entity whitelist reopens the entity to everyone", function(env)
	-- clearing the entity whitelist mask reopens the entity's existence to all
	-- allocated players, so a previously excluded player now creates it.
	local s = env.server
	local c2 = env.make_client()
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 5)
	s.world:set(e, s.net.Private, { [env.player_a] = true })

	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, env.player_a))
	env.apply(env.packet_for(snapshot, env.player_b), c2)
	expect_equal(c2.net.get_client_entity(e), nil, "B blocked before the removal")

	s.world:remove(e, s.net.Private)
	local packet_b = env.packet_for(env.frame(), env.player_b)
	expect_equal(packet_b.replicated[1], e, "B now receives the entity")
	local data_b = packet_b.components[s.defs.Health]
	expect(data_b ~= nil and data_b.values ~= nil and data_b.values[1] == 5, "B receives the value")
	env.apply(packet_b, c2)
	expect_equal(c2.world:get(c2.net.get_client_entity(e), c2.defs.Health), 5, "B's client gains the value")
end)

test("setting an entity whitelist value to nil narrows the entity to nobody", function(env)
	-- the entity-level face of the narrowing: setting the value to nil does not remove the whitelist, it
	-- empties it, so the client it admitted deletes the entity rather than the excluded one creating it.
	local s, c = env.server, env.client
	local c2 = env.make_client()
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 5)
	s.world:set(e, s.net.Private, { [env.player_a] = true })

	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, env.player_a))
	env.apply(env.packet_for(snapshot, env.player_b), c2)
	local le_a = c.net.get_client_entity(e)
	expect(le_a ~= nil and c.world:contains(le_a), "A has the entity before the edit")
	expect_equal(c2.net.get_client_entity(e), nil, "B, excluded, never created it")

	expected_warning("cannot have a nil value")
	s.world:set(e, s.net.Private, nil)
	expect_equal(s.world:has(e, s.net.Private), true, "the filter was emptied, not removed from the entity")
	expect_equal(s.net.is_entity_visible(e, env.player_a), false, "the admitted client loses the entity")
	expect_equal(s.net.is_entity_visible(e, env.player_b), false, "and the excluded one never gains it")

	local snapshot2 = env.frame()
	local packet_a = env.packet_for(snapshot2, env.player_a)
	local packet_b = env.packet_for(snapshot2, env.player_b)
	expect_equal(packet_a.unreplicated[1], e, "A is told to delete it")
	expect_equal(#packet_b.replicated, 0, "B is told to create nothing")
	env.apply(packet_a, c)
	env.apply(packet_b, c2)
	expect_equal(c.world:contains(le_a), false, "A's entity is gone end to end")
	expect_equal(c2.net.get_client_entity(e), nil, "and B still holds none")
end)

test("per-player component-removal skip under an entity whitelist", function(env)
	-- a player who deletes the whole entity this frame (revoked from the entity
	-- whitelist) does not also need the per-component removal -- deleting the entity
	-- locally strips it. the skip is per-player: a player who keeps the entity still
	-- gets the component removal.
	local s, c = env.server, env.client
	local c2 = env.make_client()
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 100)
	s.world:set(e, s.net.Private, { [env.player_a] = true, [env.player_b] = true })

	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, env.player_a))
	env.apply(env.packet_for(snapshot, env.player_b), c2)
	local le_a = c.net.get_client_entity(e)
	local le_b = c2.net.get_client_entity(e)
	expect_equal(c.world:get(le_a, c.defs.Health), 100, "A holds the value before the removal")
	expect_equal(c2.world:get(le_b, c2.defs.Health), 100, "B holds it too, before the revocation")

	-- same frame: B is revoked from the entity AND Health is removed for everyone
	s.net.edit_entity_privacy(e, env.player_b, false)
	s.world:remove(e, s.defs.Health)
	local snapshot2 = env.frame()
	local packet_a = env.packet_for(snapshot2, env.player_a)
	local packet_b = env.packet_for(snapshot2, env.player_b)

	local data_a = packet_a.components[s.defs.Health]
	expect(
		data_a ~= nil and data_a.removed ~= nil and data_a.removed[1] == e,
		"A keeps the entity and gets the Health removal"
	)
	expect_equal(#packet_a.unreplicated, 0, "A is not told to delete anything")
	expect_equal(packet_b.unreplicated[1], e, "B deletes the entity wholesale")
	expect_equal(packet_b.components[s.defs.Health], nil, "B's redundant Health removal is skipped")
	-- and under no other key either: the wholesale delete is the entirety of B's packet
	expect_equal(next(packet_b.components), nil, "B receives no sections at all")

	env.apply(packet_a)
	env.apply(packet_b, c2)
	expect_equal(c.world:contains(le_a), true, "A's entity survives")
	expect_equal(c.world:has(le_a, c.defs.Health), false, "A's Health removed")
	expect_equal(c2.world:contains(le_b), false, "B's entity deleted")
end)

test("per-player pair-target-removal skip under an entity whitelist", function(env)
	-- companion to the above on the target arm: a player who loses the pair's target
	-- this frame (revoked from the target's entity whitelist) deletes it locally, which
	-- auto-removes the pair, so the explicit pair removal is skipped for that player
	-- only. a player who keeps the target still gets the pair removal.
	local s, c = env.server, env.client
	local c2 = env.make_client()
	local subject = s.world:entity()
	local target = s.world:entity()
	s.world:add(subject, s.net.Replicated)
	s.world:add(target, s.net.Replicated)
	s.world:set(subject, pair(s.defs.Likes, target), 4)
	s.world:set(target, s.net.Private, { [env.player_a] = true, [env.player_b] = true })

	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, env.player_a))
	env.apply(env.packet_for(snapshot, env.player_b), c2)
	local le_subject = c.net.get_client_entity(subject)
	local le_target = c.net.get_client_entity(target)
	local le_subject_b = c2.net.get_client_entity(subject)
	local le_target_b = c2.net.get_client_entity(target)
	expect_equal(c.world:get(le_subject, pair(c.defs.Likes, le_target)), 4, "A holds the pair before the removal")
	expect_equal(
		c2.world:get(le_subject_b, pair(c2.defs.Likes, le_target_b)),
		4,
		"B holds it too, before the revocation"
	)

	-- same frame: B loses the target AND the pair is removed for everyone
	s.net.edit_entity_privacy(target, env.player_b, false)
	s.world:remove(subject, pair(s.defs.Likes, target))
	local pair_id = pair(s.defs.Likes, target)
	local snapshot2 = env.frame()
	local packet_a = env.packet_for(snapshot2, env.player_a)
	local packet_b = env.packet_for(snapshot2, env.player_b)

	local data_a = packet_a.components[pair_id]
	expect(
		data_a ~= nil and data_a.removed ~= nil and data_a.removed[1] == subject,
		"A keeps the target and gets the pair removal"
	)
	expect_equal(packet_b.unreplicated[1], target, "B deletes the target wholesale")
	expect_equal(#packet_b.unreplicated, 1, "and keeps the public subject")
	expect_equal(packet_b.components[pair_id], nil, "B's redundant pair removal is skipped")
	-- and under no other key either: a run naming some other target keys elsewhere in the merged view, so it
	-- would slip past the lookup above
	expect_equal(next(packet_b.components), nil, "B receives no sections at all")

	env.apply(packet_a)
	env.apply(packet_b, c2)
	expect_equal(c.world:contains(le_target), true, "A keeps the target")
	expect_equal(c.world:has(le_subject, pair(c.defs.Likes, le_target)), false, "A's pair removed explicitly")
	expect_equal(c2.world:contains(le_target_b), false, "B's target deleted")
	expect_equal(c2.world:contains(le_subject_b), true, "B keeps the public subject")
	expect_equal(c2.world:target(le_subject_b, c2.defs.Likes), nil, "and the pair went with the target")
end)

test("a late joiner's full packet respects entity whitelists", function(env)
	-- full_packet filters entities through compute_entity_vis, so a brand-new joiner
	-- outside an entity whitelist receives neither the entity nor its components nor
	-- pairs aimed at it, but still receives unrelated public entities (the public
	-- subject).
	local s = env.server
	local subject = s.world:entity()
	local target = s.world:entity()
	s.world:add(subject, s.net.Replicated)
	s.world:add(target, s.net.Replicated)
	s.world:set(target, s.defs.Health, 10)
	s.world:set(subject, pair(s.defs.Likes, target), 4)
	s.world:set(target, s.net.Private, { [env.player_a] = true })
	local pair_id = pair(s.defs.Likes, target)

	-- positive control: A, inside the whitelist, receives all of it, so C's empty result below is
	-- attributable to the whitelist rather than to these cells never replicating at all
	local packet_a = env.packet_for(env.frame(), env.player_a)
	expect(table.find(packet_a.replicated, target) ~= nil, "A receives the private target")
	local pair_data_a = packet_a.components[pair_id]
	expect(pair_data_a ~= nil and pair_data_a.values ~= nil and pair_data_a.values[1] == 4, "A receives the pair")

	-- a brand-new joiner outside the whitelist receives a full packet on its first frame
	local cC = env.make_client()
	local player_c = fake_player("PlayerC")
	local packet_c = env.join(player_c, cC)

	expect_equal(table.find(packet_c.replicated, target), nil, "C does not receive the private target")
	expect(table.find(packet_c.replicated, subject) ~= nil, "C receives the public subject")
	expect_equal(#packet_c.replicated, 1, "the public subject is the only entity C receives")
	expect_equal(packet_c.components[s.defs.Health], nil, "C does not receive the private target's Health")
	expect_equal(packet_c.components[pair_id], nil, "C does not receive the pair aimed at the target")
	expect_equal(next(packet_c.components), nil, "C's full packet carries no sections at all")
	expect_equal(cC.net.get_client_entity(target), nil, "C's client never creates the target")
	local lc_subject = cC.net.get_client_entity(subject)
	expect(lc_subject ~= nil, "C's client creates the public subject")
	expect_equal(cC.world:target(lc_subject, cC.defs.Likes), nil, "C's subject holds no pair to the target")
end)

test("recycling a player slot clears the prior occupant's entity grant", function(env)
	-- allocate_player clears the freed bit from entity_visibilities_last and
	-- entity_whitelist_mask, so a newcomer reusing the bit does not inherit the prior
	-- occupant's private entity.
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 42)
	-- private to B only
	s.world:set(e, s.net.Private, { [env.player_b] = true })
	local snapshot = env.frame() -- B sees the private entity, A does not
	expect_equal(env.packet_for(snapshot, env.player_b).replicated[1], e, "B saw the private entity")
	expect_equal(#env.packet_for(snapshot, env.player_a).replicated, 0, "A never did")

	-- B leaves, then a fresh player reuses B's freed bit. the slot's stale entity bits
	-- must be cleared so the newcomer does not inherit the private entity. C reusing
	-- B's bit rather than some other slot is structurally guaranteed by lowest-first
	-- allocation -- only B's bit is free below the fresh tail -- which is what makes
	-- this exercise the freed-slot sweep.
	s.net.remove_client(env.player_b)
	local c2 = env.make_client()
	local player_c = fake_player("PlayerC")
	local packet_c = env.join(player_c, c2)

	expect_equal(#packet_c.replicated, 0, "C does not inherit B's private entity")
	expect_equal(c2.net.get_client_entity(e), nil, "C's client never creates the private entity")

	-- the sweep must clear the freed bit from the last-sent words too, not only from the filter's allow
	-- words: a stale bit there would read C's create as already sent, so a genuine grant would never ship
	s.net.edit_entity_privacy(e, player_c, true)
	local packet_c2 = env.packet_for(env.frame(), player_c)
	expect_equal(packet_c2.replicated[1], e, "C receives the entity once genuinely admitted")
	local data_c = packet_c2.components[s.defs.Health]
	expect(data_c ~= nil and data_c.values ~= nil and data_c.values[1] == 42, "C receives the value with it")
	env.apply(packet_c2, c2)
	expect_equal(c2.world:get(c2.net.get_client_entity(e), c2.defs.Health), 42, "C's client gains the value")
end)

test("a pair to a Named (unreplicated) target ignores entity-whitelist narrowing", function(env)
	-- a Named (unreplicated) target is globally visible, so pair_target_mask returns
	-- allocated_mask for it; an un-paired Private on such a target is meaningless and
	-- does not gate pairs aimed at it.
	local s = env.server
	local target = s.world:entity()
	s.world:set(target, jecs.Name, "NamedTarget") -- replicable by Name, not Replicated
	s.world:set(target, s.net.Private, { [env.player_a] = true }) -- ignored: target is not replicated

	local subject = s.world:entity()
	s.world:add(subject, s.net.Replicated)
	s.world:set(subject, pair(s.defs.Likes, target), 1)

	local pair_id = pair(s.defs.Likes, target)
	local snapshot = env.frame()
	local data_a = env.packet_for(snapshot, env.player_a).components[pair_id]
	expect(data_a ~= nil and data_a.values ~= nil and data_a.values[1] == 1, "A receives the pair")
	local packet_b = env.packet_for(snapshot, env.player_b)
	local data_b = packet_b.components[pair_id]
	expect(
		data_b ~= nil and data_b.values ~= nil and data_b.values[1] == 1,
		"B receives the pair despite the target's whitelist"
	)
	-- the name is schema, so it reaches the excluded player too -- without it B could not map the target
	expect_equal(packet_b.names[target], "NamedTarget", "B receives the target's name announcement")
	expect_equal(
		s.net.is_component_visible(subject, pair_id, env.player_b),
		true,
		"the server reports the pair visible to B"
	)
end)

test("same-frame entity-whitelist churn nets out", function(env)
	-- a disallow then an allow of the same player in one frame leaves the existence
	-- mask unchanged, so the existence diff produces no create and no delete for them.
	local s = env.server
	local c2 = env.make_client()
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 8)
	s.world:set(e, s.net.Private, { [env.player_a] = true, [env.player_b] = true })

	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, env.player_b), c2)
	local le_b = c2.net.get_client_entity(e)
	expect(le_b ~= nil and c2.world:contains(le_b), "B has the entity before the churn")

	s.net.edit_entity_privacy(e, env.player_b, false)
	s.net.edit_entity_privacy(e, env.player_b, true)
	-- raw packets: a netted-out churn leaves nothing to send, so B must be omitted from the returned map
	-- entirely. reading a frame's blank fallback instead would report empty lists either way.
	local packets = s.net.generate_packets()
	expect_equal(packets[env.player_b], nil, "no packet for B at all")
	expect_equal(packets[env.player_a], nil, "and none for A, whose standing never moved")

	-- the slot stays coherent afterward: a later value change reaches B as a plain delta on the same client
	-- entity rather than as a delete-and-recreate
	s.world:set(e, s.defs.Health, 9)
	local packet_b = env.packet_for(env.frame(), env.player_b)
	expect_equal(#packet_b.unreplicated, 0, "no delete for B")
	expect_equal(#packet_b.replicated, 0, "no re-creation for B")
	local data_b = packet_b.components[s.defs.Health]
	expect(data_b ~= nil and data_b.values ~= nil and data_b.values[1] == 9, "B receives the new value")
	env.apply(packet_b, c2)
	expect_equal(c2.world:contains(le_b), true, "B's entity intact")
	expect_equal(c2.world:get(le_b, c2.defs.Health), 9, "B's client took the update on the same entity")
end)

test("entity whitelist values are frozen against in-place mutation", function(env)
	-- like paired whitelists, un-paired Private values are frozen on set so caching
	-- by reference is safe and out-of-band mutation errors loudly.
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	local wl = { [env.player_a] = true }
	s.world:set(e, s.net.Private, wl)

	expect_equal(table.isfrozen(wl), true, "value frozen on set")
	expect_error(function()
		wl[env.player_b] = true
	end, "in-place mutation", "readonly table")

	-- the cached mask derives from that very table, and the refused mutation leaves the gate untouched
	expect_equal(s.net.is_entity_visible(e, env.player_a), true, "the whitelisted player passes the gate")
	expect_equal(s.net.is_entity_visible(e, env.player_b), false, "the refused mutation admitted nobody")

	-- re-setting an already-frozen value must not error
	s.world:set(e, s.net.Private, wl)
	expect_equal(s.net.is_entity_visible(e, env.player_a), true, "the re-set leaves the gate in place")
	expect_equal(s.net.is_entity_visible(e, env.player_b), false, "and admits nobody new")
end)

test("is_component_visible reflects the entity-level whitelist", function(env)
	-- is_component_visible resolves visibility from the staged masks, which compute_cur
	-- narrows by the entity-level whitelist, so a player gated out of the entity reads
	-- as unable to see its components.
	local s = env.server
	local e = s.world:entity()
	s.world:set(e, s.defs.Health, 1)
	s.world:add(e, s.net.Replicated)

	expect_equal(s.net.is_component_visible(e, s.defs.Health, env.player_a), true, "A sees Health while public")
	expect_equal(s.net.is_component_visible(e, s.defs.Health, env.player_b), true, "B sees Health while public")

	-- drain, so the public masks are last-sent: the narrowing below is then a genuinely staged change rather
	-- than the absence of anything sent yet, and the two mask reads can be told apart
	env.frame()

	s.world:set(e, s.net.Private, { [env.player_a] = true })
	expect_equal(s.net.is_component_visible(e, s.defs.Health, env.player_a), true, "A still sees Health")
	expect_equal(s.net.is_component_visible(e, s.defs.Health, env.player_b), false, "B gated out of the whole entity")
	expect_equal(s.net.is_entity_visible(e, env.player_b), false, "B's whole entity is gated with it")
	expect_equal(
		s.net.was_component_visible(e, s.defs.Health, env.player_b),
		true,
		"B still holds Health until the narrowing is flushed"
	)

	env.frame()
	expect_equal(s.net.was_component_visible(e, s.defs.Health, env.player_b), false, "the flush retires B's mask")
end)

test("assigning an entity whitelist naming only an unregistered player blocks everyone", function(env)
	-- mirrors the per-component case: an unregistered player is skipped and
	-- pruned instead of erroring, leaving the entity gated to nobody.
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 5)

	local stranger = fake_player("Stranger") -- never passed to add_client
	expected_warning("untracked client(s)! they were pruned from it")
	s.world:set(e, s.net.Private, { [stranger] = true })

	local snapshot = env.frame()
	expect_equal(#env.packet_for(snapshot, env.player_a).replicated, 0, "A is blocked")
	expect_equal(#env.packet_for(snapshot, env.player_b).replicated, 0, "B is blocked")

	-- the prune persists: edit_entity_privacy clones the cached (already-
	-- pruned) table, so the stranger never reappears through the edit path.
	s.net.edit_entity_privacy(e, env.player_a, true)
	local snapshot2 = env.frame()
	local final = s.world:get(e, s.net.Private)
	expect_equal(final[stranger], nil, "stranger pruned from the persisted entity whitelist")
	expect_equal(final[env.player_a], true, "player_a present in the persisted entity whitelist")

	-- and the edited whitelist is the one actually in effect, admitting exactly the player it names
	local packet_a = env.packet_for(snapshot2, env.player_a)
	expect_equal(packet_a.replicated[1], e, "A receives the entity once admitted")
	local data_a = packet_a.components[s.defs.Health]
	expect(data_a ~= nil and data_a.values ~= nil and data_a.values[1] == 5, "A receives the value with it")
	expect_equal(#env.packet_for(snapshot2, env.player_b).replicated, 0, "B stays blocked")
	env.apply(packet_a)
	expect_equal(c.world:get(c.net.get_client_entity(e), c.defs.Health), 5, "A's client gains the value")
end)

test("same-frame entity- and component-whitelist edits resolve independently", function(env)
	-- the entity-level and per-component whitelists share one cache store (keyed
	-- Existence vs the component), and both edits restage the same Health cell in
	-- one frame. the cell must land on the intersection of both edits, with
	-- neither level's edit bleeding into the other's cache entry.
	local s, c = env.server, env.client
	local c2 = env.make_client()
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 7)
	s.world:add(e, s.defs.Burning)
	s.world:set(e, s.net.Private, { [env.player_a] = true, [env.player_b] = true })
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_a] = true, [env.player_b] = true })

	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, env.player_a)) -- main client plays as A
	env.apply(env.packet_for(snapshot, env.player_b), c2) -- c2 plays as B
	local le_a = c.net.get_client_entity(e)
	local le_b = c2.net.get_client_entity(e)
	expect_equal(c.world:get(le_a, c.defs.Health), 7, "A sees Health before the edits")
	expect_equal(c2.world:get(le_b, c2.defs.Health), 7, "B sees Health before the edits")

	-- same frame: A loses only the gated Health (component level) while B loses
	-- the whole entity (entity level)
	s.net.edit_component_privacy(e, s.defs.Health, env.player_a, false)
	s.net.edit_entity_privacy(e, env.player_b, false)

	local snapshot2 = env.frame()
	local packet_a = env.packet_for(snapshot2, env.player_a)
	local packet_b = env.packet_for(snapshot2, env.player_b)

	local data_a = packet_a.components[s.defs.Health]
	expect(data_a ~= nil and data_a.removed ~= nil and data_a.removed[1] == e, "A receives the Health removal")
	expect_equal(#packet_a.unreplicated, 0, "A keeps the entity")
	expect_equal(packet_a.components[s.defs.Burning], nil, "A's public Burning is untouched by the restages")
	expect_equal(packet_b.unreplicated[1], e, "B deletes the entity wholesale")
	expect_equal(packet_b.components[s.defs.Health], nil, "B's redundant Health removal is skipped")
	expect_equal(packet_b.components[s.defs.Burning], nil, "B's redundant Burning removal is skipped")

	env.apply(packet_a)
	env.apply(packet_b, c2)
	expect_equal(c.world:contains(le_a), true, "A's entity survives")
	expect_equal(c.world:has(le_a, c.defs.Health), false, "A's Health removed")
	expect_equal(c.world:has(le_a, c.defs.Burning), true, "A keeps the tag")
	expect_equal(c2.world:contains(le_b), false, "B's entity deleted")

	-- reopening the entity level must not have disturbed the component level:
	-- B re-creates the entity and still passes the Health whitelist, while A
	-- stays revoked from Health.
	s.net.edit_entity_privacy(e, env.player_b, true)
	local snapshot3 = env.frame()
	local packet_b2 = env.packet_for(snapshot3, env.player_b)
	expect_equal(packet_b2.replicated[1], e, "B re-creates the entity")
	local data_b2 = packet_b2.components[s.defs.Health]
	expect(
		data_b2 ~= nil and data_b2.values ~= nil and data_b2.values[1] == 7,
		"B receives Health again (component whitelist intact)"
	)
	expect_equal(next(env.packet_for(snapshot3, env.player_a).components), nil, "A sees no churn from B's grant")
	env.apply(packet_b2, c2)
	expect_equal(c2.world:get(c2.net.get_client_entity(e), c2.defs.Health), 7, "B's client regains the value")
	-- the other direction of the independence claim: B's entity-level grant left A's component-level
	-- revocation exactly where it was
	expect_equal(
		s.net.is_component_visible(e, s.defs.Health, env.player_a),
		false,
		"A stays revoked from Health across B's grant"
	)
	expect_equal(c.world:has(le_a, c.defs.Health), false, "A's client does not regain Health")
end)

-- 16) packet sections

test("players sharing a visibility mask receive the same section by reference", function(env)
	-- sections are built once per (mask, component) and stamped into every
	-- player in the mask's packet buffer; a hookless section's values array is
	-- handed to each of them by reference. raw packets (no deep copy) so
	-- reference identity is observable.
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 5)

	local packets = s.net.generate_packets()
	local view_a = decode_packet(packets[env.player_a])
	local section_a = view_a.sections[1]
	expect(section_a ~= nil, "A received a section")
	expect_equal(#view_a.sections, 1, "the one shared mask encodes one section")
	expect_equal(section_a.component, s.defs.Health, "the section encodes its component id")
	expect(
		packets[env.player_a].values ~= nil and packets[env.player_a].values[1] ~= nil,
		"A's packet actually carries a populated values side array"
	)
	expect_equal(packets[env.player_b].values[1], packets[env.player_a].values[1], "B references the same values table")
	-- the shared array is the section's own values list, holding exactly the one cell: an array rebuilt per
	-- player would compare unequal above while still decoding to the right value here
	expect_equal(section_a.values, packets[env.player_a].values[1], "the section decodes out of that very array")
	expect_equal(#packets[env.player_a].values[1], 1, "the shared array holds exactly the one cell's value")
	expect_equal(packets[env.player_a].values[1][1], 5, "and it is the value that was set")
end)

test("cells with different masks split into sections of the same component", function(env)
	local s = env.server
	local e1 = s.world:entity()
	local e2 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(e2, s.net.Replicated)
	s.world:set(e1, s.defs.Health, 1)
	s.world:set(e2, s.defs.Health, 2)
	s.world:set(e2, pair(s.net.Private, s.defs.Health), { [env.player_a] = true })

	local function health_sections(packet)
		local found = {}
		for _, section in decode_packet(packet).sections do
			if section.component == s.defs.Health then
				table.insert(found, section)
			end
		end
		return found
	end

	local packets = s.net.generate_packets()
	local sections_a = health_sections(packets[env.player_a])
	local sections_b = health_sections(packets[env.player_b])
	expect_equal(#sections_a, 2, "A's packet splits Health across two masks")
	expect_equal(#sections_b, 1, "B's packet carries only the public mask's section")

	-- the counts alone would still pass with e2's private cell riding along inside the section B shares, so
	-- pin which cell each section actually carries
	local covered_by_a = {}
	for _, section in sections_a do
		expect(section.ids ~= nil and #section.ids == 1, "each of A's Health sections carries a single cell")
		covered_by_a[section.ids[1]] = true
	end
	expect_equal(covered_by_a[e1], true, "A's sections cover the public cell")
	expect_equal(covered_by_a[e2], true, "A's sections cover the private cell")
	expect(sections_b[1].ids ~= nil and #sections_b[1].ids == 1, "B's section carries a single cell")
	expect_equal(sections_b[1].ids[1], e1, "and it is the public one")
end)

test("a delta packet held across a later frame keeps its escaped values intact", function(env)
	-- generate_packets recycles its per-frame scratch through free-list pools,
	-- but a hookless section's values array escapes into packet.values by
	-- reference and must never be released to those pools. holding a raw
	-- packet (no deep copy) across a second generate_packets call -- which
	-- recycles the first frame's drafts and lists -- and reconciling only
	-- afterward proves the escape held.
	local s, c = env.server, env.client
	local e1 = s.world:entity()
	local e2 = s.world:entity()
	local e3 = s.world:entity()
	local e4 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(e2, s.net.Replicated)
	s.world:add(e3, s.net.Replicated)
	s.world:add(e4, s.net.Replicated)
	s.world:set(e1, s.defs.Health, 1)
	s.world:set(e2, s.defs.Health, 2)
	s.world:set(e4, s.defs.Health, 4)
	env.sync(env.player_a) -- baseline: e1, e2, e4's Health are already visible to A

	-- frame 1: change e1 and e2's hookless Health values and hold the raw
	-- packet unreconciled
	s.world:set(e1, s.defs.Health, 100)
	s.world:set(e2, s.defs.Health, 200)
	local held_packet = s.net.generate_packets()[env.player_a]

	-- frame 2 recycles frame 1's pooled drafts/lists: a fresh value on e3, a
	-- plain removal on e2, and a coalesced nulled entry on e4 exercise the
	-- values, removed, and nulled lists the pools cover
	s.world:set(e3, s.defs.Health, 300)
	s.world:remove(e2, s.defs.Health)
	s.world:remove(e4, s.defs.Health)
	s.world:add(e4, s.defs.Health)
	local next_packet = s.net.generate_packets()[env.player_a]

	-- the escape is observable directly, before anything reconciles: frame 2 must neither hand the held
	-- array back out nor have cleared and refilled it in place
	local held_values = held_packet.values
	expect(held_values ~= nil and held_values[1] ~= nil, "the held packet carries a hookless values array")
	expect(
		next_packet.values ~= nil and next_packet.values[1] ~= held_values[1],
		"frame 2 built its own array rather than recycling the escaped one"
	)
	local first, second = held_values[1][1], held_values[1][2]
	expect(
		(first == 100 and second == 200) or (first == 200 and second == 100),
		`the held array still holds frame 1's values (got {tostring(first)}, {tostring(second)})`
	)

	-- reconcile the held packet only now, in order -- if pooling had wrongly
	-- released the escaped values array, frame 2 would have cleared or
	-- overwritten it in place
	c.net.reconcile_packet(deep_copy(held_packet))
	c.net.reconcile_packet(deep_copy(next_packet))

	local le1 = c.net.get_client_entity(e1)
	local le2 = c.net.get_client_entity(e2)
	local le3 = c.net.get_client_entity(e3)
	local le4 = c.net.get_client_entity(e4)
	expect_equal(c.world:get(le1, c.defs.Health), 100, "e1's frame 1 value survived the later frame")
	expect_equal(c.world:has(le2, c.defs.Health), false, "e2's frame 2 removal applied after the held value")
	expect_equal(c.world:get(le3, c.defs.Health), 300, "e3's frame 2 value applied")
	expect_equal(c.world:has(le4, c.defs.Health), true, "e4 still has Health after the coalesced nulled entry")
	expect_equal(c.world:get(le4, c.defs.Health), nil, "e4's stale value cleared by the nulled entry")
end)

test("a full packet held across a later frame keeps its escaped values intact", function(env)
	-- the same aliasing hazard, but for a newly-joined client's full packet:
	-- full_packet's hookless values also escape into packet.values and must
	-- survive a later generate_packets call recycling its scratch.
	local s = env.server
	local e1 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:set(e1, s.defs.Health, 5)
	env.frame() -- drain the initial staging so e1 is stable before the joiner arrives

	local c2 = env.make_client()
	local late_joiner = fake_player("LateJoiner")
	s.net.add_client(late_joiner)

	-- generate_packets allocates the pending client and builds its full packet
	-- at the tail of the same call; hold it raw and unreconciled
	local held_full_packet = s.net.generate_packets()[late_joiner]

	-- a later frame recycles the pools without touching e1, so its
	-- already-captured value can only be wrong if the escape was violated
	local e2 = s.world:entity()
	s.world:add(e2, s.net.Replicated)
	s.world:set(e2, s.defs.Health, 50)
	local next_packet = s.net.generate_packets()[late_joiner]

	-- observable before reconciling, like the delta case: the full packet's array must be untouched, and not
	-- reissued to the frame that followed
	local held_values = held_full_packet.values
	expect(held_values ~= nil and held_values[1] ~= nil, "the full packet carries a hookless values array")
	expect(
		next_packet.values ~= nil and next_packet.values[1] ~= held_values[1],
		"the later frame built its own array rather than recycling the escaped one"
	)
	expect_equal(held_values[1][1], 5, "the held array still holds the value it captured")

	c2.net.reconcile_packet(deep_copy(held_full_packet))
	c2.net.reconcile_packet(deep_copy(next_packet))

	local le1 = c2.net.get_client_entity(e1)
	local le2 = c2.net.get_client_entity(e2)
	expect(le1 ~= nil and le2 ~= nil, "late joiner created both entities")
	expect_equal(c2.world:get(le1, c2.defs.Health), 5, "e1's full-packet value survived the later frame")
	expect_equal(c2.world:get(le2, c2.defs.Health), 50, "e2 arrives via the delta that followed")
end)

test("get_packet_frame reads the packet frame carried in the packet's buffer", function(env)
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 1)

	local packet = s.net.generate_packets()[env.player_a]
	expect_equal(
		c.net.get_packet_frame(packet),
		buffer.readu32(packet.data, version_width),
		"matches the u32 just past the leading version byte"
	)
	expect_equal(c.net.get_packet_frame(packet), decode_packet(packet).frame, "agrees with decode_packet's view")
	-- a pure read: the packet's own creation entry must not have been applied along the way
	expect_equal(c.net.get_client_entity(e), nil, "reading the frame reconciles nothing")
end)

test("every packet from one generate_packets call reports the same packet frame", function(env)
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 1) -- public: visible to both A and B in the same call

	-- a pending joiner's full packet is built on its own path at the tail of the same call, so it has to be
	-- stamped with the call's frame too
	local player_c = fake_player("PlayerC")
	s.net.add_client(player_c)

	local packets = s.net.generate_packets()
	local frame_a = c.net.get_packet_frame(packets[env.player_a])
	local frame_b = c.net.get_packet_frame(packets[env.player_b])
	expect_equal(frame_a, frame_b, "A and B's packets share the call's packet frame")
	expect(packets[player_c] ~= nil, "the joiner received a full packet from the same call")
	expect_equal(c.net.get_packet_frame(packets[player_c]), frame_a, "the joiner's full packet shares it too")
end)

test("the packet frame advances between successive generate_packets calls", function(env)
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)

	s.world:set(e, s.defs.Health, 1)
	local first = c.net.get_packet_frame(s.net.generate_packets()[env.player_a])

	s.world:set(e, s.defs.Health, 2)
	local second = c.net.get_packet_frame(s.net.generate_packets()[env.player_a])

	expect_equal(second, first + 1, "the packet frame advances by one per call")

	-- once per call, not once per packet produced: a call with nothing to send returns no packets and still
	-- consumes a frame of its own
	expect_equal(next(s.net.generate_packets()), nil, "the quiet call returns no packets")
	s.world:set(e, s.defs.Health, 3)
	local third = c.net.get_packet_frame(s.net.generate_packets()[env.player_a])
	expect_equal(third, second + 2, "the quiet call consumed a frame")
end)

-- 17) serdes

-- symmetric hooks used by the serdes tests; sizeless (omits size entirely),
-- so packed values ride behind a u16 length prefix even though this
-- particular encode always produces 8 bytes (see f64_static_serdes for the
-- counterpart that declares a static size instead)
local f64_serdes = {
	encode = function(value)
		local buf = buffer.create(8)
		buffer.writef64(buf, 0, value)
		return buf
	end,
	decode = function(buf)
		return buffer.readf64(buf, 0)
	end,
}

-- same encoding as f64_serdes, but size is a plain number instead of omitted:
-- exercises the static-size sizing branch in finalize_section /
-- finalize_grouped_section (size * ids_count, and the wire framing omits the
-- length prefix entirely)
local f64_static_serdes = {
	size = 8,
	encode = function(value)
		local buf = buffer.create(8)
		buffer.writef64(buf, 0, value)
		return buf
	end,
	decode = function(buf)
		return buffer.readf64(buf, 0)
	end,
}

-- variable-size hooks (a tag byte then a u8 or an f64), sizeless since size
-- only ever declares a static byte length -- each value's length prefix on
-- the wire is what keeps a reader aligned across mixed-size values
local varnum_serdes = {
	encode = function(value)
		if value % 1 == 0 and value >= 0 and value < 256 then
			local buf = buffer.create(2)
			buffer.writeu8(buf, 0, 0)
			buffer.writeu8(buf, 1, value)
			return buf
		else
			local buf = buffer.create(9)
			buffer.writeu8(buf, 0, 1)
			buffer.writef64(buf, 1, value)
			return buf
		end
	end,
	decode = function(buf)
		if buffer.readu8(buf, 0) == 0 then
			return buffer.readu8(buf, 1)
		end
		return buffer.readf64(buf, 1)
	end,
}

-- sizeless string hooks (a u32 length prefix, then the bytes): variable-width
-- like varnum_serdes, but able to produce values large enough (multi-KB) to
-- be interesting alongside a small value sharing the same section
local large_string_serdes = {
	encode = function(value)
		local buf = buffer.create(4 + #value)
		buffer.writeu32(buf, 0, #value)
		buffer.writestring(buf, 4, value)
		return buf
	end,
	decode = function(buf)
		local len = buffer.readu32(buf, 0)
		return buffer.readstring(buf, 4, len)
	end,
}

-- buffer-mode hooks (the one-buffer-per-value shape third-party serdes
-- libraries expose): no size call -- encode/decode trade values whole.
-- variable-size, so packed values ride a u16 length prefix on the wire.
local buffer_string_serdes = {
	encode = function(value)
		local buf = buffer.create(#value)
		buffer.writestring(buf, 0, value)
		return buf
	end,
	decode = function(buf)
		return buffer.readstring(buf, 0, buffer.len(buf))
	end,
}

-- same buffer-mode shape, but with a static size: the wire framing omits the
-- length prefix entirely, so every value must encode to exactly 8 bytes.
local buffer_f64_serdes = {
	size = 8,
	encode = function(value)
		local buf = buffer.create(8)
		buffer.writef64(buf, 0, value)
		return buf
	end,
	decode = function(buf)
		return buffer.readf64(buf, 0)
	end,
}

test("serdes hooks pack values inline and round-trip", function(env)
	local s, c = env.server, env.client
	s.world:set(s.defs.Health, s.net.Serdes, f64_serdes)
	c.world:set(c.defs.Health, c.net.Serdes, f64_serdes)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 100)
	local packet = env.sync(env.player_a)

	-- inline sections leave no side array behind; the merged view decodes them
	expect_equal(packet.values, nil, "values packed into the buffer")
	local data = packet.components[s.defs.Health]
	expect(data ~= nil and data.values ~= nil and data.values[1] == 100, "decoded value in the merged view")

	local le = c.net.get_client_entity(e)
	expect_equal(c.world:get(le, c.defs.Health), 100, "client Health decoded via serdes")

	s.world:set(e, s.defs.Health, 55)
	env.sync(env.player_a)
	expect_equal(c.world:get(le, c.defs.Health), 55, "client Health after a serdes-encoded change")
end)

test("serdes on a relation applies to its pairs", function(env)
	local s, c = env.server, env.client
	s.world:set(s.defs.Likes, s.net.Serdes, f64_serdes)
	c.world:set(c.defs.Likes, c.net.Serdes, f64_serdes)

	local e1 = s.world:entity()
	local e2 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(e2, s.net.Replicated)
	s.world:set(e1, pair(s.defs.Likes, e2), 7)
	local packet = env.sync(env.player_a)

	-- no side array: the pair's value packed inline via its relation's hooks,
	-- rather than falling back to the hookless path
	expect_equal(packet.values, nil, "pair values packed into the buffer")
	local data = packet.components[pair(s.defs.Likes, e2)]
	expect(data ~= nil and data.values ~= nil and data.values[1] == 7, "pair value decoded in the merged view")

	local le1 = c.net.get_client_entity(e1)
	local le2 = c.net.get_client_entity(e2)
	expect_equal(c.world:get(le1, pair(c.defs.Likes, le2)), 7, "pair value decoded via the relation's hooks")
end)

test("a late joiner's full packet packs serdes values inline", function(env)
	local s = env.server
	s.world:set(s.defs.Health, s.net.Serdes, f64_serdes)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 12)
	env.frame()

	local c2 = env.make_client()
	c2.world:set(c2.defs.Health, c2.net.Serdes, f64_serdes)
	local player_c = fake_player("PlayerC")
	local packet = env.join(player_c, c2)

	-- anchor the packet as a real full packet first: a player with nothing to receive indexes the blank-packet
	-- fallback, whose values field is nil too, so the absence below would hold vacuously
	expect_equal(#packet.replicated, 1, "the full packet announces the entity")
	-- no side array: the full packet's values packed inline too
	expect_equal(packet.values, nil, "full-packet values packed into the buffer")
	local data = packet.components[s.defs.Health]
	expect(data ~= nil and data.values ~= nil and data.values[1] == 12, "the full packet's value decoded inline")
	local le = c2.net.get_client_entity(e)
	expect(le ~= nil, "the joiner mapped the entity")
	expect_equal(c2.world:get(le, c2.defs.Health), 12, "full packet value decoded via serdes")
end)

test("a sizeless registration's large value round-trips alongside a small value in the same section", function(env)
	local s, c = env.server, env.client
	s.world:set(s.defs.Health, s.net.Serdes, large_string_serdes)
	c.world:set(c.defs.Health, c.net.Serdes, large_string_serdes)

	local e1 = s.world:entity()
	local e2 = s.world:entity()
	local e3 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(e2, s.net.Replicated)
	s.world:add(e3, s.net.Replicated)
	local small_value = "small"
	local large_value = string.rep("x", 6000) -- a multi-KB value, well under the u16 length prefix's 2^16 limit
	s.world:set(e1, s.defs.Health, small_value)
	s.world:set(e2, s.defs.Health, large_value)
	s.world:set(e3, s.defs.Health, small_value)
	local packet = env.sync(env.player_a)

	-- inline sections leave no side array behind
	expect_equal(packet.values, nil, "values packed into the buffer")
	-- the three cells resolve to one mask, so they must ride one section: the scenario under test is a large
	-- value framed between two small ones inside a single value stream, not three streams of one value
	expect_equal(#packet.sections, 1, "all three values ride one section")
	local data = packet.components[s.defs.Health]
	expect(data ~= nil and data.ids ~= nil and #data.ids == 3, "the section carries all three cells")
	expect_equal(
		c.world:get(c.net.get_client_entity(e1), c.defs.Health),
		small_value,
		"small value before the large one"
	)
	expect_equal(c.world:get(c.net.get_client_entity(e2), c.defs.Health), large_value, "large value")
	expect_equal(
		c.world:get(c.net.get_client_entity(e3), c.defs.Health),
		small_value,
		"small value after the large one"
	)
end)

test("Serdes registrations read back via world:get and world:remove clears them", function(env)
	local s, c = env.server, env.client

	s.world:set(s.defs.Health, s.net.Serdes, f64_serdes)
	expect_equal(s.world:get(s.defs.Health, s.net.Serdes), f64_serdes, "getter")
	s.world:remove(s.defs.Health, s.net.Serdes)
	expect_equal(s.world:get(s.defs.Health, s.net.Serdes), nil, "getter after clear")

	-- cleared hooks restore the plain values-array path
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 4)
	local packet = env.sync(env.player_a)
	expect(packet.values ~= nil, "values travel in the plain side array again")
	expect_equal(c.world:get(c.net.get_client_entity(e), c.defs.Health), 4, "default behavior restored")

	-- a pair-specific registration takes precedence over different hooks
	-- registered on the relation itself. a precedence regression that fell
	-- back to the relation's hooks would still round-trip the value
	-- correctly (both sides would fall back the same way), so a spy-wrapped
	-- hook table is used instead of a plain value check to prove the
	-- pair-specific hooks are the ones that actually ran.
	s.world:set(s.defs.Likes, s.net.Serdes, f64_serdes)
	c.world:set(c.defs.Likes, c.net.Serdes, f64_serdes)

	local e1 = s.world:entity()
	local e2 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(e2, s.net.Replicated)
	env.sync(env.player_a)
	local le1 = c.net.get_client_entity(e1)
	local le2 = c.net.get_client_entity(e2)

	local pair_serdes_calls = 0
	local pair_serdes = {
		encode = function(value)
			pair_serdes_calls += 1
			local buf = buffer.create(8)
			buffer.writef64(buf, 0, value)
			return buf
		end,
		decode = function(buf)
			pair_serdes_calls += 1
			return buffer.readf64(buf, 0)
		end,
	}

	-- registered before pair(Likes, e2) has ever been instantiated in either
	-- world: pinning that a pair-specific registration may precede the
	-- concrete pair's first use without tripping the tag guard
	s.world:set(s.defs.Likes, pair(s.net.Serdes, e2), pair_serdes)
	c.world:set(c.defs.Likes, pair(c.net.Serdes, le2), pair_serdes)
	expect_equal(s.world:get(s.defs.Likes, pair(s.net.Serdes, e2)), pair_serdes, "pair-specific getter")

	s.world:set(e1, pair(s.defs.Likes, e2), 250)
	local pair_packet = env.sync(env.player_a)

	local data = pair_packet.components[pair(s.defs.Likes, e2)]
	expect(data ~= nil and data.values ~= nil and data.values[1] == 250, "pair value decoded in the merged view")
	expect_equal(c.world:get(le1, pair(c.defs.Likes, le2)), 250, "pair value decoded via the pair-specific hooks")
	expect(pair_serdes_calls > 0, "the pair-specific hooks ran instead of the relation's")

	s.world:remove(s.defs.Likes, pair(s.net.Serdes, e2))
	expect_equal(s.world:get(s.defs.Likes, pair(s.net.Serdes, e2)), nil, "pair-specific getter after clear")

	-- clearing the registration on both sides puts the pair back on the relation's hooks: the spy staying
	-- untouched is what separates a real fallback from a store that never dropped the entry
	c.world:remove(c.defs.Likes, pair(c.net.Serdes, le2))
	local calls_before_fallback = pair_serdes_calls
	s.world:set(e1, pair(s.defs.Likes, e2), 175)
	env.sync(env.player_a)
	expect_equal(c.world:get(le1, pair(c.defs.Likes, le2)), 175, "the pair round-trips via the relation's hooks")
	expect_equal(pair_serdes_calls, calls_before_fallback, "the cleared pair-specific hooks no longer run")
end)

test("guard: serdes hooks are rejected on tags", function(env)
	local s = env.server
	expect_error(function()
		s.world:set(s.defs.Burning, s.net.Serdes, f64_serdes)
	end, "assigning serdes hooks to a tag", "cannot be assigned to tags")
	expect_equal(s.world:get(s.defs.Burning, s.net.Serdes), nil, "no hooks assigned to the tag")

	-- the pair-specific form is judged through both halves, matching how jecs types a pair's data: a tag
	-- relation paired with a tag target still carries nothing to encode
	expect_error(function()
		s.world:set(s.defs.Targeting, pair(s.net.Serdes, s.defs.Burning), f64_serdes)
	end, "assigning pair-specific hooks to a tag pair", "cannot be assigned to tags")
	expect_equal(
		s.world:get(s.defs.Targeting, pair(s.net.Serdes, s.defs.Burning)),
		nil,
		"no hooks assigned to the tag pair"
	)

	-- the negative control for that second half: pair(tag relation, data target) holds target-typed data, so
	-- it takes hooks like any other data pair
	s.world:set(s.defs.Targeting, pair(s.net.Serdes, s.defs.Health), f64_serdes)
	expect_equal(
		s.world:get(s.defs.Targeting, pair(s.net.Serdes, s.defs.Health)),
		f64_serdes,
		"a tag relation with a data target accepts hooks"
	)
end)

test("inline values without local serdes hooks error on reconcile", function(env)
	local s, c = env.server, env.client
	s.world:set(s.defs.Health, s.net.Serdes, f64_serdes) -- server-only: the client is missing its half

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 3)
	local packet = env.frame()[env.player_a]
	expect_error(function()
		c.net.reconcile_packet(packet)
	end, "reconciling inline values without hooks", "no serdes hooks are assigned")
end)

test("a static-size serdes registration packs values inline and round-trips", function(env)
	local s, c = env.server, env.client
	s.world:set(s.defs.Health, s.net.Serdes, f64_static_serdes)
	c.world:set(c.defs.Health, c.net.Serdes, f64_static_serdes)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 100)
	local packet = env.sync(env.player_a)

	-- inline sections leave no side array behind; the merged view decodes them
	expect_equal(packet.values, nil, "values packed into the buffer")
	local data = packet.components[s.defs.Health]
	expect(data ~= nil and data.values ~= nil and data.values[1] == 100, "decoded value in the merged view")

	local le = c.net.get_client_entity(e)
	expect_equal(c.world:get(le, c.defs.Health), 100, "client Health decoded via a static-size serdes")

	s.world:set(e, s.defs.Health, 55)
	env.sync(env.player_a)
	expect_equal(c.world:get(le, c.defs.Health), 55, "client Health after a static-size serdes-encoded change")
end)

test(
	"a static size and a sizeless registration share one packet's sizing pass without corrupting either section",
	function(env)
		local s, c = env.server, env.client
		s.world:set(s.defs.Health, s.net.Serdes, f64_static_serdes)
		c.world:set(c.defs.Health, c.net.Serdes, f64_static_serdes)
		s.world:set(s.defs.Inventory, s.net.Serdes, varnum_serdes)
		c.world:set(c.defs.Inventory, c.net.Serdes, varnum_serdes)

		local e = s.world:entity()
		s.world:add(e, s.net.Replicated)
		s.world:set(e, s.defs.Health, 100) -- static size
		s.world:set(e, s.defs.Inventory, 1000.5) -- sizeless, the varnum tag-byte-plus-f64 branch
		local packet = env.sync(env.player_a)

		expect_equal(packet.values, nil, "both sections packed inline, no side array")
		local health_data = packet.components[s.defs.Health]
		expect(
			health_data ~= nil and health_data.values ~= nil and health_data.values[1] == 100,
			"the static-size section decoded correctly"
		)
		local inventory_data = packet.components[s.defs.Inventory]
		expect(
			inventory_data ~= nil and inventory_data.values ~= nil and inventory_data.values[1] == 1000.5,
			"the sizeless section decoded correctly alongside it"
		)

		local le = c.net.get_client_entity(e)
		expect_equal(c.world:get(le, c.defs.Health), 100, "client Health via the static-size serdes")
		expect_equal(c.world:get(le, c.defs.Inventory), 1000.5, "client Inventory via the sizeless serdes")
	end
)

test("buffer-mode serdes values with varying lengths round-trip behind their length prefixes", function(env)
	local s, c = env.server, env.client
	s.world:set(s.defs.Health, s.net.Serdes, buffer_string_serdes)
	c.world:set(c.defs.Health, c.net.Serdes, buffer_string_serdes)

	local e1 = s.world:entity()
	local e2 = s.world:entity()
	local e3 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(e2, s.net.Replicated)
	s.world:add(e3, s.net.Replicated)
	s.world:set(e1, s.defs.Health, "short")
	s.world:set(e2, s.defs.Health, "a much longer value than the others")
	s.world:set(e3, s.defs.Health, "tiny")
	local packet = env.sync(env.player_a)

	-- inline sections leave no side array behind; a regression to the hookless
	-- side-array path would bypass the length-prefix framing this test exercises
	expect_equal(packet.values, nil, "values packed into the buffer")
	expect_equal(c.world:get(c.net.get_client_entity(e1), c.defs.Health), "short", "small value")
	expect_equal(
		c.world:get(c.net.get_client_entity(e2), c.defs.Health),
		"a much longer value than the others",
		"large value"
	)
	expect_equal(c.world:get(c.net.get_client_entity(e3), c.defs.Health), "tiny", "small value after a large one")
end)

test("a static-size buffer-mode serdes registration omits the wire length prefix and round-trips", function(env)
	local s, c = env.server, env.client
	s.world:set(s.defs.Health, s.net.Serdes, buffer_f64_serdes)
	c.world:set(c.defs.Health, c.net.Serdes, buffer_f64_serdes)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 100)
	local packet = env.sync(env.player_a)

	-- inline sections leave no side array behind; the merged view decodes them
	expect_equal(packet.values, nil, "values packed into the buffer")
	local data = packet.components[s.defs.Health]
	expect(data ~= nil and data.values ~= nil and data.values[1] == 100, "decoded value in the merged view")

	-- the omission itself is invisible to a round-trip -- writing a u16 prefix and reading it back again
	-- would round-trip just as well -- so count the section's bytes. with one 8-byte value in the packet's
	-- only section, the layout (see src/wire.luau) allows exactly flags + section length + component +
	-- ids count + one id + the bare value: two bytes less than a per-value prefix would cost
	local buf = packet.data
	local _, offset, unreplicated_count, replicated_count, names_count = read_packet_header(buf)
	offset += unreplicated_count * id_width + replicated_count * gen_id_width
	for _ = 1, names_count do
		local _, _, next_offset = read_name(buf, offset)
		offset = next_offset
	end
	local _, section_end = read_section_header(buf, offset)
	expect_equal(section_end, buffer.len(buf), "the value section is the packet's only section")
	expect_equal(section_end - offset, 1 + 2 + id_width + 2 + id_width + 8, "the value rides with no prefix")

	local le = c.net.get_client_entity(e)
	expect_equal(c.world:get(le, c.defs.Health), 100, "client Health decoded via a static-size buffer-mode serdes")

	s.world:set(e, s.defs.Health, 55)
	env.sync(env.player_a)
	expect_equal(c.world:get(le, c.defs.Health), 55, "client Health after a static-size buffer-mode change")
end)

test(
	"guard: a serdes registration missing encode/decode hooks errors, is removed, and falls back to hookless",
	function(env)
		local s, c = env.server, env.client
		-- the removed cursor shape: ser/des instead of encode/decode
		local cursor_shape_serdes = {
			ser = function(buf, offset, value)
				buffer.writef64(buf, offset, value)
				return 8
			end,
			des = function(buf, offset)
				return buffer.readf64(buf, offset), offset + 8
			end,
		}

		expect_error(function()
			s.world:set(s.defs.Health, s.net.Serdes, cursor_shape_serdes)
		end, "assigning a registration missing encode/decode hooks", "must provide encode and decode hooks")
		expect_equal(s.world:get(s.defs.Health, s.net.Serdes), nil, "no hooks assigned when encode/decode are missing")

		-- a subsequent packet for the component must still travel, hookless, via
		-- the plain values side array
		local e = s.world:entity()
		s.world:add(e, s.net.Replicated)
		s.world:set(e, s.defs.Health, 9)
		local packet = env.sync(env.player_a)
		expect(packet.values ~= nil, "hookless values travel in the side array")
		local le = c.net.get_client_entity(e)
		expect_equal(c.world:get(le, c.defs.Health), 9, "value round-trips hookless despite the rejected registration")
	end
)

test(
	"guard: a serdes registration whose size is a function errors, is removed, and falls back to hookless",
	function(env)
		local s, c = env.server, env.client
		-- a registration mistakenly carrying the removed function-size shape
		-- instead of a static byte length
		local function_size_serdes = {
			size = function(value)
				return 8
			end,
			encode = function(value)
				local buf = buffer.create(8)
				buffer.writef64(buf, 0, value)
				return buf
			end,
			decode = function(buf)
				return buffer.readf64(buf, 0)
			end,
		}

		expect_error(function()
			s.world:set(s.defs.Health, s.net.Serdes, function_size_serdes)
		end, "a function-size registration", "size must be a static byte length")
		expect_equal(s.world:get(s.defs.Health, s.net.Serdes), nil, "no hooks assigned when size is a function")

		-- a subsequent packet for the component must still travel, hookless, via
		-- the plain values side array
		local e = s.world:entity()
		s.world:add(e, s.net.Replicated)
		s.world:set(e, s.defs.Health, 9)
		local packet = env.sync(env.player_a)
		expect(packet.values ~= nil, "hookless values travel in the side array")
		local le = c.net.get_client_entity(e)
		expect_equal(c.world:get(le, c.defs.Health), 9, "value round-trips hookless despite the rejected registration")
	end
)

test("an oversized prefixed buffer-mode value is pruned with a warning instead of erroring", function(env)
	local s, c = env.server, env.client
	local oversized_serdes = {
		encode = function(value)
			return buffer.create(0x10000)
		end,
		decode = function(buf)
			return buf
		end,
	}
	s.world:set(s.defs.Health, s.net.Serdes, oversized_serdes)
	c.world:set(c.defs.Health, c.net.Serdes, oversized_serdes)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, "encode ignores this and always returns an oversized buffer")
	-- the declaration matches the contract report the warning carries as its tail, not just the containment
	-- prefix: any other encode failure would satisfy the prefix, and this test exists for the u16 limit
	expected_warning("serdes values must encode to fewer than 2^16 bytes")
	env.sync(env.player_a)

	local le = c.net.get_client_entity(e)
	expect(le ~= nil, "the entity still replicates despite the poisoned value")
	expect_equal(c.world:get(le, c.defs.Health), nil, "the oversized value never reached the client")
end)

test(
	"a static-size buffer-mode value that mismatches the declared size is pruned with a warning instead of erroring",
	function(env)
		local s, c = env.server, env.client
		local mismatched_serdes = {
			size = 8,
			encode = function(value)
				return buffer.create(4) -- declared size is 8, this always encodes to 4
			end,
			decode = function(buf)
				return buf
			end,
		}
		s.world:set(s.defs.Health, s.net.Serdes, mismatched_serdes)
		c.world:set(c.defs.Health, c.net.Serdes, mismatched_serdes)

		local e = s.world:entity()
		s.world:add(e, s.net.Replicated)
		s.world:set(e, s.defs.Health, "encode ignores this and always mismatches the declared size")
		-- the declaration matches the contract report the warning carries as its tail, not just the
		-- containment prefix: this test exists for the static-size contract specifically
		expected_warning("serdes hooks with a static size must encode exactly that size")
		env.sync(env.player_a)

		local le = c.net.get_client_entity(e)
		expect(le ~= nil, "the entity still replicates despite the poisoned value")
		expect_equal(c.world:get(le, c.defs.Health), nil, "the mismatched-size value never reached the client")
	end
)

test(
	"an unmapped entity's buffer-mode value is skipped by its length prefix, keeping a following mapped entity's value aligned",
	function(env)
		local s, c = env.server, env.client
		-- the server side stays untracked (its decode only feeds the harness's
		-- record view, decoded for every registered client regardless of local
		-- mapping); only the client's own decode calls are under test here
		local client_decode_calls = {}
		local client_tracking_serdes = {
			encode = buffer_string_serdes.encode,
			decode = function(buf)
				local value = buffer_string_serdes.decode(buf)
				table.insert(client_decode_calls, value)
				return value
			end,
		}
		s.world:set(s.defs.Health, s.net.Serdes, buffer_string_serdes)
		c.world:set(c.defs.Health, c.net.Serdes, client_tracking_serdes)

		-- a normally-reconciled entity, mapped up front
		local mapped = s.world:entity()
		s.world:add(mapped, s.net.Replicated)
		s.world:set(mapped, s.defs.Health, "initial-mapped-value")
		env.sync(env.player_a)
		local le_mapped = c.net.get_client_entity(mapped)
		expect(le_mapped ~= nil, "the mapped entity has a client entity before the alignment frame")
		table.clear(client_decode_calls) -- only the alignment frame's decode calls matter below

		-- an entity that becomes visible and gets a value in a frame that is
		-- drained but never reconciled on the client -- standing in for a
		-- dropped packet -- so the server's per-client state advances (this
		-- entity is no longer announced as newly-replicated) while the client
		-- never learns of it
		local unmapped = s.world:entity()
		s.world:add(unmapped, s.net.Replicated)
		s.world:set(unmapped, s.defs.Health, "initial-unmapped-value")
		env.frame() -- drained and discarded

		expect_equal(c.net.get_client_entity(unmapped), nil, "precondition: the dropped-packet entity has no mapping")

		-- both cells change in the same frame, the unmapped entity staged
		-- first so its skipped value precedes the mapped entity's in the
		-- section's ids list
		s.world:set(unmapped, s.defs.Health, "second-unmapped-value")
		s.world:set(mapped, s.defs.Health, "second-mapped-value")
		local packet = env.sync(env.player_a)

		local data = packet.components[s.defs.Health]
		expect(
			data ~= nil
				and data.values ~= nil
				and data.values[1] == "second-unmapped-value"
				and data.values[2] == "second-mapped-value",
			"the wire carries both values in staging order, decoded here via the server's own hooks"
		)

		expect_equal(c.net.get_client_entity(unmapped), nil, "the unmapped entity still has no client mapping")
		expect_equal(
			c.world:get(le_mapped, c.defs.Health),
			"second-mapped-value",
			"the mapped entity's value decoded correctly despite the preceding skip"
		)
		expect_equal(
			#client_decode_calls,
			1,
			"decode ran exactly once on the client, only for the mapped entity's value"
		)
		expect_equal(
			client_decode_calls[1],
			"second-mapped-value",
			"decode's one call received the mapped entity's value, not the skipped one"
		)
	end
)

test(
	"a throwing encode hook prunes only the poisoned entity's value, leaving the rest of the frame intact",
	function(env)
		local s, c = env.server, env.client
		local poison = "poison"
		local throwing_serdes = {
			encode = function(value)
				if value == poison then
					error("simulated encode failure")
				end
				local buf = buffer.create(8)
				buffer.writef64(buf, 0, value)
				return buf
			end,
			decode = function(buf)
				return buffer.readf64(buf, 0)
			end,
		}
		s.world:set(s.defs.Health, s.net.Serdes, throwing_serdes)
		c.world:set(c.defs.Health, c.net.Serdes, throwing_serdes)

		local healthy = s.world:entity()
		local poisoned = s.world:entity()
		s.world:add(healthy, s.net.Replicated)
		s.world:add(poisoned, s.net.Replicated)
		s.world:set(healthy, s.defs.Health, 42)
		s.world:set(poisoned, s.defs.Health, poison)
		-- Inventory has no serdes hooks and drafts its own hookless section, so it stands in for
		-- "everything else in the frame" alongside the poisoned Health section
		s.world:set(healthy, s.defs.Inventory, "healthy-inventory")
		s.world:set(poisoned, s.defs.Inventory, "poisoned-inventory")

		expected_warning("a serdes encode hook threw while encoding")
		env.sync(env.player_a)

		local le_healthy = c.net.get_client_entity(healthy)
		local le_poisoned = c.net.get_client_entity(poisoned)
		expect_equal(c.world:get(le_healthy, c.defs.Health), 42, "the surviving entity's value reconciled")
		expect_equal(
			c.world:get(le_poisoned, c.defs.Health),
			nil,
			"the poisoned entity's value never reached the client"
		)
		expect_equal(
			c.world:get(le_healthy, c.defs.Inventory),
			"healthy-inventory",
			"an unrelated component on the healthy entity still reconciled"
		)
		expect_equal(
			c.world:get(le_poisoned, c.defs.Inventory),
			"poisoned-inventory",
			"an unrelated component on the poisoned entity still reconciled despite its Health value being poisoned"
		)
	end
)

test("a pruned value self-heals once its cell is set again", function(env)
	local s, c = env.server, env.client
	local poison = "poison"
	local throwing_serdes = {
		encode = function(value)
			if value == poison then
				error("simulated encode failure")
			end
			local buf = buffer.create(8)
			buffer.writef64(buf, 0, value)
			return buf
		end,
		decode = function(buf)
			return buffer.readf64(buf, 0)
		end,
	}
	s.world:set(s.defs.Health, s.net.Serdes, throwing_serdes)
	c.world:set(c.defs.Health, c.net.Serdes, throwing_serdes)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, poison)

	expected_warning("a serdes encode hook threw while encoding")
	env.sync(env.player_a)
	local le = c.net.get_client_entity(e)
	expect_equal(c.world:get(le, c.defs.Health), nil, "the poisoned value never reached the client")

	-- the server still counts a pruned cell as sent, so setting it again stages a fresh value
	-- that ships normally on the next frame
	s.world:set(e, s.defs.Health, 99)
	env.sync(env.player_a)
	expect_equal(c.world:get(le, c.defs.Health), 99, "the fixed value self-healed on the next set")
end)

test("a removal reconciles even when a poisoned value shares its section", function(env)
	local s, c = env.server, env.client
	local poison = "poison"
	local throwing_serdes = {
		encode = function(value)
			if value == poison then
				error("simulated encode failure")
			end
			local buf = buffer.create(8)
			buffer.writef64(buf, 0, value)
			return buf
		end,
		decode = function(buf)
			return buffer.readf64(buf, 0)
		end,
	}
	s.world:set(s.defs.Health, s.net.Serdes, throwing_serdes)
	c.world:set(c.defs.Health, c.net.Serdes, throwing_serdes)

	local removed_e = s.world:entity()
	local poisoned_e = s.world:entity()
	s.world:add(removed_e, s.net.Replicated)
	s.world:add(poisoned_e, s.net.Replicated)
	s.world:set(removed_e, s.defs.Health, 1)
	env.sync(env.player_a)
	local le_removed = c.net.get_client_entity(removed_e)
	local le_poisoned = c.net.get_client_entity(poisoned_e)
	expect_equal(c.world:has(le_removed, c.defs.Health), true, "precondition: the removal target had the component")

	s.world:remove(removed_e, s.defs.Health)
	s.world:set(poisoned_e, s.defs.Health, poison)
	expected_warning("a serdes encode hook threw while encoding")
	local packet = env.sync(env.player_a)

	-- the two cells must genuinely share a section, or the salvage never touches the draft the removal rides
	-- and the test says nothing about the sharing its name claims
	expect_equal(#packet.sections, 1, "the removal rides the salvaged section")
	expect_equal(c.world:has(le_removed, c.defs.Health), false, "the removal reconciled despite sharing a section")
	expect_equal(c.world:get(le_poisoned, c.defs.Health), nil, "the poisoned value never reached the client")
end)

test("a poisoned run in a grouped pair section is pruned while the healthy run reconciles", function(env)
	local s, c = env.server, env.client
	local poison = -1
	local throwing_serdes = {
		encode = function(value)
			if value == poison then
				error("simulated encode failure")
			end
			local buf = buffer.create(8)
			buffer.writef64(buf, 0, value)
			return buf
		end,
		decode = function(buf)
			return buffer.readf64(buf, 0)
		end,
	}
	s.world:set(s.defs.Likes, s.net.Serdes, throwing_serdes)
	c.world:set(c.defs.Likes, c.net.Serdes, throwing_serdes)

	local e1 = s.world:entity()
	local t1 = s.world:entity()
	local t2 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(t1, s.net.Replicated)
	s.world:add(t2, s.net.Replicated)
	s.world:set(e1, pair(s.defs.Likes, t1), 4.5)
	s.world:set(e1, pair(s.defs.Likes, t2), poison)

	expected_warning("a serdes encode hook threw while encoding")
	local packet = env.sync(env.player_a)

	-- the two targets must genuinely share one grouped section: two plain sections would prune one section
	-- whole and leave the other alone, proving nothing about runs. decode_packet's per-run view erases the
	-- distinction (see section 21's raw_section_flags), so the section flags are read here directly
	local grouped_count = 0
	local data = packet.data
	local _, offset, unreplicated_count, replicated_count, names_count = read_packet_header(data)
	offset += unreplicated_count * id_width + replicated_count * gen_id_width
	for _ = 1, names_count do
		local _, _, next_offset = read_name(data, offset)
		offset = next_offset
	end
	while offset < buffer.len(data) do
		local flags, next_offset = read_section_header(data, offset)
		if bit32.band(flags, flag_pair) ~= 0 and bit32.band(flags, flag_runs) ~= 0 then
			grouped_count += 1
		end
		offset = next_offset
	end
	expect_equal(grouped_count, 1, "both targets' runs share one grouped section")

	local le1 = c.net.get_client_entity(e1)
	local lt1 = c.net.get_client_entity(t1)
	local lt2 = c.net.get_client_entity(t2)
	expect_equal(c.world:get(le1, pair(c.defs.Likes, lt1)), 4.5, "the healthy run reconciled")
	expect_equal(c.world:get(le1, pair(c.defs.Likes, lt2)), nil, "the poisoned run never reached the client")
end)

test("a joiner's full packet prunes a poisoned value without erroring", function(env)
	local s = env.server
	local poison = "poison"
	local throwing_serdes = {
		encode = function(value)
			if value == poison then
				error("simulated encode failure")
			end
			local buf = buffer.create(8)
			buffer.writef64(buf, 0, value)
			return buf
		end,
		decode = function(buf)
			return buffer.readf64(buf, 0)
		end,
	}
	s.world:set(s.defs.Health, s.net.Serdes, throwing_serdes)

	local healthy = s.world:entity()
	local poisoned = s.world:entity()
	s.world:add(healthy, s.net.Replicated)
	s.world:add(poisoned, s.net.Replicated)
	s.world:set(healthy, s.defs.Health, 10)

	local c2 = env.make_client()
	c2.world:set(c2.defs.Health, c2.net.Serdes, throwing_serdes)
	local player_c = fake_player("PlayerC")
	s.net.add_client(player_c)

	-- the poisoned value lands both in the existing players' delta (a genuine staged change) and
	-- in the joiner's independently-walked full packet, so the guard fires twice in this one
	-- generate_packets call
	s.world:set(poisoned, s.defs.Health, poison)
	expected_warning("a serdes encode hook threw while encoding")
	expected_warning("a serdes encode hook threw while encoding")
	local packets = s.net.generate_packets()
	c2.net.reconcile_packet(packets[player_c])

	local le_healthy = c2.net.get_client_entity(healthy)
	local le_poisoned = c2.net.get_client_entity(poisoned)
	expect(le_healthy ~= nil and le_poisoned ~= nil, "both entities still replicate to the joiner")
	expect_equal(c2.world:get(le_healthy, c2.defs.Health), 10, "the healthy value reconciled in the full packet")
	expect_equal(c2.world:get(le_poisoned, c2.defs.Health), nil, "the poisoned value never reached the joiner")
end)

test("an encode hook returning a non-buffer value is pruned the same way, without erroring", function(env)
	local s, c = env.server, env.client
	local bad_return_serdes = {
		encode = function(value)
			return "not a buffer" -- violates the encode contract
		end,
		decode = function(buf)
			return buffer.readf64(buf, 0)
		end,
	}
	s.world:set(s.defs.Health, s.net.Serdes, bad_return_serdes)
	c.world:set(c.defs.Health, c.net.Serdes, bad_return_serdes)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 5)

	-- the initial measure dies on the raw buffer.len; only the salvage's own type check names the contract,
	-- so this substring also pins that the reported error is the salvage's rather than the measure's
	expected_warning("serdes encode hooks must return a buffer")
	env.sync(env.player_a)

	local le = c.net.get_client_entity(e)
	expect(le ~= nil, "the entity still replicates despite the poisoned value")
	expect_equal(c.world:get(le, c.defs.Health), nil, "the non-buffer-returning value never reached the client")
end)

test("a hook that fails the final re-measure strips the section's value sends wholesale", function(env)
	local s, c = env.server, env.client
	local poison = -1
	local poison_calls = 0
	-- the poisoned value throws on the initial measure (call 1) and again on the re-measure after a
	-- successful salvage re-encode (call 2) -- nondeterministic enough to defeat the per-value salvage, so
	-- the whole section's value sends are stripped. the healthy value sharing the section is what makes the
	-- strip observable: a per-value prune would have kept it.
	local flaky_serdes = {
		encode = function(value)
			if value == poison then
				poison_calls += 1
				if poison_calls % 2 == 1 then
					error(`simulated nondeterministic failure on call {poison_calls}`)
				end
			end
			local buf = buffer.create(8)
			buffer.writef64(buf, 0, value)
			return buf
		end,
		decode = function(buf)
			return buffer.readf64(buf, 0)
		end,
	}
	s.world:set(s.defs.Health, s.net.Serdes, flaky_serdes)
	c.world:set(c.defs.Health, c.net.Serdes, flaky_serdes)

	local healthy = s.world:entity()
	local poisoned = s.world:entity()
	s.world:add(healthy, s.net.Replicated)
	s.world:add(poisoned, s.net.Replicated)
	s.world:set(healthy, s.defs.Health, 7)
	s.world:set(poisoned, s.defs.Health, poison)

	-- both values are reported dropped: a salvage that pruned per value would have reported one
	expected_warning("2 value(s) were dropped from this frame's packets")
	env.sync(env.player_a)

	expect_equal(
		poison_calls,
		3,
		"the initial measure, the salvage re-encode, and the failed re-measure each encoded the poisoned value"
	)
	local le_healthy = c.net.get_client_entity(healthy)
	local le_poisoned = c.net.get_client_entity(poisoned)
	expect(le_healthy ~= nil and le_poisoned ~= nil, "both entities still replicate despite the wholesale strip")
	expect_equal(
		c.world:get(le_poisoned, c.defs.Health),
		nil,
		"the poisoned value was stripped after the re-measure also failed"
	)
	expect_equal(
		c.world:get(le_healthy, c.defs.Health),
		nil,
		"the value that encoded cleanly was stripped with it -- the strip is wholesale, not per value"
	)
end)

-- the client-side counterpart to the encode salvage tests above: apply_lists (reconcile_packet) runs
-- decode under pcall, so a throwing hook skips only its own value -- the framing already knows every
-- value's length before decoding, keeping the stream aligned -- with one warning per affected list
-- rather than an unwind that would lose the rest of the packet.

test("a nulled entry and a removal reconcile even when a poisoned decode shares their section", function(env)
	local s, c = env.server, env.client
	local poison = -1
	local throwing_decode_serdes = {
		encode = function(value)
			local buf = buffer.create(8)
			buffer.writef64(buf, 0, value)
			return buf
		end,
		decode = function(buf)
			local value = buffer.readf64(buf, 0)
			if value == poison then
				error("simulated decode failure")
			end
			return value
		end,
	}
	s.world:set(s.defs.Health, s.net.Serdes, throwing_decode_serdes)
	c.world:set(c.defs.Health, c.net.Serdes, throwing_decode_serdes)

	local nulled_e = s.world:entity()
	local removed_e = s.world:entity()
	local poisoned_e = s.world:entity()
	s.world:add(nulled_e, s.net.Replicated)
	s.world:add(removed_e, s.net.Replicated)
	s.world:add(poisoned_e, s.net.Replicated)
	s.world:set(nulled_e, s.defs.Health, 1)
	s.world:set(removed_e, s.defs.Health, 2)
	-- the poisoned cell arrives healthy first, so the skip below has a previous value to leave in place
	s.world:set(poisoned_e, s.defs.Health, 3)
	env.sync(env.player_a)
	local le_nulled = c.net.get_client_entity(nulled_e)
	local le_removed = c.net.get_client_entity(removed_e)
	local le_poisoned = c.net.get_client_entity(poisoned_e)
	expect_equal(c.world:has(le_removed, c.defs.Health), true, "precondition: the removal target had the component")
	expect_equal(c.world:get(le_poisoned, c.defs.Health), 3, "precondition: the poisoned cell holds a healthy value")

	s.world:remove(nulled_e, s.defs.Health)
	s.world:add(nulled_e, s.defs.Health) -- coalesces to a nulled entry, not a removal
	s.world:remove(removed_e, s.defs.Health)
	s.world:set(poisoned_e, s.defs.Health, poison)
	-- the harness's frame()/sync helpers decode every value through the same hooks to build their
	-- assertion view, which would re-throw the poisoned decode outside of reconcile_packet's own pcall;
	-- go straight to the raw packet instead, exactly as reconcile_packet receives it in production
	expected_warning("were skipped and their cells will not update")
	local packet = s.net.generate_packets()[env.player_a]
	c.net.reconcile_packet(deep_copy(packet))

	expect_equal(c.world:has(le_nulled, c.defs.Health), true, "the nulled entry reconciled despite sharing a section")
	expect_equal(c.world:get(le_nulled, c.defs.Health), nil, "the nulled entry's value cleared to nil")
	expect_equal(c.world:has(le_removed, c.defs.Health), false, "the removal reconciled despite sharing a section")
	expect_equal(
		c.world:get(le_poisoned, c.defs.Health),
		3,
		"the skipped value left the poisoned cell holding exactly what it held before"
	)
end)

test(
	"entity creates and deletes, plus a later hookless section, reconcile normally despite a poisoned decode elsewhere in the packet",
	function(env)
		local s, c = env.server, env.client
		local poison = -1
		local throwing_decode_serdes = {
			encode = function(value)
				local buf = buffer.create(8)
				buffer.writef64(buf, 0, value)
				return buf
			end,
			decode = function(buf)
				local value = buffer.readf64(buf, 0)
				if value == poison then
					error("simulated decode failure")
				end
				return value
			end,
		}
		s.world:set(s.defs.Health, s.net.Serdes, throwing_decode_serdes)
		c.world:set(c.defs.Health, c.net.Serdes, throwing_decode_serdes)

		local deleted_e = s.world:entity()
		local poisoned_e = s.world:entity()
		s.world:add(deleted_e, s.net.Replicated)
		s.world:add(poisoned_e, s.net.Replicated)
		env.sync(env.player_a)
		local le_deleted = c.net.get_client_entity(deleted_e)
		expect(le_deleted ~= nil, "precondition: the entity to be deleted has a client entity")

		local created_e = s.world:entity()
		s.world:add(created_e, s.net.Replicated)
		s.world:delete(deleted_e)
		s.world:set(poisoned_e, s.defs.Health, poison)
		s.world:set(poisoned_e, s.defs.Inventory, "later-section-value")
		-- bypass env.sync/frame() here too (see the comment in the nulled-entry test above); the harness's
		-- own decode of the poisoned value would throw before reconcile_packet's pcall ever gets a chance
		expected_warning("were skipped and their cells will not update")
		local packet = s.net.generate_packets()[env.player_a]
		c.net.reconcile_packet(deep_copy(packet))

		expect_equal(c.world:contains(le_deleted), false, "the deletion reconciled despite a poisoned value elsewhere")
		local le_created = c.net.get_client_entity(created_e)
		expect(le_created ~= nil, "the creation reconciled despite a poisoned value elsewhere")
		local le_poisoned = c.net.get_client_entity(poisoned_e)
		expect_equal(
			c.world:get(le_poisoned, c.defs.Inventory),
			"later-section-value",
			"a later hookless section still reconciled despite the earlier section's poisoned decode"
		)
	end
)

test("a skipped decode value self-heals once the server sets the cell to a value that decodes cleanly", function(env)
	local s, c = env.server, env.client
	local poison = -1
	local throwing_decode_serdes = {
		encode = function(value)
			local buf = buffer.create(8)
			buffer.writef64(buf, 0, value)
			return buf
		end,
		decode = function(buf)
			local value = buffer.readf64(buf, 0)
			if value == poison then
				error("simulated decode failure")
			end
			return value
		end,
	}
	s.world:set(s.defs.Health, s.net.Serdes, throwing_decode_serdes)
	c.world:set(c.defs.Health, c.net.Serdes, throwing_decode_serdes)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, poison)

	-- bypass env.sync/frame() (see the comment in the nulled-entry test above); the harness's own
	-- decode of the poisoned value would throw before reconcile_packet's pcall ever gets a chance
	expected_warning("were skipped and their cells will not update")
	c.net.reconcile_packet(deep_copy(s.net.generate_packets()[env.player_a]))
	local le = c.net.get_client_entity(e)
	expect(le ~= nil, "the entity still replicates despite the poisoned initial value")
	expect_equal(c.world:has(le, c.defs.Health), false, "the poisoned value never reached the client")

	s.world:set(e, s.defs.Health, 99)
	env.sync(env.player_a)
	expect_equal(c.world:get(le, c.defs.Health), 99, "the fixed value self-healed on the next set")
end)

test("a decode failure on an entity's initial value does not add the component to the client entity", function(env)
	local s, c = env.server, env.client
	local poison = -1
	local throwing_decode_serdes = {
		encode = function(value)
			local buf = buffer.create(8)
			buffer.writef64(buf, 0, value)
			return buf
		end,
		decode = function(buf)
			local value = buffer.readf64(buf, 0)
			if value == poison then
				error("simulated decode failure")
			end
			return value
		end,
	}
	s.world:set(s.defs.Health, s.net.Serdes, throwing_decode_serdes)
	c.world:set(c.defs.Health, c.net.Serdes, throwing_decode_serdes)

	local healthy = s.world:entity()
	local poisoned = s.world:entity()
	s.world:add(healthy, s.net.Replicated)
	s.world:add(poisoned, s.net.Replicated)
	s.world:set(healthy, s.defs.Health, 1)
	s.world:set(poisoned, s.defs.Health, poison)

	-- bypass env.sync/frame() (see the comment in the nulled-entry test above); the harness's own
	-- decode of the poisoned value would throw before reconcile_packet's pcall ever gets a chance
	expected_warning("were skipped and their cells will not update")
	c.net.reconcile_packet(deep_copy(s.net.generate_packets()[env.player_a]))

	local le_healthy = c.net.get_client_entity(healthy)
	local le_poisoned = c.net.get_client_entity(poisoned)
	expect_equal(c.world:has(le_healthy, c.defs.Health), true, "the healthy entity's membership add applied normally")
	expect_equal(c.world:get(le_healthy, c.defs.Health), 1, "the healthy entity's value decoded normally")
	expect_equal(
		c.world:has(le_poisoned, c.defs.Health),
		false,
		"the poisoned entity's membership add never happened -- the component was not added without a value"
	)
end)

test(
	"a registered changed override is not invoked for a value that fails to decode, but still runs for other values",
	function(env)
		local s, c = env.server, env.client
		local poison = -1
		local throwing_decode_serdes = {
			encode = function(value)
				local buf = buffer.create(8)
				buffer.writef64(buf, 0, value)
				return buf
			end,
			decode = function(buf)
				local value = buffer.readf64(buf, 0)
				if value == poison then
					error("simulated decode failure")
				end
				return value
			end,
		}
		s.world:set(s.defs.Health, s.net.Serdes, throwing_decode_serdes)
		c.world:set(c.defs.Health, c.net.Serdes, throwing_decode_serdes)

		local healthy = s.world:entity()
		local poisoned = s.world:entity()
		s.world:add(healthy, s.net.Replicated)
		s.world:add(poisoned, s.net.Replicated)

		local calls = {}
		c.net.set_changed_override(c.defs.Health, function(entity, value)
			table.insert(calls, { entity = entity, value = value })
		end)

		s.world:set(healthy, s.defs.Health, 42)
		s.world:set(poisoned, s.defs.Health, poison)
		-- bypass env.sync/frame() (see the comment in the nulled-entry test above); the harness's own
		-- decode of the poisoned value would throw before reconcile_packet's pcall ever gets a chance
		expected_warning("were skipped and their cells will not update")
		c.net.reconcile_packet(deep_copy(s.net.generate_packets()[env.player_a]))

		local le_healthy = c.net.get_client_entity(healthy)
		expect_equal(#calls, 1, "the override ran exactly once, for the value that decoded cleanly")
		expect_equal(calls[1].entity, le_healthy, "the override's one call was for the healthy entity")
		expect_equal(calls[1].value, 42, "the override received the decoded value")
	end
)

test(
	"a throwing decode hook on a static-size registration skips only its own value, keeping a following value aligned",
	function(env)
		local s, c = env.server, env.client
		local poison = -1
		local static_throwing_decode_serdes = {
			size = 8,
			encode = function(value)
				local buf = buffer.create(8)
				buffer.writef64(buf, 0, value)
				return buf
			end,
			decode = function(buf)
				local value = buffer.readf64(buf, 0)
				if value == poison then
					error("simulated decode failure")
				end
				return value
			end,
		}
		s.world:set(s.defs.Health, s.net.Serdes, static_throwing_decode_serdes)
		c.world:set(c.defs.Health, c.net.Serdes, static_throwing_decode_serdes)

		-- the healthy cell exists (and has already been sent) before the poisoned one is added, which fixes
		-- their order inside the section's value list: newly-visible cells resolve ahead of plain value
		-- changes, so the poisoned value is written first and the healthy one genuinely follows it
		local healthy = s.world:entity()
		s.world:add(healthy, s.net.Replicated)
		s.world:set(healthy, s.defs.Health, 7)
		env.sync(env.player_a)
		local le_healthy = c.net.get_client_entity(healthy)
		expect_equal(c.world:get(le_healthy, c.defs.Health), 7, "precondition: the healthy cell arrived first")

		local poisoned = s.world:entity()
		s.world:add(poisoned, s.net.Replicated)
		s.world:set(poisoned, s.defs.Health, poison)
		s.world:set(healthy, s.defs.Health, 8)

		-- bypass env.sync/frame() (see the comment in the nulled-entry test above); the harness's own
		-- decode of the poisoned value would throw before reconcile_packet's pcall ever gets a chance
		expected_warning("were skipped and their cells will not update")
		c.net.reconcile_packet(deep_copy(s.net.generate_packets()[env.player_a]))

		local le_poisoned = c.net.get_client_entity(poisoned)
		expect_equal(c.world:has(le_poisoned, c.defs.Health), false, "the poisoned value never reached the client")
		expect_equal(
			c.world:get(le_healthy, c.defs.Health),
			8,
			"the following value in the same static-size list decoded correctly, proving alignment held"
		)
	end
)

-- 18) client shard compaction

test("a straggler moved by shard compaction is invisible to the move and keeps receiving correct deltas", function(env)
	local s = env.server
	local fillers = join_named_fillers(env, 30) -- shard 1 holds its full 32 (A, B, and 30 fillers)

	local straggler = fake_player("Straggler")
	local sc = env.make_client()
	env.join(straggler, sc) -- opens shard 2 as its sole occupant (33 live clients)
	expect_equal(s.net._client_shard(straggler), 2, "precondition: the straggler is shard 2's sole occupant")

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 10)
	env.apply(env.packet_for(env.frame(), straggler), sc)
	local le = sc.net.get_client_entity(e)
	expect_equal(sc.world:get(le, sc.defs.Health), 10, "straggler sees Health before the shrink")

	-- drop 10 of shard 1's fillers, leaving 22 there plus the straggler: 23 live
	-- clients, past the deadzone boundary for shard 2's lone occupant
	for i = 1, 10 do
		s.net.remove_client(fillers[i])
	end
	-- this call produces no packets -- nothing is staged; its purpose is
	-- running the reclaim at its tail, migrating the straggler down into shard 1
	s.net.generate_packets()
	expect_equal(s.net._client_shard(straggler), 1, "the reclaim actually migrated the straggler into shard 1")

	-- with nothing changed in the world, the migrated client's last-sent state
	-- already matches its current state at the new slot, so it gets no packet
	local quiet_packets = s.net.generate_packets()
	expect_equal(quiet_packets[straggler], nil, "a moved client with no world changes receives no packet at all")

	-- a value change reaches the migrated client as an ordinary delta
	s.world:set(e, s.defs.Health, 20)
	env.apply(env.packet_for(env.frame(), straggler), sc)
	expect_equal(sc.world:get(le, sc.defs.Health), 20, "migrated client receives the changed value")

	-- removing the component sends the migrated client a removal
	s.world:remove(e, s.defs.Health)
	env.apply(env.packet_for(env.frame(), straggler), sc)
	expect_equal(sc.world:has(le, sc.defs.Health), false, "migrated client receives the removal")
end)

test("component and entity whitelist membership survive a shard-compacting move", function(env)
	local s = env.server
	local fillers = join_named_fillers(env, 30) -- shard 1 holds its full 32 (A, B, and 30 fillers)

	local straggler = fake_player("Straggler")
	local sc = env.make_client()
	env.join(straggler, sc) -- opens shard 2 as its sole occupant (33 live clients)
	expect_equal(s.net._client_shard(straggler), 2, "precondition: the straggler is shard 2's sole occupant")

	-- a component-level whitelist: the entity is public, only Health is gated
	local e1 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:set(e1, s.defs.Health, 10)
	s.world:set(e1, pair(s.net.Private, s.defs.Health), { [straggler] = true })

	-- an entity-level whitelist: the whole entity is gated
	local e2 = s.world:entity()
	s.world:set(e2, s.defs.Health, 5)
	s.world:set(e2, s.net.Private, { [straggler] = true })
	s.world:add(e2, s.net.Replicated)

	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, straggler), sc)
	env.apply(env.packet_for(snapshot, env.player_a))
	local le1 = sc.net.get_client_entity(e1)
	local le2 = sc.net.get_client_entity(e2)
	expect_equal(sc.world:get(le1, sc.defs.Health), 10, "straggler sees the component-whitelisted value")
	expect(le2 ~= nil, "straggler sees the entity-whitelisted entity")
	local le1_a = env.client.net.get_client_entity(e1)
	expect(le1_a ~= nil, "player A still sees the public entity e1")
	expect_equal(
		env.client.world:has(le1_a, env.client.defs.Health),
		false,
		"player A is blocked from the gated Health"
	)
	expect_equal(env.client.net.get_client_entity(e2), nil, "player A never sees the entity-whitelisted e2")

	-- drop 10 of shard 1's fillers, leaving 23 live clients, and trigger the
	-- reclaim: the straggler migrates down into shard 1
	for i = 1, 10 do
		s.net.remove_client(fillers[i])
	end
	s.net.generate_packets()
	expect_equal(s.net._client_shard(straggler), 1, "the reclaim actually migrated the straggler into shard 1")

	-- the migrated client's whitelist grants still apply after the move: a
	-- fresh change on each gated cell must reach the straggler and nobody
	-- else. the new tag on e2 is gated only by the entity-level word, so it
	-- probes that the word's bit survived the move too.
	s.world:set(e1, s.defs.Health, 20)
	s.world:add(e2, s.defs.Burning)
	local snapshot2 = env.frame()
	env.apply(env.packet_for(snapshot2, straggler), sc)
	env.apply(env.packet_for(snapshot2, env.player_a))
	expect_equal(sc.world:get(le1, sc.defs.Health), 20, "migrated straggler still receives the whitelisted change")
	expect_equal(sc.world:has(le2, sc.defs.Burning), true, "the entity-level whitelist still admits the straggler")
	expect_equal(env.client.world:has(le1_a, env.client.defs.Health), false, "player A stays excluded after the move")
	expect_equal(env.client.net.get_client_entity(e2), nil, "player A stays excluded from e2 after the move")

	-- a later disallow on the migrated client still revokes correctly
	s.net.edit_component_privacy(e1, s.defs.Health, straggler, false)
	env.apply(env.packet_for(env.frame(), straggler), sc)
	expect_equal(sc.world:has(le1, sc.defs.Health), false, "disallowing the migrated client still revokes it")
end)

test("shard reclamation respects the compaction deadzone: no reclaim at 24, reclaim at 23", function(env)
	local s = env.server
	local fillers = join_named_fillers(env, 30) -- shard 1 holds its full 32 (A, B, and 30 fillers)

	local straggler = fake_player("Straggler")
	s.net.add_client(straggler)
	env.frame() -- opens shard 2 as its sole occupant (33 live clients)

	-- drop 9 fillers: 24 live clients, exactly at the deadzone boundary --
	-- (shard_count - 1) * 32 - 8 == 24, so 24 live clients must not reclaim.
	-- sections are shared across shards now, so shard placement can no longer
	-- be inferred from section identity; read it directly via _client_shard.
	for i = 1, 9 do
		s.net.remove_client(fillers[i])
	end
	s.net.generate_packets()
	expect_equal(s.net._client_shard(straggler), 2, "at 24 live clients the straggler's shard is not reclaimed")

	-- drop one more filler: 23 live clients, past the boundary -- this call
	-- reclaims shard 2, moving the straggler down into shard 1
	s.net.remove_client(fillers[10])
	s.net.generate_packets()
	expect_equal(s.net._client_shard(straggler), 1, "past the deadzone boundary the straggler migrates down")
end)

test("a three-shard population reclaims one shard per generate_packets call as it shrinks", function(env)
	local s = env.server
	local fillers1 = join_named_fillers(env, 30) -- shard 1 fills to 32 (A, B, and 30 fillers)

	local fillers2 = {}
	for i = 1, 31 do
		local filler = fake_player(`Shard2Filler{i}`)
		fillers2[i] = filler
		s.net.add_client(filler)
	end
	local occupant33 = fake_player("Occupant33")
	s.net.add_client(occupant33)
	env.frame() -- shard 2 fills to 32 (the 33rd through 64th clients)
	expect_equal(s.net._client_shard(occupant33), 2, "precondition: the shard-2 occupant starts in shard 2")

	local occupant65 = fake_player("Occupant65")
	s.net.add_client(occupant65)
	env.frame() -- shard 3 opens with its sole occupant (the 65th client)
	expect_equal(s.net._client_shard(occupant65), 3, "precondition: the 65th client opens shard 3")

	-- shrink to 5 live clients: 3 left in shard 1, the sole shard-2 occupant,
	-- and the sole shard-3 occupant
	for i = 1, 29 do
		s.net.remove_client(fillers1[i])
	end
	for i = 1, 31 do
		s.net.remove_client(fillers2[i])
	end

	-- first cycle: only shard 3 (the top shard) is past its deadzone, so its
	-- straggler (Occupant65) migrates down into shard 1. sections are shared
	-- across shards now, so shard placement can no longer be inferred from
	-- section identity; read it directly via _client_shard.
	s.net.generate_packets()
	expect_equal(s.net._client_shard(occupant65), 1, "the ex-shard-3 straggler migrates down to shard 1")
	expect_equal(s.net._client_shard(occupant33), 2, "the shard-2 occupant is still in its own shard")

	-- second cycle: shard 2 is now the top shard and is also past its
	-- deadzone, so its straggler (Occupant33) migrates down into shard 1 too
	s.net.generate_packets()
	expect_equal(s.net._client_shard(env.player_a), 1, "player A stays in shard 1")
	expect_equal(s.net._client_shard(env.player_b), 1, "player B stays in shard 1")
	expect_equal(s.net._client_shard(occupant65), 1, "the ex-shard-3 straggler still shares the single remaining shard")
	expect_equal(s.net._client_shard(occupant33), 1, "the ex-shard-2 straggler now shares the single remaining shard")
end)

-- 19) privacy blacklists and edit_entity_privacy/edit_component_privacy transitions

test("an entity-level Private blacklist blocks only the named client", function(env)
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 42)
	s.world:set(e, s.net.Private, { [env.player_a] = false })

	-- an unfiltered entity carrying no components anchors the named client's packet as a real one, so the
	-- absences below cannot pass through the harness's blank-packet fallback
	local public_e = s.world:entity()
	s.world:add(public_e, s.net.Replicated)

	local snapshot = env.frame()
	local packet_a = env.packet_for(snapshot, env.player_a)
	local packet_b = env.packet_for(snapshot, env.player_b)

	expect_equal(#packet_a.replicated, 1, "the named client receives only the unfiltered entity")
	expect_equal(packet_a.replicated[1], public_e, "the entity the named client receives is the public one")
	expect_equal(next(packet_a.components), nil, "the named client receives no component data")
	expect(table.find(packet_b.replicated, e) ~= nil, "every other client receives the entity")
	local data_b = packet_b.components[s.defs.Health]
	expect(data_b ~= nil and data_b.values ~= nil and data_b.values[1] == 42, "every other client receives Health")
end)

test("toggling an entity blacklist mid-session unreplicates it from the newly-named client", function(env)
	local s, c = env.server, env.client
	local c2 = env.make_client()
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 1)
	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, env.player_a), c)
	env.apply(env.packet_for(snapshot, env.player_b), c2)
	local le = c.net.get_client_entity(e)
	local le_b = c2.net.get_client_entity(e)
	expect(le ~= nil and c.world:contains(le), "A has the entity before the blacklist")
	expect(le_b ~= nil and c2.world:contains(le_b), "B has the entity before the blacklist")

	s.world:set(e, s.net.Private, { [env.player_a] = false })
	local snapshot2 = env.frame()
	local packet_a = env.packet_for(snapshot2, env.player_a)
	env.apply(packet_a, c)
	env.apply(env.packet_for(snapshot2, env.player_b), c2)
	expect_equal(packet_a.unreplicated[1], e, "A is told to delete the now-blacklisted entity")
	expect_equal(c.world:contains(le), false, "A's entity deleted")
	expect_equal(c2.world:contains(le_b), true, "B's entity unaffected by A's blacklist")
end)

test("a per-component Private blacklist hides only that component from the named client", function(env)
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 10)
	s.world:add(e, s.defs.Burning)
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_a] = false })

	local snapshot = env.frame()
	local packet_a = env.packet_for(snapshot, env.player_a)
	local packet_b = env.packet_for(snapshot, env.player_b)

	expect_equal(packet_a.replicated[1], e, "the named client still receives the entity")
	expect_equal(packet_a.components[s.defs.Health], nil, "the named client is blocked from the gated component")
	expect(packet_a.components[s.defs.Burning] ~= nil, "the named client still receives the public component")

	local data_b = packet_b.components[s.defs.Health]
	expect(data_b ~= nil and data_b.values ~= nil and data_b.values[1] == 10, "every other client keeps the component")
end)

test("a Private blacklist on a relation blocks its pairs from the named client", function(env)
	local s = env.server
	local e1 = s.world:entity()
	local e2 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(e2, s.net.Replicated)
	s.world:set(e1, pair(s.defs.Likes, e2), 3)
	-- a pair through a different relation, left unfiltered: the filter keys on Likes, so this one must
	-- still reach the named client
	s.world:add(e1, pair(s.defs.Targeting, e2))
	s.world:set(e1, pair(s.net.Private, s.defs.Likes), { [env.player_a] = false })

	local pair_id = pair(s.defs.Likes, e2)
	local other_pair_id = pair(s.defs.Targeting, e2)
	local snapshot = env.frame()
	local packet_a = env.packet_for(snapshot, env.player_a)
	-- the entities themselves still replicate to A -- this anchors A's packet
	-- as real, so the nil below can't pass through the blank-packet fallback
	expect(table.find(packet_a.replicated, e1) ~= nil, "the named client still receives the subject")
	expect(table.find(packet_a.replicated, e2) ~= nil, "the named client still receives the target")
	expect_equal(packet_a.components[pair_id], nil, "the named client is blocked from the pair")
	expect(packet_a.components[other_pair_id] ~= nil, "the filter keys on Likes: the named client keeps other pairs")
	local data_b = env.packet_for(snapshot, env.player_b).components[pair_id]
	expect(data_b ~= nil and data_b.values ~= nil and data_b.values[1] == 3, "every other client receives the pair")
end)

test("a client joining after a blacklist exists is admitted by it", function(env)
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 5)
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_a] = false })
	env.frame()

	local c2 = env.make_client()
	local newcomer = fake_player("Newcomer")
	local packet = env.join(newcomer, c2)

	expect_equal(packet.replicated[1], e, "the newcomer receives the entity")
	local data = packet.components[s.defs.Health]
	expect(
		data ~= nil and data.values ~= nil and data.values[1] == 5,
		"the newcomer, unnamed, is admitted by the blacklist"
	)
end)

test("a pending client named in a blacklist is excluded from their own full packet", function(env)
	local s = env.server
	local pending = fake_player("Pending")
	s.net.add_client(pending)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 5)
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [pending] = false })

	local packets = env.frame() -- allocates pending and builds its full packet
	expect_equal(packets[pending].replicated[1], e, "the pending client still receives the entity itself")
	expect_equal(
		packets[pending].components[s.defs.Health],
		nil,
		"the named pending client excludes the gated component"
	)
	local data_a = packets[env.player_a].components[s.defs.Health]
	expect(data_a ~= nil and data_a.values ~= nil and data_a.values[1] == 5, "an unnamed existing client still sees it")
end)

test("a filter naming only a pending client is neither pruned nor warned about", function(env)
	-- add_client is what makes a client tracked, not the slot allocation that follows it, so a filter naming a
	-- pending client names a tracked one: sanitization leaves it alone, and the prune warning stays silent
	-- (declaring nothing here is the assertion).
	local s = env.server
	local pending = fake_player("PendingNamed")
	s.net.add_client(pending) -- no generate_packets since, so the slot is still unallocated

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 33)
	local whitelist = { [pending] = true }
	s.world:set(e, s.net.Private, whitelist)

	local stored = s.world:get(e, s.net.Private)
	expect_equal(stored, whitelist, "nothing was pruned, so the table the caller passed is the one stored")
	expect_equal(stored[pending], true, "the pending client keeps the standing the filter gave them")

	local packets = env.frame() -- allocates the pending client and builds its full packet
	expect_equal(packets[pending].replicated[1], e, "the named client is admitted once their slot is allocated")
	local data = packets[pending].components[s.defs.Health]
	expect(data ~= nil and data.values ~= nil and data.values[1] == 33, "with the entity's value")
	expect_equal(
		#env.packet_for(packets, env.player_a).replicated,
		0,
		"while a client the filter never named is blocked"
	)
end)

test("a blacklist naming only already-departed clients restricts nobody", function(env)
	local s = env.server
	local departed = fake_player("Departed")
	s.net.add_client(departed)
	env.frame() -- allocate then depart, so the blacklist below names a dead slot
	s.net.remove_client(departed)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 9)
	expected_warning("blacklist named only untracked clients! it was removed outright")
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [departed] = false })
	-- a blacklist that sanitizes to nobody is dropped from inside the triggering set rather than cached:
	-- an empty table would read as a whitelist and block everyone instead
	expect_equal(
		s.world:has(e, pair(s.net.Private, s.defs.Health)),
		false,
		"the blacklist naming only a departed client was removed outright"
	)

	local snapshot = env.frame()
	local data_a = env.packet_for(snapshot, env.player_a).components[s.defs.Health]
	local data_b = env.packet_for(snapshot, env.player_b).components[s.defs.Health]
	expect(data_a ~= nil and data_a.values ~= nil and data_a.values[1] == 9, "player A sees the value")
	expect(data_b ~= nil and data_b.values ~= nil and data_b.values[1] == 9, "player B sees the value")
end)

test(
	"guard: a mixed-polarity per-component Private table errors, undoes the add, and leaves the component open to everyone",
	function(env)
		local s = env.server
		local e = s.world:entity()
		s.world:add(e, s.net.Replicated)
		s.world:set(e, s.defs.Health, 1)

		expect_error(function()
			s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_a] = true, [env.player_b] = false })
		end, "a mixed-polarity per-component Private table with no previous filter", "cannot mix allowed")
		expect_equal(
			s.world:has(e, pair(s.net.Private, s.defs.Health)),
			false,
			"the pair removed by the guard before erroring"
		)

		local snapshot = env.frame()
		local packet_a = env.packet_for(snapshot, env.player_a)
		local packet_b = env.packet_for(snapshot, env.player_b)
		expect(packet_a.components[s.defs.Health] ~= nil, "A sees Health, unfiltered")
		expect(packet_b.components[s.defs.Health] ~= nil, "B sees Health too, unfiltered")

		s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_a] = true })
		local snapshot2 = env.frame()
		local data_b = env.packet_for(snapshot2, env.player_b).components[s.defs.Health]
		expect(
			data_b ~= nil and data_b.removed ~= nil and data_b.removed[1] == e,
			"a subsequent valid whitelist filters B normally"
		)
	end
)

test(
	"guard: a mixed-polarity per-component Private table reverts to the previous filter with no spurious delta",
	function(env)
		local s = env.server
		local e = s.world:entity()
		s.world:add(e, s.net.Replicated)
		s.world:set(e, s.defs.Health, 1)
		local whitelist = { [env.player_a] = true }
		s.world:set(e, pair(s.net.Private, s.defs.Health), whitelist)

		local snapshot = env.frame()
		expect(env.packet_for(snapshot, env.player_a).components[s.defs.Health] ~= nil, "A admitted by the whitelist")
		expect_equal(
			env.packet_for(snapshot, env.player_b).components[s.defs.Health],
			nil,
			"B excluded by the whitelist"
		)

		expect_error(function()
			s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_a] = true, [env.player_b] = false })
		end, "a mixed-polarity per-component Private table with a previous filter", "cannot mix allowed")
		expect_equal(
			s.world:get(e, pair(s.net.Private, s.defs.Health)),
			whitelist,
			"the previous filter is restored by reference"
		)

		-- the revert restages the governed cells, but every mask lands back where it was, so the frame must
		-- carry no packet at all -- not merely a packet whose sections are empty. read the raw map: the
		-- harness's frame() hands back a blank packet for a player with none, which would hide the churn.
		local packets = s.net.generate_packets()
		expect_equal(packets[env.player_a], nil, "no spurious packet for A")
		expect_equal(packets[env.player_b], nil, "B still excluded, no churn either way")
	end
)

test(
	"guard: a mixed-polarity Private table errors, undoes the add, and leaves the entity open to everyone",
	function(env)
		local s = env.server
		local e = s.world:entity()
		s.world:add(e, s.net.Replicated)
		s.world:set(e, s.defs.Health, 1)

		expect_error(function()
			s.world:set(e, s.net.Private, { [env.player_a] = true, [env.player_b] = false })
		end, "a mixed-polarity Private table with no previous filter", "cannot mix allowed")
		expect_equal(s.world:has(e, s.net.Private), false, "Private removed by the guard before erroring")

		local snapshot = env.frame()
		expect_equal(env.packet_for(snapshot, env.player_a).replicated[1], e, "A sees the entity, unfiltered")
		expect_equal(env.packet_for(snapshot, env.player_b).replicated[1], e, "B sees the entity too, unfiltered")

		s.world:set(e, s.net.Private, { [env.player_a] = true })
		local snapshot2 = env.frame()
		-- A keeps the entity: nothing about A changed this frame, so their packet is blank and the
		-- proof has to come off the server's own masks rather than out of an absent delta
		expect_equal(
			s.net.is_entity_visible(e, env.player_a),
			true,
			"A stays visible under a subsequent valid whitelist"
		)
		expect_equal(#env.packet_for(snapshot2, env.player_a).unreplicated, 0, "A is never told to delete it")
		expect_equal(
			env.packet_for(snapshot2, env.player_b).unreplicated[1],
			e,
			"a subsequent valid whitelist filters B normally"
		)
	end
)

test(
	"guard: a mixed-polarity Private table reverts to the entity's previous filter with no spurious delta",
	function(env)
		local s = env.server
		local e = s.world:entity()
		s.world:add(e, s.net.Replicated)
		s.world:set(e, s.defs.Health, 1)
		local whitelist = { [env.player_a] = true }
		s.world:set(e, s.net.Private, whitelist)

		local snapshot = env.frame()
		expect_equal(env.packet_for(snapshot, env.player_a).replicated[1], e, "A admitted by the whitelist")
		expect_equal(#env.packet_for(snapshot, env.player_b).replicated, 0, "B excluded by the whitelist")

		expect_error(function()
			s.world:set(e, s.net.Private, { [env.player_a] = true, [env.player_b] = false })
		end, "a mixed-polarity Private table with a previous filter", "cannot mix allowed")
		expect_equal(s.world:get(e, s.net.Private), whitelist, "the previous filter is restored by reference")

		local snapshot2 = env.frame()
		local packet_a = env.packet_for(snapshot2, env.player_a)
		local packet_b = env.packet_for(snapshot2, env.player_b)
		expect_equal(next(packet_a.components), nil, "no spurious data for A")
		expect_equal(#packet_a.replicated, 0, "no spurious replicate churn for A")
		expect_equal(#packet_a.unreplicated, 0, "no spurious unreplicate churn for A")
		expect_equal(#packet_b.replicated, 0, "B still excluded, no churn either way")
		expect_equal(#packet_b.unreplicated, 0, "B still excluded, no churn either way")
	end
)

test(
	"guard: a mixed-polarity Private table reverts to an empty previous filter, keeping the entity hidden",
	function(env)
		local s = env.server
		local e = s.world:entity()
		s.world:add(e, s.net.Replicated)
		s.world:set(e, s.defs.Health, 1)
		local empty = {}
		s.world:set(e, s.net.Private, empty) -- empty: blocks everyone

		expect_error(function()
			s.world:set(e, s.net.Private, { [env.player_a] = true, [env.player_b] = false })
		end, "a mixed-polarity Private table with an empty previous filter", "cannot mix allowed")
		expect_equal(s.world:has(e, s.net.Private), true, "Private is still present after the revert")
		-- an empty filter caches as the caller's own table like any other, so the revert restores that very
		-- table rather than some shared empty stand-in
		expect_equal(s.world:get(e, s.net.Private), empty, "the previous empty filter is restored by reference")
		expect_equal(table.isfrozen(empty), true, "the reverted value is frozen")

		env.frame()
		expect_equal(s.net.is_entity_visible(e, env.player_a), false, "A still blocked by the empty gate")
		expect_equal(s.net.is_entity_visible(e, env.player_b), false, "B still blocked by the empty gate")

		-- control: the two blocks above come from the reverted filter and not from
		-- an entity the guard broke on its way out, so dropping it reopens both
		s.world:remove(e, s.net.Private)
		env.frame()
		expect_equal(s.net.is_entity_visible(e, env.player_a), true, "A reopens once the reverted filter is dropped")
		expect_equal(s.net.is_entity_visible(e, env.player_b), true, "B reopens once the reverted filter is dropped")
	end
)

test("guard: a non-table Private value errors, undoes the add, and leaves the entity open to everyone", function(env)
	-- a filter is a table keyed by client, so a scalar names no clients at all: the shape check faults before
	-- anything is cached, and the same revert guard the mixed-polarity error rides drops the value the fresh
	-- add had already landed.
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 1)

	expect_error(function()
		s.world:set(e, s.net.Private, 7 :: any)
	end, "a non-table Private value with no previous filter", "must be tables keyed by client")
	expect_equal(s.world:has(e, s.net.Private), false, "Private removed by the guard before erroring")

	local snapshot = env.frame()
	expect_equal(env.packet_for(snapshot, env.player_a).replicated[1], e, "A sees the entity, unfiltered")
	expect_equal(env.packet_for(snapshot, env.player_b).replicated[1], e, "B sees the entity too, unfiltered")
end)

test("guard: a non-table Private value reverts to the entity's previous filter, which still gates", function(env)
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 1)
	local whitelist = { [env.player_a] = true }
	s.world:set(e, s.net.Private, whitelist)

	local snapshot = env.frame()
	expect_equal(env.packet_for(snapshot, env.player_a).replicated[1], e, "A admitted by the whitelist")
	expect_equal(#env.packet_for(snapshot, env.player_b).replicated, 0, "B excluded by the whitelist")

	expect_error(function()
		s.world:set(e, s.net.Private, "everyone" :: any)
	end, "a non-table Private value with a previous filter", "must be tables keyed by client")
	expect_equal(s.world:get(e, s.net.Private), whitelist, "the previous filter is restored by reference")

	-- and the restored filter is still the one in force, not merely the value sitting on the entity
	env.frame()
	expect_equal(s.net.is_entity_visible(e, env.player_a), true, "A stays admitted by the reverted whitelist")
	expect_equal(s.net.is_entity_visible(e, env.player_b), false, "and B stays excluded by it")
end)

test("guard: a Private table mapping a client to a non-boolean errors rather than admitting them", function(env)
	-- a truthy non-boolean would sail through the polarity check and read as an allowed client, so it is
	-- refused rather than coerced: this is the one malformation whose reading would *widen* a filter.
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 1)
	local blocked = {}
	s.world:set(e, s.net.Private, blocked) -- empty: blocks everyone, so an admission would show

	expect_error(function()
		s.world:set(e, s.net.Private, { [env.player_a] = 1 :: any })
	end, "a Private table mapping a client to a number", "must map each client to true")
	expect_equal(s.world:get(e, s.net.Private), blocked, "the previous empty filter is restored by reference")

	env.frame()
	expect_equal(s.net.is_entity_visible(e, env.player_a), false, "the named client is not admitted by the refusal")
	expect_equal(s.net.is_entity_visible(e, env.player_b), false, "and nobody else is either")
end)

test(
	"guard: a non-table per-component Private value errors, undoing the add and leaving the component open",
	function(env)
		-- the shape checks sit in sanitize_privacy, which every filter passes through, so the paired level is
		-- guarded exactly like the entity level and reverts the same way.
		local s = env.server
		local e = s.world:entity()
		s.world:add(e, s.net.Replicated)
		s.world:set(e, s.defs.Health, 1)

		expect_error(function()
			s.world:set(e, pair(s.net.Private, s.defs.Health), true :: any)
		end, "a non-table per-component Private value with no previous filter", "must be tables keyed by client")
		expect_equal(
			s.world:has(e, pair(s.net.Private, s.defs.Health)),
			false,
			"the pair removed by the guard before erroring"
		)

		local snapshot = env.frame()
		expect(env.packet_for(snapshot, env.player_a).components[s.defs.Health] ~= nil, "A sees Health, unfiltered")
		expect(env.packet_for(snapshot, env.player_b).components[s.defs.Health] ~= nil, "B sees Health too, unfiltered")
	end
)

test("a blacklist created via edit_component_privacy blocks exactly the disallowed client", function(env)
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 8)
	env.frame()

	s.net.edit_component_privacy(e, s.defs.Health, env.player_b, false)
	-- with no filter configured, disallowing starts a blacklist naming just that
	-- client -- never a whitelist naming everyone else
	local filter = s.world:get(e, pair(s.net.Private, s.defs.Health))
	expect(filter ~= nil and filter[env.player_b] == false, "the edit named the disallowed client false")
	expect_equal(filter[env.player_a], nil, "the unnamed client is never written into the blacklist")

	local snapshot = env.frame()
	local data_a = env.packet_for(snapshot, env.player_a).components[s.defs.Health]
	expect_equal(data_a, nil, "player A, unnamed, observes no change (already visible)")
	local data_b = env.packet_for(snapshot, env.player_b).components[s.defs.Health]
	expect(
		data_b ~= nil and data_b.removed ~= nil and data_b.removed[1] == e,
		"player B, newly named, receives a removal"
	)

	-- a later update proves A's silence above was "nothing changed" rather than a
	-- block of their own, and that B's block outlives the frame it was made in
	s.world:set(e, s.defs.Health, 9)
	local snapshot2 = env.frame()
	local update_a = env.packet_for(snapshot2, env.player_a).components[s.defs.Health]
	expect(update_a ~= nil and update_a.values ~= nil and update_a.values[1] == 9, "A still receives updates")
	expect_equal(
		env.packet_for(snapshot2, env.player_b).components[s.defs.Health],
		nil,
		"B receives nothing further while blacklisted"
	)
end)

test("re-allowing a blacklisted client removes their name rather than writing true", function(env)
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 8)
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_a] = false, [env.player_b] = false })
	env.frame()

	s.net.edit_component_privacy(e, s.defs.Health, env.player_b, true)
	local current = s.world:get(e, pair(s.net.Private, s.defs.Health))
	expect_equal(current[env.player_b], nil, "the re-allowed client is un-named rather than set to true")
	expect_equal(current[env.player_a], false, "the still-disallowed client keeps their name")

	local snapshot = env.frame()
	local data_b = env.packet_for(snapshot, env.player_b).components[s.defs.Health]
	expect(
		data_b ~= nil and data_b.values ~= nil and data_b.values[1] == 8,
		"B receives the value now that they're admitted"
	)

	-- exactly one name was dropped: the client still named keeps their block, and
	-- the mask read makes that a live answer rather than an absent delta
	expect_equal(env.packet_for(snapshot, env.player_a).components[s.defs.Health], nil, "A receives nothing")
	expect_equal(
		s.net.is_component_visible(e, s.defs.Health, env.player_a),
		false,
		"the still-named client stays blocked"
	)
end)

test("allowing the last blacklisted client removes the Private pair and reopens the component", function(env)
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 8)
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_a] = false })
	env.sync(env.player_a)
	local le = c.net.get_client_entity(e)
	expect_equal(c.world:has(le, c.defs.Health), false, "A blocked before the edit")

	s.net.edit_component_privacy(e, s.defs.Health, env.player_a, true)
	expect_equal(s.world:has(e, pair(s.net.Private, s.defs.Health)), false, "the Private pair is removed entirely")

	env.sync(env.player_a)
	expect_equal(c.world:get(le, c.defs.Health), 8, "A now sees the value, admitted by everyone")
end)

test("allowing the last blacklisted client removes the entity-level Private value and reopens the entity", function(env)
	local s = env.server
	local c2 = env.make_client()
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 3)
	s.world:set(e, s.net.Private, { [env.player_b] = false })

	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, env.player_a))
	env.apply(env.packet_for(snapshot, env.player_b), c2)
	expect_equal(c2.net.get_client_entity(e), nil, "B blocked before the edit")

	s.net.edit_entity_privacy(e, env.player_b, true)
	expect_equal(s.world:has(e, s.net.Private), false, "the entity-level Private value is removed entirely")

	local packet_b = env.packet_for(env.frame(), env.player_b)
	expect_equal(packet_b.replicated[1], e, "B now receives the entity, admitted by everyone")
	env.apply(packet_b, c2)
	expect_equal(c2.world:get(c2.net.get_client_entity(e), c2.defs.Health), 3, "B's client gains the value")
end)

test("draining a whitelist to empty via edits keeps blocking everyone", function(env)
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 4)
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_a] = true })

	s.net.edit_component_privacy(e, s.defs.Health, env.player_a, false)
	local current = s.world:get(e, pair(s.net.Private, s.defs.Health))
	expect(current ~= nil, "the Private pair still exists")
	expect_equal(next(current), nil, "the drained whitelist is an empty table")

	-- the drained member is blocked too: this frame carries the entity's
	-- creation, so A's packet is real and the nil read below is meaningful
	local snapshot = env.frame()
	local packet_a = env.packet_for(snapshot, env.player_a)
	expect_equal(packet_a.replicated[1], e, "player A still receives the entity itself")
	expect_equal(packet_a.components[s.defs.Health], nil, "the drained-out player A is blocked")

	-- a fresh joiner is still blocked: an empty table always reads as a
	-- whitelist blocking everyone, never as a blacklist
	local c2 = env.make_client()
	local newcomer = fake_player("Newcomer")
	local packet = env.join(newcomer, c2)
	expect_equal(packet.replicated[1], e, "the newcomer receives the entity itself")
	expect_equal(packet.components[s.defs.Health], nil, "the newcomer is blocked by the empty whitelist")
end)

test("redundant blacklist edits are no-ops", function(env)
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 1)
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_a] = false })

	env.frame()

	local before = s.world:get(e, pair(s.net.Private, s.defs.Health))
	s.net.edit_component_privacy(e, s.defs.Health, env.player_a, false) -- already disallowed
	s.net.edit_component_privacy(e, s.defs.Health, env.player_b, true) -- already admitted
	expect_equal(s.world:get(e, pair(s.net.Private, s.defs.Health)), before, "blacklist value unchanged")

	local snapshot2 = env.frame()
	expect_equal(next(env.packet_for(snapshot2, env.player_a).components), nil, "no data for A")
	expect_equal(next(env.packet_for(snapshot2, env.player_b).components), nil, "no data for B")
end)

test("setting a blacklist naming only departed clients removes the Private value outright", function(env)
	-- a blacklist naming only already-departed clients sanitizes to an empty
	-- table, which restricts nobody; on_private_set removes the Private value
	-- outright from inside the triggering world:set rather than caching an
	-- empty entry, so the entity is left with no filter at all. that reads to
	-- edit_component_privacy as a plain absent filter, so allowing a client
	-- afterward warns the ordinary no-whitelist warning and does nothing.
	local s = env.server
	local departed = fake_player("Departed")
	s.net.add_client(departed)
	env.frame()
	s.net.remove_client(departed)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 6)
	local blacklist = { [departed] = false }
	expected_warning("blacklist named only untracked clients! it was removed outright")
	s.world:set(e, pair(s.net.Private, s.defs.Health), blacklist)

	-- the set itself removed the value: sanitization pruned the blacklist to
	-- empty and on_private_set dropped it rather than caching an empty entry
	expect_equal(s.world:has(e, pair(s.net.Private, s.defs.Health)), false, "the Private pair was removed by the set")

	-- visibility stays open with no filter configured: this frame carries the
	-- entity's creation, so A's packet is real and the value below is meaningful
	local snapshot = env.frame()
	local data_a = env.packet_for(snapshot, env.player_a).components[s.defs.Health]
	expect(
		data_a ~= nil and data_a.values ~= nil and data_a.values[1] == 6,
		"A sees the value with no filter configured"
	)

	expected_warning("cannot allow a client without a whitelist")
	s.net.edit_component_privacy(e, s.defs.Health, env.player_a, true)
	expect_equal(
		s.world:has(e, pair(s.net.Private, s.defs.Health)),
		false,
		"the no-op leaves no Private pair on the entity"
	)
end)

test("a component blacklist naming one player per shard blocks exactly those two", function(env)
	local s = env.server
	join_fillers(env, 30) -- shard 1 now holds its full 32 (A, B, and 30 fillers)

	local other = fake_player("ShardOneOther")
	local blocked = fake_player("ShardOneBlocked")
	s.net.add_client(other)
	s.net.add_client(blocked)
	env.frame() -- both land in shard 2, the first shard with room

	-- the cross-shard split is the whole point of the test, so pin the placement:
	-- a wider shard would quietly collapse this into a single-shard scenario
	expect_equal(s.net._client_shard(env.player_b), 1, "the named player of shard 1 is really in shard 1")
	expect_equal(s.net._client_shard(other), 2, "the unnamed newcomer opened shard 2")
	expect_equal(s.net._client_shard(blocked), 2, "the named newcomer landed in shard 2 too")

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 5)
	env.frame() -- every allocated player in both shards observes Health publicly

	-- name one player per shard; everyone else keeps seeing it
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_b] = false, [blocked] = false })
	local snapshot = env.frame()

	expect_equal(
		env.packet_for(snapshot, env.player_a).components[s.defs.Health],
		nil,
		"shard 1's unnamed player sees no change (already visible)"
	)
	expect_equal(
		env.packet_for(snapshot, other).components[s.defs.Health],
		nil,
		"shard 2's unnamed player sees no change (already visible)"
	)

	local data_b = env.packet_for(snapshot, env.player_b).components[s.defs.Health]
	expect(
		data_b ~= nil and data_b.removed ~= nil and data_b.removed[1] == e,
		"shard 1's named player receives a removal"
	)
	local data_blocked = env.packet_for(snapshot, blocked).components[s.defs.Health]
	expect(
		data_blocked ~= nil and data_blocked.removed ~= nil and data_blocked.removed[1] == e,
		"shard 2's named player receives a removal"
	)

	-- a later update proves the unnamed players of both shards are still admitted
	-- rather than merely unchanged, and that both named players stay out
	s.world:set(e, s.defs.Health, 6)
	local snapshot2 = env.frame()
	local update_a = env.packet_for(snapshot2, env.player_a).components[s.defs.Health]
	expect(
		update_a ~= nil and update_a.values ~= nil and update_a.values[1] == 6,
		"shard 1's unnamed player still receives updates"
	)
	local update_other = env.packet_for(snapshot2, other).components[s.defs.Health]
	expect(
		update_other ~= nil and update_other.values ~= nil and update_other.values[1] == 6,
		"shard 2's unnamed player still receives updates"
	)
	expect_equal(
		env.packet_for(snapshot2, env.player_b).components[s.defs.Health],
		nil,
		"shard 1's named player receives no update"
	)
	expect_equal(
		env.packet_for(snapshot2, blocked).components[s.defs.Health],
		nil,
		"shard 2's named player receives no update"
	)
end)

test("a blacklisted client's standing survives a shard-compacting move", function(env)
	local s = env.server
	local fillers = join_named_fillers(env, 30) -- shard 1 holds its full 32 (A, B, and 30 fillers)

	local straggler = fake_player("Straggler")
	local sc = env.make_client()
	env.join(straggler, sc) -- opens shard 2 as its sole occupant (33 live clients)
	-- the move below is only a move if the straggler really starts a shard up
	expect_equal(s.net._client_shard(straggler), 2, "the straggler opened shard 2")

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 10)
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [straggler] = false })

	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, straggler), sc)
	env.apply(env.packet_for(snapshot, env.player_a))
	local le = sc.net.get_client_entity(e)
	expect_equal(sc.world:has(le, sc.defs.Health), false, "the straggler is blocked before the shrink")
	local le_a = env.client.net.get_client_entity(e)
	expect_equal(env.client.world:get(le_a, env.client.defs.Health), 10, "player A, unnamed, sees the value")

	-- drop 10 of shard 1's fillers, leaving 23 live clients, and trigger the
	-- reclaim: the straggler migrates down into shard 1
	for i = 1, 10 do
		s.net.remove_client(fillers[i])
	end
	s.net.generate_packets()
	expect_equal(s.net._client_shard(straggler), 1, "the straggler migrates down into shard 1")

	-- the migrated client's blacklist standing still applies after the move
	s.world:set(e, s.defs.Health, 20)
	local snapshot2 = env.frame()
	env.apply(env.packet_for(snapshot2, straggler), sc)
	env.apply(env.packet_for(snapshot2, env.player_a))
	expect(sc.world:contains(le), "the straggler still holds the entity: only the component was ever gated")
	expect_equal(sc.world:has(le, sc.defs.Health), false, "the migrated straggler stays blocked")
	expect_equal(env.client.world:get(le_a, env.client.defs.Health), 20, "player A still receives the change")

	-- allowing the migrated client still admits them correctly
	s.net.edit_component_privacy(e, s.defs.Health, straggler, true)
	env.apply(env.packet_for(env.frame(), straggler), sc)
	expect_equal(sc.world:get(le, sc.defs.Health), 20, "allowing the migrated client admits them")
end)

test("a fresh client reusing a blacklisted departed client's slot is admitted", function(env)
	local s = env.server
	-- a second blacklisted client, so B's departure prunes the filter instead of
	-- removing it outright (a blacklist naming only the departing client is
	-- dropped, which would leave no filter for the newcomer to be admitted by)
	local other = fake_player("OtherBlocked")
	s.net.add_client(other)
	env.frame()

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 42)
	-- blacklisted against B and the client who stays
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_b] = false, [other] = false })
	env.frame() -- B and the other named client are blocked, A sees the value

	-- B leaves, then a fresh player reuses B's freed bit (the lowest free slot).
	-- the newcomer must be admitted by the surviving blacklist, not inherit B's
	-- block from the slot they took over.
	s.net.remove_client(env.player_b)
	expect_equal(
		s.world:has(e, pair(s.net.Private, s.defs.Health)),
		true,
		"the blacklist survives the departure, still naming the client who stayed"
	)

	local c2 = env.make_client()
	local player_c = fake_player("PlayerC")
	local packet_c = env.join(player_c, c2)

	expect_equal(packet_c.replicated[1], e, "C receives the public entity creation")
	local data_c = packet_c.components[s.defs.Health]
	expect(
		data_c ~= nil and data_c.values ~= nil and data_c.values[1] == 42,
		"C is admitted by the blacklist, unlike B"
	)
	local le = c2.net.get_client_entity(e)
	expect_equal(c2.world:get(le, c2.defs.Health), 42, "C's client gains the value")
	expect_equal(
		s.net.is_component_visible(e, s.defs.Health, other),
		false,
		"the client still named stays blocked across the slot reuse"
	)
end)

test("a blacklist naming only the departing client is removed outright on departure", function(env)
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 5)
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_b] = false })
	env.frame() -- A sees Health, B is blocked

	s.net.remove_client(env.player_b)
	expect_equal(
		s.world:has(e, pair(s.net.Private, s.defs.Health)),
		false,
		"the blacklist naming only the departed client is removed from the entity"
	)

	-- the removed hook restages the cell, but no remaining client's admission
	-- changed, so this drain must produce no spurious send
	local snapshot = env.frame()
	expect_equal(next(env.packet_for(snapshot, env.player_a).components), nil, "no spurious send from the restage")

	-- ordinary updates still flow correctly afterward
	s.world:set(e, s.defs.Health, 6)
	local snapshot2 = env.frame()
	local data_a = env.packet_for(snapshot2, env.player_a).components[s.defs.Health]
	expect(data_a ~= nil and data_a.values ~= nil and data_a.values[1] == 6, "A still receives ordinary updates")
end)

test("a departing client is pruned from a cached blacklist that still names another client", function(env)
	local s = env.server
	local blocked = fake_player("Blocked")
	s.net.add_client(blocked)
	env.frame() -- allocate the extra blocked client

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 7)
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_b] = false, [blocked] = false })
	env.frame() -- A sees Health, B and blocked are both blocked

	s.net.remove_client(env.player_b)

	-- blocked stays blocked, A keeps receiving updates
	s.world:set(e, s.defs.Health, 8)
	local snapshot = env.frame()
	expect_equal(
		env.packet_for(snapshot, blocked).components[s.defs.Health],
		nil,
		"the still-named client remains blocked"
	)
	local data_a = env.packet_for(snapshot, env.player_a).components[s.defs.Health]
	expect(
		data_a ~= nil and data_a.values ~= nil and data_a.values[1] == 8,
		"the unnamed client keeps receiving updates"
	)

	-- a rejoined B is admitted: blacklists admit unnamed clients, and the
	-- departure prune dropped B from the cache
	local c2 = env.make_client()
	local packet_b = env.join(env.player_b, c2)
	expect_equal(packet_b.replicated[1], e, "the rejoined client receives the public entity")
	local data_b = packet_b.components[s.defs.Health]
	expect(
		data_b ~= nil and data_b.values ~= nil and data_b.values[1] == 8,
		"the rejoined client is admitted, no longer named in the blacklist"
	)

	-- the prune persists in the cache: editing another client's standing clones
	-- the pruned table, so the departed client never reappears through the
	-- copy-on-write edit path
	s.net.edit_component_privacy(e, s.defs.Health, env.player_a, false)
	local final = s.world:get(e, pair(s.net.Private, s.defs.Health))
	expect_equal(final[env.player_b], nil, "the departed client pruned from the persisted blacklist")
	expect_equal(final[blocked], false, "the still-blocked client retained")
	expect_equal(final[env.player_a], false, "the newly disallowed client added")
end)

test("a whitelist naming only the departing client keeps blocking everyone after they leave", function(env)
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 9)
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_b] = true })
	env.frame() -- B sees Health, A is blocked

	s.net.remove_client(env.player_b)
	expect_equal(
		s.world:has(e, pair(s.net.Private, s.defs.Health)),
		true,
		"the whitelist value stays on the entity, unlike a blacklist emptied by the same departure"
	)
	-- the prune reaches the value as well as the cache, so the two stay one
	-- table: what is left names nobody at all
	local pruned = s.world:get(e, pair(s.net.Private, s.defs.Health))
	expect_equal(pruned[env.player_b], nil, "the departed client is pruned from the stored value too")
	expect_equal(next(pruned), nil, "the whitelist pruned of its only client is an empty table")
	expect_equal(table.isfrozen(pruned), true, "the pruned value is frozen like any cached filter")

	-- nobody sees the gated component now, including a rejoined B: an empty
	-- whitelist keeps blocking everyone
	s.world:set(e, s.defs.Health, 10)
	local snapshot = env.frame()
	expect_equal(env.packet_for(snapshot, env.player_a).components[s.defs.Health], nil, "A stays blocked")

	local c2 = env.make_client()
	local packet_b = env.join(env.player_b, c2)
	expect_equal(packet_b.replicated[1], e, "the rejoined client still receives the public entity")
	expect_equal(packet_b.components[s.defs.Health], nil, "the rejoined client is blocked by the empty whitelist")
end)

test("a departing client is pruned from an entity-level whitelist that still names another client", function(env)
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 11)
	s.world:set(e, s.net.Private, { [env.player_a] = true, [env.player_b] = true })
	env.frame() -- both named clients see the entity

	s.net.remove_client(env.player_b)
	-- the departure prunes the value alongside the cache, so the filter the world holds is the one the gate
	-- reads: everyone it still names keeps their standing
	local pruned = s.world:get(e, s.net.Private)
	expect_equal(pruned[env.player_b], nil, "the departed client is gone from the value, not just the cache")
	expect_equal(pruned[env.player_a], true, "the client who stayed keeps their standing")
	expect_equal(table.isfrozen(pruned), true, "the pruned value is frozen like any cached filter")

	s.world:set(e, s.defs.Health, 12)
	local snapshot = env.frame()
	local data_a = env.packet_for(snapshot, env.player_a).components[s.defs.Health]
	expect(
		data_a ~= nil and data_a.values ~= nil and data_a.values[1] == 12,
		"the still-named client keeps receiving updates"
	)

	-- an unfiltered neighbour anchors the rejoiner's full packet as a real one, so the absence below is the
	-- pruned whitelist's doing rather than an empty packet's
	local open = s.world:entity()
	s.world:add(open, s.net.Replicated)

	-- a rejoining client starts unlisted rather than re-admitted by the name they left behind
	local c2 = env.make_client()
	local packet_b = env.join(env.player_b, c2)
	expect(table.find(packet_b.replicated, open) ~= nil, "the rejoiner's full packet is real, not the blank fallback")
	expect_equal(table.find(packet_b.replicated, e), nil, "the rejoined client is blocked by the pruned whitelist")
	expect_equal(s.net.is_entity_visible(e, env.player_b), false, "and the gate agrees")
end)

test("a departing client is pruned from a per-component whitelist that still names another client", function(env)
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 3)
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_a] = true, [env.player_b] = true })
	env.frame() -- both named clients see the component

	s.net.remove_client(env.player_b)
	local pruned = s.world:get(e, pair(s.net.Private, s.defs.Health))
	expect_equal(pruned[env.player_b], nil, "the departed client is gone from the value, not just the cache")
	expect_equal(pruned[env.player_a], true, "the client who stayed keeps their standing")
	expect_equal(table.isfrozen(pruned), true, "the pruned value is frozen like any cached filter")

	s.world:set(e, s.defs.Health, 4)
	local snapshot = env.frame()
	local data_a = env.packet_for(snapshot, env.player_a).components[s.defs.Health]
	expect(
		data_a ~= nil and data_a.values ~= nil and data_a.values[1] == 4,
		"the still-named client keeps receiving updates"
	)

	-- a per-component filter never gates the entity itself, so the rejoiner's packet carries the entity and is
	-- real either way
	local c2 = env.make_client()
	local packet_b = env.join(env.player_b, c2)
	expect_equal(packet_b.replicated[1], e, "the rejoined client still receives the entity itself")
	expect_equal(packet_b.components[s.defs.Health], nil, "but starts unlisted in the pruned whitelist")
	expect_equal(s.net.is_component_visible(e, s.defs.Health, env.player_b), false, "and the component gate agrees")
end)

test("an entity-level whitelist naming an untracked client is stored pruned of them", function(env)
	-- sanitization prunes clients the instance never tracked, and the set writes that pruned copy back over
	-- the component's own value from inside the triggering set, so world:get reads the filter the caches gate
	-- by rather than the table the caller passed.
	local s = env.server
	local stranger = fake_player("EntityStranger")
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 21)
	local whitelist = { [env.player_a] = true, [stranger] = true }
	expected_warning("untracked client(s)! they were pruned from it")
	s.world:set(e, s.net.Private, whitelist)

	local stored = s.world:get(e, s.net.Private)
	expect(stored ~= whitelist, "the pruned copy replaced the table that was passed")
	expect_equal(stored[env.player_a], true, "the tracked client keeps their standing")
	expect_equal(stored[stranger], nil, "the never-tracked client is pruned out of the value")
	expect_equal(table.isfrozen(stored), true, "the pruned value is frozen like any cached filter")

	-- an unfiltered neighbour anchors the stranger's later full packet as a real one
	local open = s.world:entity()
	s.world:add(open, s.net.Replicated)

	local snapshot = env.frame()
	expect(table.find(env.packet_for(snapshot, env.player_a).replicated, e) ~= nil, "the named client sees the entity")
	expect_equal(s.net.is_entity_visible(e, env.player_b), false, "an unnamed client is blocked, so the filter gates")

	-- joining later cannot restore a standing the filter no longer holds
	local c2 = env.make_client()
	local packet = env.join(stranger, c2)
	expect(table.find(packet.replicated, open) ~= nil, "the stranger's full packet is real, not the blank fallback")
	expect_equal(table.find(packet.replicated, e), nil, "the pruned client joins blocked")

	-- re-admitting them goes through an edit, like any other unlisted client
	s.net.edit_entity_privacy(e, stranger, true)
	expect_equal(s.world:get(e, s.net.Private)[stranger], true, "the edit re-admits them")
	expect_equal(s.net.is_entity_visible(e, stranger), true, "and the gate opens")
end)

test("a per-component whitelist naming an untracked client is stored pruned of them", function(env)
	local s = env.server
	local stranger = fake_player("ComponentStranger")
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 22)
	local whitelist = { [env.player_a] = true, [stranger] = true }
	expected_warning("untracked client(s)! they were pruned from it")
	s.world:set(e, pair(s.net.Private, s.defs.Health), whitelist)

	local stored = s.world:get(e, pair(s.net.Private, s.defs.Health))
	expect(stored ~= whitelist, "the pruned copy replaced the table that was passed")
	expect_equal(stored[env.player_a], true, "the tracked client keeps their standing")
	expect_equal(stored[stranger], nil, "the never-tracked client is pruned out of the value")
	expect_equal(table.isfrozen(stored), true, "the pruned value is frozen like any cached filter")

	local snapshot = env.frame()
	local data_a = env.packet_for(snapshot, env.player_a).components[s.defs.Health]
	expect(data_a ~= nil and data_a.values ~= nil and data_a.values[1] == 22, "the named client sees the value")
	expect_equal(env.packet_for(snapshot, env.player_b).components[s.defs.Health], nil, "an unnamed client is blocked")

	local c2 = env.make_client()
	local packet = env.join(stranger, c2)
	expect_equal(packet.replicated[1], e, "the pruned client still receives the entity itself")
	expect_equal(packet.components[s.defs.Health], nil, "but joins blocked from the gated component")
end)

test("a partly pruned entity whitelist warns with the number of clients it lost", function(env)
	-- the warning counts the prune rather than the filter: the surviving entries are subtracted from the ones
	-- the caller passed, so the count names exactly how many standings went silently missing.
	local s = env.server
	local first = fake_player("CountedStrangerOne")
	local second = fake_player("CountedStrangerTwo")
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 31)

	expected_warning("named 2 untracked client(s)")
	s.world:set(e, s.net.Private, { [env.player_a] = true, [first] = true, [second] = true })

	local stored = s.world:get(e, s.net.Private)
	expect_equal(stored[env.player_a], true, "the one tracked client keeps their standing")
	expect_equal(stored[first], nil, "the first untracked client is pruned out of the value")
	expect_equal(stored[second], nil, "and so is the second")

	-- the pruned filter is a live whitelist, not a husk: it still admits the client it kept
	local snapshot = env.frame()
	local packet_a = env.packet_for(snapshot, env.player_a)
	expect(table.find(packet_a.replicated, e) ~= nil, "the surviving whitelist admits the tracked client")
	local data_a = packet_a.components[s.defs.Health]
	expect(data_a ~= nil and data_a.values ~= nil and data_a.values[1] == 31, "carrying the entity's value with it")
	expect_equal(#env.packet_for(snapshot, env.player_b).replicated, 0, "while a client it never named stays blocked")
end)

test("a blacklist naming one tracked and one untracked client is pruned rather than removed", function(env)
	-- a blacklist only loses its value outright when the prune empties it; with a tracked client still named it
	-- survives pruned like any other filter, and warns as a prune rather than as a removal.
	local s = env.server
	local stranger = fake_player("BlacklistStranger")
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 32)

	expected_warning("untracked client(s)! they were pruned from it")
	s.world:set(e, pair(s.net.Private, s.defs.Health), { [env.player_a] = false, [stranger] = false })

	local stored = s.world:get(e, pair(s.net.Private, s.defs.Health))
	expect(stored ~= nil, "the blacklist survived, still having a tracked client to restrict")
	expect_equal(stored[env.player_a], false, "naming the tracked client it was given")
	expect_equal(stored[stranger], nil, "and pruned of the untracked one")

	local snapshot = env.frame()
	expect_equal(
		env.packet_for(snapshot, env.player_a).components[s.defs.Health],
		nil,
		"the surviving blacklist still blocks the client it names"
	)
	local data_b = env.packet_for(snapshot, env.player_b).components[s.defs.Health]
	expect(data_b ~= nil and data_b.values ~= nil and data_b.values[1] == 32, "and admits everyone it does not")
end)

test("a departure prune rewrites the value without firing a user's Private hooks", function(env)
	-- the prune writes the pruned table straight into the value's column rather than through world:set: no
	-- client's standing changes, so nothing is restaged and a user's own Private listeners must stay asleep.
	local s = env.server
	local added_count = 0
	local changed_count = 0
	s.world:added(s.net.Private, function()
		added_count += 1
	end)
	s.world:changed(s.net.Private, function()
		changed_count += 1
	end)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 13)
	s.world:set(e, s.net.Private, { [env.player_a] = true, [env.player_b] = true })
	-- control: both listeners really are connected, so the unchanged counts below mean silence rather than a
	-- registration duplecs's own hooks displaced
	expect_equal(added_count, 1, "the ordinary add reached the added listener")
	s.world:set(e, s.net.Private, { [env.player_a] = true, [env.player_b] = true })
	expect_equal(changed_count, 1, "the ordinary re-set reached the changed listener")
	env.frame()

	s.net.remove_client(env.player_b)
	expect_equal(s.world:get(e, s.net.Private)[env.player_b], nil, "the prune really did rewrite the value")
	expect_equal(added_count, 1, "the rewrite fired no added hook")
	expect_equal(changed_count, 1, "the rewrite fired no changed hook")
end)

test("editing a pruned whitelist re-admits the rejoined client it no longer names", function(env)
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 14)
	s.world:set(e, s.net.Private, { [env.player_a] = true, [env.player_b] = true })
	-- an unfiltered neighbour anchors the rejoiner's full packet as a real one
	local open = s.world:entity()
	s.world:add(open, s.net.Replicated)
	env.frame()

	s.net.remove_client(env.player_b)
	expect_equal(s.world:get(e, s.net.Private)[env.player_b], nil, "the departure pruned the client from the value")

	local c2 = env.make_client()
	local packet_b = env.join(env.player_b, c2)
	expect(table.find(packet_b.replicated, open) ~= nil, "the rejoiner's full packet is real, not the blank fallback")
	expect_equal(table.find(packet_b.replicated, e), nil, "the rejoined client starts blocked")

	-- the edit clones from the pruned table, so the name it adds is the only one the filter holds for them
	s.net.edit_entity_privacy(e, env.player_b, true)
	local edited = s.world:get(e, s.net.Private)
	expect_equal(edited[env.player_b], true, "the edit re-admits the rejoined client")
	expect_equal(edited[env.player_a], true, "the client who never left is untouched")
	expect_equal(table.isfrozen(edited), true, "the edited value is frozen")

	local packet = env.packet_for(env.frame(), env.player_b)
	expect_equal(packet.replicated[1], e, "the re-admitted client receives the entity")
	env.apply(packet, c2)
	local le = c2.net.get_client_entity(e)
	expect_equal(c2.world:get(le, c2.defs.Health), 14, "and its value")
end)

-- 20) privacy delegation (InheritsPrivacy)

test("a group whitelist gates a delegating member end-to-end", function(env)
	-- pair(InheritsPrivacy, group) delegates the member's entity-level gate to
	-- the group's own unpaired Private; end-to-end via packet reconciliation, not
	-- just is_entity_visible, so the client-side create/omit is exercised too.
	local s, c = env.server, env.client
	local c2 = env.make_client()
	local group = s.world:entity()
	s.world:set(group, s.net.Private, { [env.player_a] = true })
	local member = s.world:entity()
	s.world:add(member, s.net.Replicated)
	s.world:set(member, s.defs.Health, 42)
	s.world:add(member, pair(s.net.InheritsPrivacy, group))

	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, env.player_a))
	env.apply(env.packet_for(snapshot, env.player_b), c2)

	local le_a = c.net.get_client_entity(member)
	expect(le_a ~= nil and c.world:contains(le_a), "A creates the delegated member")
	expect_equal(c.world:get(le_a, c.defs.Health), 42, "A receives the member's Health")
	expect_equal(c2.net.get_client_entity(member), nil, "B never creates the member")
end)

test("edit_entity_privacy on a group fans out to delegating members", function(env)
	-- edit_entity_privacy(group, client, allowed) edits the group's own unpaired
	-- filter; the fan-out reaches delegating members through world:set -> the
	-- Private hooks, both admitting and later revoking them.
	local s = env.server
	local c2 = env.make_client()
	local group = s.world:entity()
	s.world:set(group, s.net.Private, { [env.player_a] = true })
	local member = s.world:entity()
	s.world:add(member, s.net.Replicated)
	s.world:set(member, s.defs.Health, 5)
	s.world:add(member, pair(s.net.InheritsPrivacy, group))

	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, env.player_b), c2)
	expect_equal(c2.net.get_client_entity(member), nil, "B blocked before the group edit")

	s.net.edit_entity_privacy(group, env.player_b, true)
	-- the edit lands on the group alone: editing a group and editing a member's
	-- own filter stay structurally distinct operations
	expect_equal(s.world:has(member, s.net.Private), false, "the member gains no filter of its own")
	local packet_b = env.packet_for(env.frame(), env.player_b)
	expect_equal(packet_b.replicated[1], member, "B receives the member creation via the group edit")
	env.apply(packet_b, c2)
	local le_b = c2.net.get_client_entity(member)
	expect_equal(c2.world:get(le_b, c2.defs.Health), 5, "B's client gains the member's Health")

	s.net.edit_entity_privacy(group, env.player_b, false)
	local packet_b2 = env.packet_for(env.frame(), env.player_b)
	expect_equal(packet_b2.unreplicated[1], member, "B is told to delete the member")
	env.apply(packet_b2, c2)
	expect_equal(c2.world:contains(le_b), false, "B's member deleted wholesale")
end)

test("a member's own whitelist intersects the group delegation", function(env)
	-- a delegating entity's own unpaired Private narrows further: only clients
	-- passing both the group's filter and the member's own filter are admitted.
	-- a third client is what makes the group's half of that observable -- a
	-- filter naming every allocated client restricts nobody, so with only A and B
	-- the member's own filter alone would produce the same answers.
	local s = env.server
	local player_c = fake_player("IntersectThird")
	s.net.add_client(player_c)
	env.frame()
	expect(s.net._client_shard(player_c) ~= nil, "the third client really did get a slot")

	local group = s.world:entity()
	s.world:set(group, s.net.Private, { [env.player_a] = true, [env.player_b] = true })
	local member = s.world:entity()
	s.world:add(member, s.net.Replicated)
	s.world:add(member, pair(s.net.InheritsPrivacy, group))
	s.world:set(member, s.net.Private, { [env.player_a] = true, [player_c] = true })

	env.frame()
	expect_equal(s.net.is_entity_visible(member, env.player_a), true, "A admitted by the group and the own filter")
	expect_equal(
		s.net.is_entity_visible(member, env.player_b),
		false,
		"B admitted by the group but narrowed by own filter"
	)
	expect_equal(
		s.net.is_entity_visible(member, player_c),
		false,
		"C admitted by the own filter but narrowed by the group"
	)
end)

test("nested InheritsPrivacy chains narrow down the chain", function(env)
	-- effective visibility is the intersection all the way down: grandparent
	-- filter narrowed by parent filter narrowed by (absent) own filter. a third
	-- client is what makes the grandparent's link observable -- a filter naming
	-- every allocated client restricts nobody, so with only A and B the leaf's
	-- gate would read the same with the grandparent dropped from the chain.
	local s = env.server
	local player_c = fake_player("ChainThird")
	s.net.add_client(player_c)
	env.frame()
	expect(s.net._client_shard(player_c) ~= nil, "the third client really did get a slot")

	local grandparent = s.world:entity()
	s.world:set(grandparent, s.net.Private, { [env.player_a] = true, [env.player_b] = true })
	local parent = s.world:entity()
	s.world:add(parent, pair(s.net.InheritsPrivacy, grandparent))
	s.world:set(parent, s.net.Private, { [env.player_b] = true, [player_c] = true })
	local leaf = s.world:entity()
	s.world:add(leaf, s.net.Replicated)
	s.world:add(leaf, pair(s.net.InheritsPrivacy, parent))

	env.frame()
	expect_equal(s.net.is_entity_visible(leaf, env.player_a), false, "A narrowed out at the parent level")
	expect_equal(s.net.is_entity_visible(leaf, env.player_b), true, "B admitted through the whole chain")
	expect_equal(s.net.is_entity_visible(leaf, player_c), false, "C narrowed out at the grandparent level")
end)

test("removing a group's filter reverts an unfiltered delegating member to open", function(env)
	-- absent-vs-present: with no filter left anywhere on the chain, the member
	-- reverts to visible-to-everyone rather than staying gated, and the revert
	-- reaches the newly admitted client as a real create.
	local s, c = env.server, env.client
	local c2 = env.make_client()
	local group = s.world:entity()
	s.world:set(group, s.net.Private, { [env.player_a] = true })
	local member = s.world:entity()
	s.world:add(member, s.net.Replicated)
	s.world:set(member, s.defs.Health, 4)
	s.world:add(member, pair(s.net.InheritsPrivacy, group))

	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, env.player_a))
	env.apply(env.packet_for(snapshot, env.player_b), c2)
	expect_equal(s.net.is_entity_visible(member, env.player_a), true, "A admitted by the group whitelist")
	expect_equal(s.net.is_entity_visible(member, env.player_b), false, "B blocked while the group filters")
	expect(c.net.get_client_entity(member) ~= nil, "A's client holds the member while the group filters")
	expect_equal(c2.net.get_client_entity(member), nil, "B's client never created the member")

	s.world:remove(group, s.net.Private)
	local snapshot2 = env.frame()
	local packet_a = env.packet_for(snapshot2, env.player_a)
	local packet_b = env.packet_for(snapshot2, env.player_b)
	expect_equal(s.net.is_entity_visible(member, env.player_a), true, "A open after the revert")
	expect_equal(s.net.is_entity_visible(member, env.player_b), true, "B open after the revert")
	expect_equal(packet_b.replicated[1], member, "the revert reaches B as a create")
	expect_equal(#packet_a.replicated, 0, "A, already admitted, is not re-created by the revert")
	env.apply(packet_b, c2)
	local le_b = c2.net.get_client_entity(member)
	expect(le_b ~= nil and c2.world:contains(le_b), "B's client creates the member after the revert")
	expect_equal(c2.world:get(le_b, c2.defs.Health), 4, "B receives the member's Health with the create")
end)

test("removing an ancestor's filter mid-chain reverts descendants down the chain", function(env)
	-- the recompute must yield absent (not narrowed) once the whole chain is
	-- unrestricted, cascading through refresh_descendants two levels deep and
	-- landing on the newly admitted client as a create.
	local s, c = env.server, env.client
	local c2 = env.make_client()
	local grandparent = s.world:entity()
	s.world:set(grandparent, s.net.Private, { [env.player_b] = true })
	local parent = s.world:entity()
	s.world:add(parent, pair(s.net.InheritsPrivacy, grandparent))
	local leaf = s.world:entity()
	s.world:add(leaf, s.net.Replicated)
	s.world:set(leaf, s.defs.Health, 17)
	s.world:add(leaf, pair(s.net.InheritsPrivacy, parent))

	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, env.player_a))
	env.apply(env.packet_for(snapshot, env.player_b), c2)
	expect_equal(s.net.is_entity_visible(leaf, env.player_a), false, "A blocked by the grandparent's filter")
	expect_equal(s.net.is_entity_visible(leaf, env.player_b), true, "B admitted by the grandparent's filter")
	expect_equal(c.net.get_client_entity(leaf), nil, "A's client never created the leaf")
	local le_b = c2.net.get_client_entity(leaf)
	expect(le_b ~= nil and c2.world:contains(le_b), "B holds the leaf through the two-level chain")

	s.world:remove(grandparent, s.net.Private)
	local snapshot2 = env.frame()
	local packet_a = env.packet_for(snapshot2, env.player_a)
	expect_equal(s.net.is_entity_visible(leaf, env.player_a), true, "A reverts to open once the chain is unrestricted")
	expect_equal(s.net.is_entity_visible(leaf, env.player_b), true, "B stays open too")
	expect_equal(packet_a.replicated[1], leaf, "the revert reaches A two levels down as a create")
	expect_equal(#env.packet_for(snapshot2, env.player_b).replicated, 0, "B, already admitted, is not re-created")
	env.apply(packet_a)
	local le_a = c.net.get_client_entity(leaf)
	expect(le_a ~= nil and c.world:contains(le_a), "A's client creates the leaf after the revert")
	expect_equal(c.world:get(le_a, c.defs.Health), 17, "A receives the leaf's Health with the create")
	expect_equal(c2.world:contains(le_b), true, "B keeps the leaf across the revert")
end)

test("an empty group Private blocks every client below it", function(env)
	-- present-empty is the opposite of absent: an empty unpaired Private on the group
	-- caches as an empty (non-nil) mask, blocking everyone underneath it.
	local s, c = env.server, env.client
	local group = s.world:entity()
	s.world:set(group, s.net.Private, {}) -- present-empty: blocks everyone
	local member = s.world:entity()
	s.world:add(member, s.net.Replicated)
	s.world:add(member, pair(s.net.InheritsPrivacy, group))
	-- an ungated neighbour anchors both packets as real deliveries: without it a
	-- fully blocked member leaves both clients packetless, and the absences below
	-- would read off the harness's blank-packet fallback instead
	local neighbour = s.world:entity()
	s.world:add(neighbour, s.net.Replicated)

	local snapshot = env.frame()
	local packet_a = env.packet_for(snapshot, env.player_a)
	local packet_b = env.packet_for(snapshot, env.player_b)
	expect_equal(s.net.is_entity_visible(member, env.player_a), false, "A blocked by the present-empty gate")
	expect_equal(s.net.is_entity_visible(member, env.player_b), false, "B blocked by the present-empty gate")
	expect(table.find(packet_a.replicated, neighbour) ~= nil, "A's packet is real, not the blank fallback")
	expect(table.find(packet_b.replicated, neighbour) ~= nil, "B's packet is real, not the blank fallback")
	expect_equal(table.find(packet_a.replicated, member), nil, "A's packet never creates the member")
	expect_equal(table.find(packet_b.replicated, member), nil, "B's packet never creates the member")
	env.apply(packet_a)
	expect_equal(c.net.get_client_entity(member), nil, "A's client holds no member entity")
end)

test("a nil value on a group Private empties it, hiding the members below it", function(env)
	-- the normalization fans out like any filter edit on a group: the members inherit the emptied gate, so a
	-- nil value closes a whole delegation subtree at once rather than opening it.
	local s, c = env.server, env.client
	local group = s.world:entity()
	s.world:set(group, s.net.Private, { [env.player_a] = true })
	local member = s.world:entity()
	s.world:add(member, s.net.Replicated)
	s.world:set(member, s.defs.Health, 4)
	s.world:add(member, pair(s.net.InheritsPrivacy, group))

	env.apply(env.packet_for(env.frame(), env.player_a))
	expect_equal(s.net.is_entity_visible(member, env.player_a), true, "A is admitted by the inherited gate")
	expect_equal(s.net.is_entity_visible(member, env.player_b), false, "B is blocked by it")
	local le_a = c.net.get_client_entity(member)
	expect(le_a ~= nil and c.world:contains(le_a), "A's client holds the member before the edit")

	expected_warning("cannot have a nil value")
	s.world:set(group, s.net.Private, nil)
	expect_equal(s.world:has(group, s.net.Private), true, "the group's filter was emptied, not removed")
	expect_equal(s.world:has(member, s.net.Private), false, "the member never held a filter of its own")
	expect_equal(s.net.is_entity_visible(member, env.player_a), false, "so A loses the member through the delegation")
	expect_equal(s.net.is_entity_visible(member, env.player_b), false, "and B never gains it")

	local packet_a = env.packet_for(env.frame(), env.player_a)
	expect_equal(packet_a.unreplicated[1], member, "A is told to delete the member")
	env.apply(packet_a)
	expect_equal(c.world:contains(le_a), false, "A's client drops the member")
end)

test("a group blacklist composes with a member's own whitelist", function(env)
	-- blacklists normalize to allow-words at sanitization, so a mixed-polarity
	-- chain composes: the group's blacklist intersects the member's whitelist.
	-- the third client is what makes both halves load-bearing -- the blacklist
	-- admits them and the member's own whitelist does not, so dropping either
	-- gate admits someone who must stay out.
	local s, c = env.server, env.client
	local c2 = env.make_client()
	local c3 = env.make_client()
	local player_c = fake_player("BlacklistComposeThird")
	env.join(player_c, c3)

	local group = s.world:entity()
	s.world:set(group, s.net.Private, { [env.player_a] = false })
	local member = s.world:entity()
	s.world:add(member, s.net.Replicated)
	s.world:set(member, s.defs.Health, 6)
	s.world:set(member, s.net.Private, { [env.player_a] = true, [env.player_b] = true })
	s.world:add(member, pair(s.net.InheritsPrivacy, group))

	local snapshot = env.frame()
	expect_equal(
		s.net.is_entity_visible(member, env.player_a),
		false,
		"the group blacklist blocks A despite the own whitelist"
	)
	expect_equal(
		s.net.is_entity_visible(member, env.player_b),
		true,
		"B passes both the blacklist and the own whitelist"
	)
	expect_equal(
		s.net.is_entity_visible(member, player_c),
		false,
		"the third client passes the blacklist but not the own whitelist"
	)

	env.apply(env.packet_for(snapshot, env.player_a))
	env.apply(env.packet_for(snapshot, env.player_b), c2)
	env.apply(env.packet_for(snapshot, player_c), c3)
	expect_equal(c.net.get_client_entity(member), nil, "A's client never creates the member")
	local le_b = c2.net.get_client_entity(member)
	expect(le_b ~= nil and c2.world:contains(le_b), "B's client creates the member")
	expect_equal(c2.world:get(le_b, c2.defs.Health), 6, "B receives the member's Health")
	expect_equal(c3.net.get_client_entity(member), nil, "the third client never creates the member")
end)

test("closing an InheritsPrivacy cycle at runtime errors and removes only the offending pair", function(env)
	local s = env.server
	local a = s.world:entity()
	s.world:add(a, s.net.Replicated)
	local b = s.world:entity()
	s.world:add(a, pair(s.net.InheritsPrivacy, b))

	expect_error(function()
		s.world:add(b, pair(s.net.InheritsPrivacy, a))
	end, "closing an InheritsPrivacy cycle", "cannot contain cycles")
	expect_equal(s.world:has(b, pair(s.net.InheritsPrivacy, a)), false, "the offending pair was removed")
	expect_equal(s.world:has(a, pair(s.net.InheritsPrivacy, b)), true, "the pre-existing pair is untouched")

	-- world:has only speaks for the world; the internal mirror must agree. the
	-- surviving edge still has to delegate, and the rejected one must have left
	-- nothing behind that could gate b's other delegators from below.
	local watcher = s.world:entity()
	s.world:add(watcher, s.net.Replicated)
	s.world:add(watcher, pair(s.net.InheritsPrivacy, b))
	s.world:set(b, s.net.Private, { [env.player_a] = true })
	env.frame()
	expect_equal(s.net.is_entity_visible(a, env.player_a), true, "a still inherits b's filter")
	expect_equal(s.net.is_entity_visible(a, env.player_b), false, "a's inherited gate blocks B")

	s.world:set(a, s.net.Private, {}) -- empty: blocks everyone, and would block b too through a phantom edge
	env.frame()
	expect_equal(s.net.is_entity_visible(a, env.player_a), false, "a's own empty filter closes a itself")
	expect_equal(
		s.net.is_entity_visible(watcher, env.player_a),
		true,
		"the rejected b -> a edge left no trace: a's filter never reaches b's other delegator"
	)
end)

test("self-delegating InheritsPrivacy errors and removes the pair", function(env)
	local s = env.server
	local e = s.world:entity()
	expect_error(function()
		s.world:add(e, pair(s.net.InheritsPrivacy, e))
	end, "self-delegation", "cannot contain cycles")
	expect_equal(s.world:has(e, pair(s.net.InheritsPrivacy, e)), false, "the self-delegating pair was removed")

	-- the rejected add ran the guard before any mirror write, so the entity is
	-- still a clean delegator afterwards rather than poisoned by a half-edge
	local group = s.world:entity()
	s.world:set(group, s.net.Private, { [env.player_a] = true })
	s.world:add(e, s.net.Replicated)
	s.world:add(e, pair(s.net.InheritsPrivacy, group))
	env.frame()
	expect_equal(s.net.is_entity_visible(e, env.player_a), true, "A admitted through the later, valid edge")
	expect_equal(s.net.is_entity_visible(e, env.player_b), false, "B blocked by the group's whitelist")
end)

test("an unpaired InheritsPrivacy add errors and the tag is removed", function(env)
	local s = env.server
	-- the entity already delegates for real: the guard's undo has to take the unpaired
	-- tag and nothing else, wildcard-adjacent though the two ids are
	local group = s.world:entity()
	s.world:set(group, s.net.Private, { [env.player_a] = true })
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:add(e, pair(s.net.InheritsPrivacy, group))

	expect_error(function()
		s.world:add(e, s.net.InheritsPrivacy)
	end, "adding InheritsPrivacy unpaired", "must be paired with a group entity")
	expect_equal(s.world:has(e, s.net.InheritsPrivacy), false, "the unpaired tag was removed")
	expect_equal(s.world:has(e, pair(s.net.InheritsPrivacy, group)), true, "the real delegation pair survives")

	env.frame()
	expect_equal(s.net.is_entity_visible(e, env.player_a), true, "the surviving edge still admits A")
	expect_equal(s.net.is_entity_visible(e, env.player_b), false, "the surviving edge still blocks B")
end)

test("adding a second InheritsPrivacy pair accumulates and visibility intersects both groups' gates", function(env)
	-- InheritsPrivacy is no longer jecs.Exclusive: an entity may hold several
	-- delegation pairs at once, and its gate becomes the intersection of every
	-- parent's effective gate rather than a reparent. the narrowing has to land
	-- on the dropped client as a real delete, not just a server-side flip.
	local s, c = env.server, env.client
	local group1 = s.world:entity()
	s.world:set(group1, s.net.Private, { [env.player_a] = true, [env.player_b] = true })
	local group2 = s.world:entity()
	s.world:set(group2, s.net.Private, { [env.player_b] = true })
	local member = s.world:entity()
	s.world:add(member, s.net.Replicated)
	s.world:set(member, s.defs.Health, 8)
	s.world:add(member, pair(s.net.InheritsPrivacy, group1))

	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, env.player_a))
	expect_equal(s.net.is_entity_visible(member, env.player_a), true, "A admitted by group1 alone")
	expect_equal(s.net.is_entity_visible(member, env.player_b), true, "B admitted by group1 alone")
	local le_a = c.net.get_client_entity(member)
	expect(le_a ~= nil and c.world:contains(le_a), "A's client holds the member under group1 alone")
	expect_equal(c.world:get(le_a, c.defs.Health), 8, "A holds the member's Health under group1 alone")

	s.world:add(member, pair(s.net.InheritsPrivacy, group2))
	expect_equal(s.world:has(member, pair(s.net.InheritsPrivacy, group1)), true, "the first pair is still present")
	expect_equal(
		s.world:has(member, pair(s.net.InheritsPrivacy, group2)),
		true,
		"the second pair accumulates alongside it"
	)

	local snapshot2 = env.frame()
	expect_equal(s.net.is_entity_visible(member, env.player_a), false, "A dropped: group2 narrows the intersection")
	expect_equal(s.net.is_entity_visible(member, env.player_b), true, "B stays admitted by both groups")
	local packet_a = env.packet_for(snapshot2, env.player_a)
	expect_equal(packet_a.unreplicated[1], member, "the narrowing reaches A as a delete")
	env.apply(packet_a)
	expect_equal(c.world:contains(le_a), false, "A's client drops the member")
end)

test("delegating to two groups intersects both groups' whitelists end-to-end", function(env)
	-- multi-parent delegation, exercised through actual packet delivery rather
	-- than just is_entity_visible: a client must pass every parent's gate to
	-- receive the create, and one passing only one of the two must not.
	local s, c = env.server, env.client
	local c2 = env.make_client()
	local c3 = env.make_client()
	local player_c = fake_player("DelegationMultiThird")
	env.join(player_c, c3)

	local group_a = s.world:entity()
	s.world:set(group_a, s.net.Private, { [env.player_a] = true, [env.player_b] = true })
	local group_b = s.world:entity()
	s.world:set(group_b, s.net.Private, { [env.player_b] = true, [player_c] = true })
	local member = s.world:entity()
	s.world:add(member, s.net.Replicated)
	s.world:set(member, s.defs.Health, 7)
	s.world:add(member, pair(s.net.InheritsPrivacy, group_a))
	s.world:add(member, pair(s.net.InheritsPrivacy, group_b))

	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, env.player_a))
	env.apply(env.packet_for(snapshot, env.player_b), c2)
	env.apply(env.packet_for(snapshot, player_c), c3)

	expect_equal(c.net.get_client_entity(member), nil, "A blocked: not in group_b")
	local le_b = c2.net.get_client_entity(member)
	expect(le_b ~= nil and c2.world:contains(le_b), "B creates the member: admitted by both groups")
	expect_equal(c2.world:get(le_b, c2.defs.Health), 7, "B receives the member's Health")
	expect_equal(c3.net.get_client_entity(member), nil, "the third client blocked: not in group_a")
end)

test("removing one of two InheritsPrivacy pairs widens visibility to the remaining parent", function(env)
	-- removing an edge re-derives against the surviving parents: a client
	-- blocked only by the removed group's gate regains visibility, and the
	-- regain shows up as an actual create in the packet diff, not just a
	-- server-side visibility flip. the third client, named by neither group,
	-- pins that the widening stops at group_a rather than clearing the gate --
	-- a cleared gate would look identical from A's side alone.
	local s, c = env.server, env.client
	local c2 = env.make_client()
	local c3 = env.make_client()
	local player_c = fake_player("WidenOutsider")
	env.join(player_c, c3)

	local group_a = s.world:entity()
	s.world:set(group_a, s.net.Private, { [env.player_a] = true, [env.player_b] = true })
	local group_b = s.world:entity()
	s.world:set(group_b, s.net.Private, { [env.player_b] = true })
	local member = s.world:entity()
	s.world:add(member, s.net.Replicated)
	s.world:set(member, s.defs.Health, 13)
	s.world:add(member, pair(s.net.InheritsPrivacy, group_a))
	s.world:add(member, pair(s.net.InheritsPrivacy, group_b))

	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, env.player_a))
	env.apply(env.packet_for(snapshot, env.player_b), c2)
	expect_equal(c.net.get_client_entity(member), nil, "A blocked before the removal: group_b excludes A")
	local le_b = c2.net.get_client_entity(member)
	expect(le_b ~= nil and c2.world:contains(le_b), "B holds the member through both gates")

	s.world:remove(member, pair(s.net.InheritsPrivacy, group_b))
	local snapshot2 = env.frame()
	local packet_a = env.packet_for(snapshot2, env.player_a)
	expect_equal(packet_a.replicated[1], member, "removing the group_b edge widens A's gate to group_a alone")
	env.apply(packet_a)
	local le_a = c.net.get_client_entity(member)
	expect(le_a ~= nil and c.world:contains(le_a), "A's client creates the member after the widen")
	expect_equal(c.world:get(le_a, c.defs.Health), 13, "A receives the member's Health")
	expect_equal(
		s.net.is_entity_visible(member, player_c),
		false,
		"the widening stops at group_a: a client neither group names stays blocked"
	)
	expect_equal(#env.packet_for(snapshot2, env.player_b).replicated, 0, "B, already admitted, is not re-created")
	expect_equal(c2.world:contains(le_b), true, "B keeps the member across the widening")
end)

test("removing a redundant InheritsPrivacy edge that never restricted produces no delta", function(env)
	-- group_b carries no Private filter at all, so it never narrows the
	-- intersection; recompute_effective's unchanged-words comparison must skip
	-- the restage entirely, so the packet diff after the removal is empty for
	-- every client -- and the surviving edge must still gate exactly as before,
	-- which is the half a silent no-op and a silent clear would disagree on.
	local s, c = env.server, env.client
	local group_a = s.world:entity()
	s.world:set(group_a, s.net.Private, { [env.player_a] = true })
	local group_b = s.world:entity() -- no Private set: unrestricted
	local member = s.world:entity()
	s.world:add(member, s.net.Replicated)
	s.world:set(member, s.defs.Health, 19)
	s.world:add(member, pair(s.net.InheritsPrivacy, group_a))
	s.world:add(member, pair(s.net.InheritsPrivacy, group_b))

	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, env.player_a))
	local le_a = c.net.get_client_entity(member)
	expect(le_a ~= nil and c.world:contains(le_a), "A holds the member before the removal")
	expect_equal(s.net.is_entity_visible(member, env.player_a), true, "A admitted by group_a alone")
	expect_equal(s.net.is_entity_visible(member, env.player_b), false, "B blocked by group_a's whitelist")

	s.world:remove(member, pair(s.net.InheritsPrivacy, group_b))
	expect_equal(s.world:has(member, pair(s.net.InheritsPrivacy, group_b)), false, "the redundant edge is gone")
	local frame2 = env.frame()
	local packet_a = env.packet_for(frame2, env.player_a)
	local packet_b = env.packet_for(frame2, env.player_b)
	expect_equal(#packet_a.replicated, 0, "A's packet carries no create")
	expect_equal(#packet_a.unreplicated, 0, "A's packet carries no delete")
	expect_equal(next(packet_a.components), nil, "A's packet carries no component change")
	expect_equal(#packet_b.replicated, 0, "B's packet carries no create")
	expect_equal(#packet_b.unreplicated, 0, "B's packet carries no delete")
	expect_equal(s.net.is_entity_visible(member, env.player_a), true, "A still admitted by group_a")
	expect_equal(s.net.is_entity_visible(member, env.player_b), false, "B still blocked by group_a")
	env.apply(packet_a)
	expect_equal(c.world:contains(le_a), true, "A's client entity is untouched by the removal")
	expect_equal(c.world:get(le_a, c.defs.Health), 19, "A's Health survives the removal unchanged")
end)

test("diamond delegation folds through both parents to the shared root exactly once", function(env)
	-- E delegates to g1 and g2, and both g1 and g2 delegate to the same root: a
	-- diamond in the delegation DAG. verify the resting state equals own
	-- intersect g1 intersect g2 intersect root, then confirm a single root edit
	-- propagates through both branches to E in one generate_packets. g1 and g2
	-- are Replicated too, so each branch's own fold is observed directly instead
	-- of inferred from E's.
	local s = env.server
	local player_c = fake_player("DiamondC")
	local player_d = fake_player("DiamondD")
	s.net.add_client(player_c)
	s.net.add_client(player_d)
	env.frame() -- allocates both before any filter names them

	local root = s.world:entity()
	s.world:set(
		root,
		s.net.Private,
		{ [env.player_a] = true, [env.player_b] = true, [player_c] = true, [player_d] = true }
	)
	local g1 = s.world:entity()
	s.world:add(g1, s.net.Replicated)
	s.world:set(g1, s.net.Private, { [env.player_a] = true, [env.player_b] = true, [player_d] = true })
	s.world:add(g1, pair(s.net.InheritsPrivacy, root))
	local g2 = s.world:entity()
	s.world:add(g2, s.net.Replicated)
	s.world:set(g2, s.net.Private, { [env.player_a] = true, [env.player_b] = true, [player_c] = true })
	s.world:add(g2, pair(s.net.InheritsPrivacy, root))
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.net.Private, { [env.player_a] = true, [player_c] = true, [player_d] = true })
	s.world:add(e, pair(s.net.InheritsPrivacy, g1))
	s.world:add(e, pair(s.net.InheritsPrivacy, g2))

	env.frame()
	-- own{a,c,d} intersect g1{a,b,d} intersect g2{a,b,c} intersect root{a,b,c,d} = {a}
	expect_equal(s.net.is_entity_visible(g1, player_c), false, "g1's own filter excludes C")
	expect_equal(s.net.is_entity_visible(g2, player_d), false, "g2's own filter excludes D")
	expect_equal(s.net.is_entity_visible(e, env.player_a), true, "A passes own, g1, g2, and root")
	expect_equal(s.net.is_entity_visible(e, env.player_b), false, "B narrowed out by own")
	expect_equal(s.net.is_entity_visible(e, player_c), false, "C narrowed out by g1")
	expect_equal(s.net.is_entity_visible(e, player_d), false, "D narrowed out by g2")

	-- narrow the root so it no longer admits A either: the edit must reach E
	-- through both g1 and g2 in the same frame, and the fan-out must not
	-- double-restage E along the way
	s.world:set(root, s.net.Private, { [env.player_b] = true, [player_c] = true, [player_d] = true })
	local snapshot = env.frame()
	-- g1 folds to {b,d} and g2 to {b,c}, so E's intersection with own{a,c,d} empties
	expect_equal(s.net.is_entity_visible(g1, env.player_a), false, "the root edit reaches g1")
	expect_equal(s.net.is_entity_visible(g1, player_d), true, "g1 still admits D through the narrowed root")
	expect_equal(s.net.is_entity_visible(g2, env.player_a), false, "the root edit reaches g2")
	expect_equal(s.net.is_entity_visible(g2, player_c), true, "g2 still admits C through the narrowed root")
	expect_equal(
		s.net.is_entity_visible(e, env.player_a),
		false,
		"A now narrowed out by the root through both branches"
	)
	expect_equal(s.net.is_entity_visible(e, env.player_b), false, "B still narrowed out by own")
	expect_equal(s.net.is_entity_visible(e, player_c), false, "C still narrowed out by g1")
	expect_equal(s.net.is_entity_visible(e, player_d), false, "D still narrowed out by g2")

	-- one delete per entity A lost -- E, g1, and g2 -- however many times the
	-- diamond's two arrivals restaged them
	local packet_a = env.packet_for(snapshot, env.player_a)
	expect(table.find(packet_a.unreplicated, e) ~= nil, "A is told to drop E")
	expect_equal(#packet_a.unreplicated, 3, "A drops exactly E, g1, and g2, with no repeats")
end)

test("closing a cycle through a multi-parent path errors and removes only the offending pair", function(env)
	-- E delegates to both g1 and g2, and both delegate to the shared root;
	-- closing the loop by having root delegate back to E must be caught by the
	-- reachability walk even though the path back to root only exists through
	-- one of E's two parents at a time.
	local s = env.server
	local root = s.world:entity()
	s.world:set(root, s.net.Private, { [env.player_a] = true })
	local g1 = s.world:entity()
	s.world:add(g1, pair(s.net.InheritsPrivacy, root))
	local g2 = s.world:entity()
	s.world:add(g2, pair(s.net.InheritsPrivacy, root))
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:add(e, pair(s.net.InheritsPrivacy, g1))
	s.world:add(e, pair(s.net.InheritsPrivacy, g2))

	expect_error(function()
		s.world:add(root, pair(s.net.InheritsPrivacy, e))
	end, "closing a cycle through a multi-parent path", "InheritsPrivacy delegation cannot contain cycles!")
	expect_equal(s.world:has(root, pair(s.net.InheritsPrivacy, e)), false, "the offending pair was removed")

	-- the rejected edge left the DAG exactly as it was: e still inherits the
	-- root's whitelist through both branches rather than reverting to open,
	-- which is the state a widening after the root edit would also produce
	env.frame()
	expect_equal(s.net.is_entity_visible(e, env.player_a), true, "A still admitted through the intact DAG")
	expect_equal(s.net.is_entity_visible(e, env.player_b), false, "B still blocked by the root's whitelist")

	-- the rest of the DAG keeps working: a root filter edit still propagates
	-- down through both g1 and g2 to e
	s.world:set(root, s.net.Private, { [env.player_a] = true, [env.player_b] = true })
	env.frame()
	expect_equal(s.net.is_entity_visible(e, env.player_a), true, "A stays admitted after the root widen")
	expect_equal(s.net.is_entity_visible(e, env.player_b), true, "B admitted after the root widen, DAG intact")
end)

test("deleting a group deletes its delegating subtree, server and client", function(env)
	-- InheritsPrivacy carries pair(OnDeleteTarget, Delete), so deleting a group
	-- deletes every delegating entity down the chain; clients holding a deleted
	-- member locally receive the deletion and drop their client entity. mid is
	-- Replicated too, so the whole subtree is observed client-side rather than
	-- just its bottom.
	local s, c = env.server, env.client
	local c2 = env.make_client()
	local group = s.world:entity()
	s.world:set(group, s.net.Private, { [env.player_a] = true, [env.player_b] = true })
	local mid = s.world:entity()
	s.world:add(mid, s.net.Replicated)
	s.world:add(mid, pair(s.net.InheritsPrivacy, group))
	local leaf = s.world:entity()
	s.world:add(leaf, s.net.Replicated)
	s.world:set(leaf, s.defs.Health, 15)
	s.world:add(leaf, pair(s.net.InheritsPrivacy, mid))

	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, env.player_a))
	env.apply(env.packet_for(snapshot, env.player_b), c2)
	local le_a = c.net.get_client_entity(leaf)
	local le_b = c2.net.get_client_entity(leaf)
	local lm_a = c.net.get_client_entity(mid)
	expect(le_a ~= nil and c.world:contains(le_a), "A holds the leaf before the delete")
	expect(le_b ~= nil and c2.world:contains(le_b), "B holds the leaf before the delete")
	expect(lm_a ~= nil and c.world:contains(lm_a), "A holds the mid node before the delete")
	expect_equal(c.world:get(le_a, c.defs.Health), 15, "A holds the leaf's Health before the delete")

	s.world:delete(group)
	expect_equal(s.world:contains(group), false, "group deleted")
	expect_equal(s.world:contains(mid), false, "mid deleted through the OnDeleteTarget cascade")
	expect_equal(s.world:contains(leaf), false, "leaf deleted through the chain")

	local snapshot2 = env.frame()
	local packet_a = env.packet_for(snapshot2, env.player_a)
	local packet_b = env.packet_for(snapshot2, env.player_b)
	expect(table.find(packet_a.unreplicated, leaf) ~= nil, "A is told to delete the leaf")
	expect(table.find(packet_b.unreplicated, leaf) ~= nil, "B is told to delete the leaf")
	expect(table.find(packet_a.unreplicated, mid) ~= nil, "A is told to delete the mid node too")
	env.apply(packet_a)
	env.apply(packet_b, c2)
	expect_equal(c.world:contains(le_a), false, "A's local leaf entity removed")
	expect_equal(c2.world:contains(le_b), false, "B's local leaf entity removed")
	expect_equal(c.world:contains(lm_a), false, "A's local mid entity removed")
end)

test("deleting one of several groups a member delegates to still deletes the member", function(env)
	-- InheritsPrivacy still carries pair(OnDeleteTarget, Delete) per edge, so
	-- deleting any one group an entity delegates to deletes the entity outright
	-- -- a group deletion never merely widens the surviving intersection. the
	-- sibling bounds the cascade from the other side: it follows the deleted
	-- group's edges only, never the survivor's.
	local s, c = env.server, env.client
	local c2 = env.make_client()
	local group_a = s.world:entity()
	s.world:set(group_a, s.net.Private, { [env.player_a] = true, [env.player_b] = true })
	local group_b = s.world:entity()
	s.world:set(group_b, s.net.Private, { [env.player_a] = true, [env.player_b] = true })
	local member = s.world:entity()
	s.world:add(member, s.net.Replicated)
	s.world:add(member, pair(s.net.InheritsPrivacy, group_a))
	s.world:add(member, pair(s.net.InheritsPrivacy, group_b))
	local sibling = s.world:entity()
	s.world:add(sibling, s.net.Replicated)
	s.world:add(sibling, pair(s.net.InheritsPrivacy, group_b))

	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, env.player_a))
	env.apply(env.packet_for(snapshot, env.player_b), c2)
	local le_a = c.net.get_client_entity(member)
	local le_b = c2.net.get_client_entity(member)
	local ls_a = c.net.get_client_entity(sibling)
	expect(le_a ~= nil and c.world:contains(le_a), "A holds the member before the delete")
	expect(le_b ~= nil and c2.world:contains(le_b), "B holds the member before the delete")
	expect(ls_a ~= nil and c.world:contains(ls_a), "A holds the sibling before the delete")

	s.world:delete(group_a)
	expect_equal(s.world:contains(group_a), false, "group_a deleted")
	expect_equal(s.world:contains(group_b), true, "group_b, untouched, survives")
	expect_equal(
		s.world:contains(member),
		false,
		"member deleted through the OnDeleteTarget cascade from group_a alone"
	)
	expect_equal(s.world:contains(sibling), true, "the sibling delegating only to group_b is untouched")

	local snapshot2 = env.frame()
	local packet_a = env.packet_for(snapshot2, env.player_a)
	local packet_b = env.packet_for(snapshot2, env.player_b)
	expect(table.find(packet_a.unreplicated, member) ~= nil, "A is told to delete the member")
	expect(table.find(packet_b.unreplicated, member) ~= nil, "B is told to delete the member")
	expect_equal(table.find(packet_a.unreplicated, sibling), nil, "A is not told to drop the sibling")
	env.apply(packet_a)
	env.apply(packet_b, c2)
	expect_equal(c.world:contains(le_a), false, "A's local member entity removed")
	expect_equal(c2.world:contains(le_b), false, "B's local member entity removed")
	expect_equal(c.world:contains(ls_a), true, "A's local sibling entity survives")
end)

test("a group's per-component Private filter has no effect on a member's component", function(env)
	-- delegation is scoped to the entity-level gate only: a (component, group)
	-- key can't be encoded in a single pair target, so per-component filters on
	-- the group never reach a delegating member's own cells. the unpaired filter set
	-- at the end is the positive control -- without it the pass above reads the
	-- same whether the edge excludes per-component filters or is simply dead.
	local s = env.server
	local group = s.world:entity()
	s.world:set(group, pair(s.net.Private, s.defs.Health), { [env.player_a] = true })
	local member = s.world:entity()
	s.world:add(member, s.net.Replicated)
	s.world:set(member, s.defs.Health, 9)
	s.world:add(member, pair(s.net.InheritsPrivacy, group))

	local snapshot = env.frame()
	local data_a = env.packet_for(snapshot, env.player_a).components[s.defs.Health]
	local data_b = env.packet_for(snapshot, env.player_b).components[s.defs.Health]
	expect(
		data_a ~= nil and data_a.values[1] == 9,
		"A receives Health: the group's per-component filter is local to the group"
	)
	expect(data_b ~= nil and data_b.values[1] == 9, "B also receives Health: per-component filters never inherit")

	s.world:set(group, s.net.Private, { [env.player_a] = true })
	local snapshot2 = env.frame()
	expect_equal(s.net.is_entity_visible(member, env.player_a), true, "the group's entity-level filter admits A")
	expect_equal(s.net.is_entity_visible(member, env.player_b), false, "the same edge does gate the entity level")
	expect(
		table.find(env.packet_for(snapshot2, env.player_b).unreplicated, member) ~= nil,
		"B loses the whole member once the group's entity-level filter names only A"
	)
end)

test("a delegation chain built before the first frame derives correct delegated visibility", function(env)
	-- a world populated in one go on a fresh instance (delegation pairs and
	-- filters all in place before any packet frame) must resolve the same as a
	-- chain edited across frames.
	local world = jecs.world()
	local net = duplecs.server(world)
	local defs = make_defs(world)
	world:add(defs.Health, net.Networked)

	local player_a = fake_player("CatchupA")
	local player_b = fake_player("CatchupB")
	-- queue the clients first: a filter naming a client that is neither
	-- tracked nor pending is pruned at sanitization
	net.add_client(player_a)
	net.add_client(player_b)

	local group = world:entity()
	world:set(group, net.Private, { [player_a] = true })
	local mid = world:entity()
	world:add(mid, pair(net.InheritsPrivacy, group))
	local leaf = world:entity()
	world:add(leaf, net.Replicated)
	world:set(leaf, defs.Health, 3)
	world:add(leaf, pair(net.InheritsPrivacy, mid))
	-- an ungated entity anchors B's full packet as a real delivery, so B's
	-- exclusion below cannot pass against a packet that carried nothing at all
	local open = world:entity()
	world:add(open, net.Replicated)

	local packets = net.generate_packets()

	local server = { world = world, net = net, defs = defs }
	local client_a = make_client(server)
	local client_b = make_client(server)
	client_a.net.reconcile_packet(deep_copy(packets[player_a]))
	client_b.net.reconcile_packet(deep_copy(packets[player_b]))

	expect_equal(net.is_entity_visible(leaf, player_a), true, "the two-level chain admits A")
	expect_equal(net.is_entity_visible(leaf, player_b), false, "the two-level chain blocks B")
	local le_a = client_a.net.get_client_entity(leaf)
	expect(le_a ~= nil and client_a.world:contains(le_a), "A's first full packet creates the leaf")
	expect_equal(client_a.world:get(le_a, client_a.defs.Health), 3, "A sees the leaf's Health")
	expect(client_b.net.get_client_entity(open) ~= nil, "B's full packet is a real delivery")
	expect_equal(client_b.net.get_client_entity(leaf), nil, "B's first full packet excludes the leaf")
end)

test("a multi-parent DAG built before the first frame derives correct visibility", function(env)
	-- mirrors the single-chain test above, but the leaf now delegates to two
	-- groups: both edges must accumulate into delegation_parents and fold into
	-- one intersected gate before the first packet resolves. the two groups
	-- deliberately admit different extra clients, so honouring either edge alone
	-- wrongly admits one of them -- with nested whitelists the second edge alone
	-- would give the right answer for the wrong reason.
	local world = jecs.world()
	local net = duplecs.server(world)
	local defs = make_defs(world)
	world:add(defs.Health, net.Networked)

	local player_a = fake_player("MultiCatchupA")
	local player_b = fake_player("MultiCatchupB")
	local player_c = fake_player("MultiCatchupC")
	net.add_client(player_a)
	net.add_client(player_b)
	net.add_client(player_c)

	local group_a = world:entity()
	world:set(group_a, net.Private, { [player_a] = true, [player_b] = true })
	local group_b = world:entity()
	world:set(group_b, net.Private, { [player_a] = true, [player_c] = true })
	local leaf = world:entity()
	world:add(leaf, net.Replicated)
	world:set(leaf, defs.Health, 5)
	world:add(leaf, pair(net.InheritsPrivacy, group_a))
	world:add(leaf, pair(net.InheritsPrivacy, group_b))
	-- an ungated entity anchors the excluded clients' full packets as real
	-- deliveries rather than packets that happened to carry nothing
	local open = world:entity()
	world:add(open, net.Replicated)

	local packets = net.generate_packets()

	local server = { world = world, net = net, defs = defs }
	local client_a = make_client(server)
	local client_b = make_client(server)
	local client_c = make_client(server)
	client_a.net.reconcile_packet(deep_copy(packets[player_a]))
	client_b.net.reconcile_packet(deep_copy(packets[player_b]))
	client_c.net.reconcile_packet(deep_copy(packets[player_c]))

	expect_equal(net.is_entity_visible(leaf, player_a), true, "A passes both groups")
	expect_equal(net.is_entity_visible(leaf, player_b), false, "B passes group_a only")
	expect_equal(net.is_entity_visible(leaf, player_c), false, "C passes group_b only")

	local le_a = client_a.net.get_client_entity(leaf)
	expect(
		le_a ~= nil and client_a.world:contains(le_a),
		"A's first full packet creates the leaf: admitted by both groups"
	)
	expect_equal(client_a.world:get(le_a, client_a.defs.Health), 5, "A sees the leaf's Health")
	expect(client_b.net.get_client_entity(open) ~= nil, "B's full packet is a real delivery")
	expect_equal(
		client_b.net.get_client_entity(leaf),
		nil,
		"B's first full packet excludes the leaf: group_b narrows it out"
	)
	expect(client_c.net.get_client_entity(open) ~= nil, "C's full packet is a real delivery")
	expect_equal(
		client_c.net.get_client_entity(leaf),
		nil,
		"C's first full packet excludes the leaf: group_a narrows it out"
	)
end)

test("a joiner's full packet respects delegation, then is admitted by a group edit", function(env)
	local s = env.server
	local group = s.world:entity()
	s.world:set(group, s.net.Private, { [env.player_a] = true })
	local member = s.world:entity()
	s.world:add(member, s.net.Replicated)
	s.world:set(member, s.defs.Health, 11)
	s.world:add(member, pair(s.net.InheritsPrivacy, group))
	-- an ungated entity anchors the joiner's full packet as a real delivery, so
	-- the exclusion below cannot pass against a packet that carried nothing
	local open = s.world:entity()
	s.world:add(open, s.net.Replicated)
	env.frame()

	local c3 = env.make_client()
	local player_c = fake_player("DelegationJoiner")
	local packet_c = env.join(player_c, c3)
	expect(table.find(packet_c.replicated, open) ~= nil, "the joiner's full packet carries the ungated entity")
	expect_equal(table.find(packet_c.replicated, member), nil, "the joiner is blocked by the group whitelist")
	expect_equal(c3.net.get_client_entity(member), nil, "the joiner's client never creates the member")
	expect_equal(s.net.is_entity_visible(member, player_c), false, "the joiner sits outside the delegated gate")

	s.net.edit_entity_privacy(group, player_c, true)
	local snapshot = env.frame()
	local packet_c2 = env.packet_for(snapshot, player_c)
	expect_equal(packet_c2.replicated[1], member, "the group edit admits the joiner")
	expect_equal(#env.packet_for(snapshot, env.player_a).replicated, 0, "A, already admitted, sees no churn")
	env.apply(packet_c2, c3)
	expect_equal(
		c3.world:get(c3.net.get_client_entity(member), c3.defs.Health),
		11,
		"the joiner's client gains the member"
	)
end)

test("a pending client joining across a multi-parent delegation is granted the intersected gate", function(env)
	-- exercises allocate_client's delegation-aware pass over more than one
	-- parent: both group filters name the pending joiner while they're still
	-- bitless, and refresh_delegator must re-derive the entity's effective
	-- words from both freshly-granted parents before full_packet resolves the
	-- joiner's first snapshot. A and B each pass exactly one of the two groups,
	-- so both must stay out.
	local s = env.server
	local pending = fake_player("DelegationPending")
	s.net.add_client(pending)

	local group_a = s.world:entity()
	s.world:set(group_a, s.net.Private, { [pending] = true, [env.player_a] = true })
	local group_b = s.world:entity()
	s.world:set(group_b, s.net.Private, { [pending] = true, [env.player_b] = true })
	local member = s.world:entity()
	s.world:add(member, s.net.Replicated)
	s.world:set(member, s.defs.Health, 21)
	s.world:add(member, pair(s.net.InheritsPrivacy, group_a))
	s.world:add(member, pair(s.net.InheritsPrivacy, group_b))
	-- an ungated entity anchors A's and B's packets as real deliveries, so their
	-- exclusions below cannot read off the blank-packet fallback
	local open = s.world:entity()
	s.world:add(open, s.net.Replicated)

	local packets = env.frame() -- allocates pending and builds its full packet
	expect(
		table.find(packets[pending].replicated, member) ~= nil,
		"the joiner's full packet includes the intersected member"
	)
	local data = packets[pending].components[s.defs.Health]
	expect(data ~= nil and data.values[1] == 21, "the joiner receives the member's Health in their first packet")
	expect_equal(s.net.is_entity_visible(member, pending), true, "the joiner passes both freshly-granted gates")
	expect_equal(s.net.is_entity_visible(member, env.player_a), false, "A stays excluded: not in group_b")
	expect_equal(s.net.is_entity_visible(member, env.player_b), false, "B stays excluded: not in group_a")
	expect(table.find(packets[env.player_a].replicated, open) ~= nil, "A's packet is a real delivery")
	expect(table.find(packets[env.player_b].replicated, open) ~= nil, "B's packet is a real delivery")
	expect_equal(table.find(packets[env.player_a].replicated, member), nil, "A's packet excludes the member")
	expect_equal(table.find(packets[env.player_b].replicated, member), nil, "B's packet excludes the member")
end)

test("recycling a client slot clears a stale delegated group grant", function(env)
	-- sweep_freed_slots clears the derived effective words too, not just the
	-- own allow words, so a newcomer reusing a freed bit does not inherit
	-- the prior occupant's admission through the group.
	local s = env.server
	local group = s.world:entity()
	s.world:set(group, s.net.Private, { [env.player_b] = true })
	local member = s.world:entity()
	s.world:add(member, s.net.Replicated)
	s.world:add(member, pair(s.net.InheritsPrivacy, group))

	-- anchor the grant before the recycle: a delegation that admitted nobody would satisfy every assertion
	-- below for entirely the wrong reason
	local packets = env.frame()
	expect_equal(packets[env.player_b].replicated[1], member, "B sees the delegated member")
	expect_equal(#packets[env.player_a].replicated, 0, "A does not: the group whitelists B alone")

	-- B leaves, then a fresh player reuses B's freed bit
	s.net.remove_client(env.player_b)
	local c2 = env.make_client()
	local player_c = fake_player("PlayerC")
	local packet_c = env.join(player_c, c2)

	expect_equal(table.find(packet_c.replicated, member), nil, "C does not inherit B's delegated admission")
	expect_equal(c2.net.get_client_entity(member), nil, "C's client never creates the member")
end)

test("a delegated member gated by a group whitelist survives a shard-compacting move", function(env)
	local s = env.server
	local fillers = join_named_fillers(env, 30) -- shard 1 holds its full 32 (A, B, and 30 fillers)

	local straggler = fake_player("DelegationStraggler")
	local sc = env.make_client()
	env.join(straggler, sc) -- opens shard 2 as its sole occupant (33 live clients)

	local group = s.world:entity()
	s.world:set(group, s.net.Private, { [straggler] = true })
	local member = s.world:entity()
	s.world:add(member, s.net.Replicated)
	s.world:set(member, s.defs.Health, 10)
	s.world:add(member, pair(s.net.InheritsPrivacy, group))

	local snapshot = env.frame()
	env.apply(env.packet_for(snapshot, straggler), sc)
	env.apply(env.packet_for(snapshot, env.player_a))
	local le = sc.net.get_client_entity(member)
	expect(le ~= nil, "the straggler sees the delegated member before the shrink")
	expect_equal(env.client.net.get_client_entity(member), nil, "player A never sees the delegated member")

	-- drop 10 of shard 1's fillers, leaving 23 live clients, and trigger the
	-- reclaim: the straggler migrates down into shard 1
	for i = 1, 10 do
		s.net.remove_client(fillers[i])
	end
	s.net.generate_packets()
	expect_equal(s.net._client_shard(straggler), 1, "the straggler migrates down into shard 1")

	-- the migrated client's delegated grant still applies after the move
	s.world:set(member, s.defs.Health, 20)
	local snapshot2 = env.frame()
	env.apply(env.packet_for(snapshot2, straggler), sc)
	env.apply(env.packet_for(snapshot2, env.player_a))
	expect_equal(sc.world:get(le, sc.defs.Health), 20, "the migrated straggler still receives the delegated change")
	expect_equal(env.client.net.get_client_entity(member), nil, "player A stays excluded after the move")
end)

-- 21) grouped pair sections

-- raw section flags for a packet's sections: decode_packet's per-run
-- DecodedSection view intentionally erases the legacy/grouped distinction (a
-- lone-run grouped section and a legacy single-target section decode to the
-- same shape), so the tests below that must tell the layouts apart read the
-- section headers themselves instead -- see the grouped layout in
-- src/wire.luau.
local function raw_section_flags(packet)
	local flags_list = {}
	local data = packet.data
	local _, offset, unreplicated_count, replicated_count, names_count = read_packet_header(data)
	offset += unreplicated_count * id_width + replicated_count * gen_id_width
	for _ = 1, names_count do
		local _, _, next_offset = read_name(data, offset)
		offset = next_offset
	end
	local size = buffer.len(data)
	while offset < size do
		local flags, next_offset = read_section_header(data, offset)
		table.insert(flags_list, flags)
		offset = next_offset
	end
	return flags_list
end

-- builds a client that maps every server definition except the named one, to
-- test reconcile behavior when a relation is genuinely unmapped -- unlike
-- make_client (env.make_client), which always maps every definition.
local function make_client_missing(server, excluded_name)
	local world = jecs.world()
	local net = duplecs.client(world)
	local defs = make_defs(world)
	for name, server_def in server.defs do
		if name ~= excluded_name then
			net.set_client_entity(server_def, defs[name])
		end
	end
	net.set_client_entity(jecs.ChildOf, jecs.ChildOf)
	return { world = world, net = net, defs = defs }
end

test("a relation with several dirty targets across subjects encodes one grouped section", function(env)
	local s, c = env.server, env.client
	local e1 = s.world:entity()
	local e2 = s.world:entity()
	local t1 = s.world:entity()
	local t2 = s.world:entity()
	local t3 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(e2, s.net.Replicated)
	s.world:add(t1, s.net.Replicated)
	s.world:add(t2, s.net.Replicated)
	s.world:add(t3, s.net.Replicated)
	s.world:set(e1, pair(s.defs.Likes, t1), "v1")
	s.world:set(e1, pair(s.defs.Likes, t2), "v2")
	s.world:set(e2, pair(s.defs.Likes, t3), "v3")
	local packet = env.sync(env.player_a)

	local grouped_count = 0
	local legacy_count = 0
	for _, flags in raw_section_flags(packet) do
		if bit32.band(flags, flag_pair) ~= 0 then
			if bit32.band(flags, flag_runs) ~= 0 then
				grouped_count += 1
				expect(bit32.band(flags, flag_side_values) ~= 0, "hookless runs ride the section's side array")
			else
				legacy_count += 1
			end
		end
	end
	expect_equal(grouped_count, 1, "the relation's three targets share one grouped section")
	expect_equal(legacy_count, 0, "no target split off into a single-target section of its own")

	-- the three hookless runs concatenate into one side entry rather than claiming one each
	expect(packet.values ~= nil and #packet.values == 1, "the section claims exactly one side entry")
	expect_equal(#packet.values[1], 3, "all three runs' values ride that one entry")

	local le1 = c.net.get_client_entity(e1)
	local le2 = c.net.get_client_entity(e2)
	local lt1 = c.net.get_client_entity(t1)
	local lt2 = c.net.get_client_entity(t2)
	local lt3 = c.net.get_client_entity(t3)
	expect_equal(c.world:get(le1, pair(c.defs.Likes, lt1)), "v1", "first run reconciled")
	expect_equal(c.world:get(le1, pair(c.defs.Likes, lt2)), "v2", "second run reconciled")
	expect_equal(c.world:get(le2, pair(c.defs.Likes, lt3)), "v3", "third run, on a different subject, reconciled")
end)

test("tag-relation pairs across multiple targets reconcile via the nulled lists of grouped runs", function(env)
	local s, c = env.server, env.client
	local e1 = s.world:entity()
	local e2 = s.world:entity()
	local t1 = s.world:entity()
	local t2 = s.world:entity()
	local t3 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(e2, s.net.Replicated)
	s.world:add(t1, s.net.Replicated)
	s.world:add(t2, s.net.Replicated)
	s.world:add(t3, s.net.Replicated)
	s.world:add(e1, pair(s.defs.Targeting, t1))
	s.world:add(e1, pair(s.defs.Targeting, t2))
	s.world:add(e2, pair(s.defs.Targeting, t3))
	local packet = env.sync(env.player_a)

	local grouped_count = 0
	local legacy_count = 0
	for _, flags in raw_section_flags(packet) do
		if bit32.band(flags, flag_pair) ~= 0 then
			if bit32.band(flags, flag_runs) ~= 0 then
				grouped_count += 1
				expect(bit32.band(flags, flag_side_values) == 0, "tag runs carry no values at all")
			else
				legacy_count += 1
			end
		end
	end
	expect_equal(grouped_count, 1, "the tag relation's three targets share one grouped section")
	expect_equal(legacy_count, 0, "no target split off into a single-target section of its own")

	-- the name's claim, pinned: a tag run's subjects ride its nulled list, never an ids/values pair
	local data_t1 = packet.components[pair(s.defs.Targeting, t1)]
	expect(
		data_t1 ~= nil and data_t1.nulled ~= nil and data_t1.nulled[1] == e1,
		"the tag run carries its subject in the nulled list"
	)
	expect_equal(data_t1.ids, nil, "and no ids, so no values either")

	local le1 = c.net.get_client_entity(e1)
	local le2 = c.net.get_client_entity(e2)
	local lt1 = c.net.get_client_entity(t1)
	local lt2 = c.net.get_client_entity(t2)
	local lt3 = c.net.get_client_entity(t3)
	expect_equal(c.world:has(le1, pair(c.defs.Targeting, lt1)), true, "first tag run reconciled")
	expect_equal(c.world:has(le1, pair(c.defs.Targeting, lt2)), true, "second tag run reconciled")
	expect_equal(
		c.world:has(le2, pair(c.defs.Targeting, lt3)),
		true,
		"third tag run, on a different subject, reconciled"
	)
end)

test("inline serdes values across multiple targets of one relation round-trip through grouped runs", function(env)
	local s, c = env.server, env.client
	s.world:set(s.defs.Likes, s.net.Serdes, f64_serdes)
	c.world:set(c.defs.Likes, c.net.Serdes, f64_serdes)

	local e1 = s.world:entity()
	local e2 = s.world:entity()
	local t1 = s.world:entity()
	local t2 = s.world:entity()
	local t3 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(e2, s.net.Replicated)
	s.world:add(t1, s.net.Replicated)
	s.world:add(t2, s.net.Replicated)
	s.world:add(t3, s.net.Replicated)
	s.world:set(e1, pair(s.defs.Likes, t1), 1.5)
	s.world:set(e1, pair(s.defs.Likes, t2), 2.5)
	s.world:set(e2, pair(s.defs.Likes, t3), 3.5)
	local packet = env.sync(env.player_a)

	local grouped_count = 0
	local legacy_count = 0
	for _, flags in raw_section_flags(packet) do
		if bit32.band(flags, flag_pair) ~= 0 then
			if bit32.band(flags, flag_runs) ~= 0 then
				grouped_count += 1
				expect(bit32.band(flags, flag_side_values) == 0, "every run packed its values inline, none hookless")
			else
				legacy_count += 1
			end
		end
	end
	expect_equal(grouped_count, 1, "the relation's three targets share one grouped section")
	expect_equal(legacy_count, 0, "no target split off into a single-target section of its own")

	local le1 = c.net.get_client_entity(e1)
	local le2 = c.net.get_client_entity(e2)
	local lt1 = c.net.get_client_entity(t1)
	local lt2 = c.net.get_client_entity(t2)
	local lt3 = c.net.get_client_entity(t3)
	expect_equal(c.world:get(le1, pair(c.defs.Likes, lt1)), 1.5, "first inline run reconciled")
	expect_equal(c.world:get(le1, pair(c.defs.Likes, lt2)), 2.5, "second inline run reconciled")
	expect_equal(c.world:get(le2, pair(c.defs.Likes, lt3)), 3.5, "third inline run, on a different subject, reconciled")
end)

test("a single-target pair section still uses the legacy layout", function(env)
	local s, c = env.server, env.client
	local e1 = s.world:entity()
	local t1 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(t1, s.net.Replicated)
	s.world:set(e1, pair(s.defs.Likes, t1), "solo")
	local packet = env.sync(env.player_a)

	local grouped_count = 0
	local legacy_count = 0
	for _, flags in raw_section_flags(packet) do
		if bit32.band(flags, flag_pair) ~= 0 then
			if bit32.band(flags, flag_runs) ~= 0 then
				grouped_count += 1
			else
				legacy_count += 1
			end
		end
	end
	expect_equal(grouped_count, 0, "a lone target never pays for the grouped layout")
	expect_equal(legacy_count, 1, "the section still uses the plain single-target layout")

	local le1 = c.net.get_client_entity(e1)
	local lt1 = c.net.get_client_entity(t1)
	expect_equal(c.world:get(le1, pair(c.defs.Likes, lt1)), "solo", "the lone pair still reconciles")
end)

test("value changes, removals, and new pairs of one relation reconcile through grouped runs", function(env)
	local s, c = env.server, env.client
	local e1 = s.world:entity()
	local e2 = s.world:entity()
	local t1 = s.world:entity()
	local t2 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(e2, s.net.Replicated)
	s.world:add(t1, s.net.Replicated)
	s.world:add(t2, s.net.Replicated)
	s.world:set(e1, pair(s.defs.Likes, t1), "a")
	s.world:set(e1, pair(s.defs.Likes, t2), "b")
	env.sync(env.player_a)
	local le1 = c.net.get_client_entity(e1)
	local le2 = c.net.get_client_entity(e2)
	local lt1 = c.net.get_client_entity(t1)
	local lt2 = c.net.get_client_entity(t2)

	-- the baseline the delta below is diffed against: without it the removal assertion would hold for a
	-- client that never received the pair in the first place
	expect_equal(c.world:get(le1, pair(c.defs.Likes, lt1)), "a", "the first frame's pair to t1 reconciled")
	expect_equal(c.world:get(le1, pair(c.defs.Likes, lt2)), "b", "...and to t2, so the removal below is real")

	local t3 = s.world:entity()
	s.world:add(t3, s.net.Replicated)
	s.world:set(e1, pair(s.defs.Likes, t1), "a2") -- value change
	s.world:remove(e1, pair(s.defs.Likes, t2)) -- removal
	s.world:set(e2, pair(s.defs.Likes, t3), "c") -- new pair, to a target created this frame
	local packet = env.sync(env.player_a)

	local grouped_count = 0
	local legacy_count = 0
	for _, flags in raw_section_flags(packet) do
		if bit32.band(flags, flag_pair) ~= 0 then
			if bit32.band(flags, flag_runs) ~= 0 then
				grouped_count += 1
			else
				legacy_count += 1
			end
		end
	end
	expect_equal(grouped_count, 1, "the change, the removal, and the new pair share one grouped section")
	expect_equal(legacy_count, 0, "no cell split off into a single-target section of its own")

	-- only the two value-carrying runs claim side entries; the removal-only run claims none
	expect(packet.values ~= nil and #packet.values == 1, "the section claims exactly one side entry")
	expect_equal(#packet.values[1], 2, "the change and the new pair ride it; the removal contributes nothing")

	local lt3 = c.net.get_client_entity(t3)
	expect(lt3 ~= nil, "the new target mapped from the delta")
	expect_equal(c.world:get(le1, pair(c.defs.Likes, lt1)), "a2", "value change reconciled through a grouped run")
	expect_equal(c.world:has(le1, pair(c.defs.Likes, lt2)), false, "removal reconciled through a grouped run")
	expect_equal(c.world:get(le2, pair(c.defs.Likes, lt3)), "c", "new pair reconciled through a grouped run")
end)

test("a grouped run to a target one client never mapped leaves the other runs correctly aligned", function(env)
	local s, c = env.server, env.client
	local c2 = env.make_client()
	local e1 = s.world:entity()
	local named = s.world:entity()
	local t2 = s.world:entity()
	local t3 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:set(named, jecs.Name, "GroupRunTarget") -- replicable by Name, never given Replicated
	s.world:add(t2, s.net.Replicated)
	s.world:add(t3, s.net.Replicated)

	-- c maps the named target manually; c2 never does, so its run must skip
	-- while claiming its side entry, leaving t2's and t3's runs aligned
	local lnamed = c.world:entity()
	c.net.set_client_entity(named, lnamed)

	s.world:set(e1, pair(s.defs.Likes, named), "named-value")
	s.world:set(e1, pair(s.defs.Likes, t2), "t2-value")
	s.world:set(e1, pair(s.defs.Likes, t3), "t3-value")

	local snapshot = env.frame()
	local packet_a = env.packet_for(snapshot, env.player_a)
	local packet_b = env.packet_for(snapshot, env.player_b)
	env.apply(packet_a, c)
	expected_warning("section's pair target") -- c2 never mapped the named target its run points at
	env.apply(packet_b, c2)

	local grouped_count = 0
	local legacy_count = 0
	for _, flags in raw_section_flags(packet_a) do
		if bit32.band(flags, flag_pair) ~= 0 then
			if bit32.band(flags, flag_runs) ~= 0 then
				grouped_count += 1
			else
				legacy_count += 1
			end
		end
	end
	expect_equal(grouped_count, 1, "all three runs share one grouped section")
	expect_equal(legacy_count, 0, "the skipped target did not land in a single-target section of its own")

	-- there is only a cursor to misalign because the skipped run's value sits in the entry the other two
	-- runs read from: one shared side entry holding all three values, in run order
	expect(packet_a.values ~= nil and #packet_a.values == 1, "the section claims exactly one side entry")
	expect_equal(#packet_a.values[1], 3, "all three runs' values ride it, the unmapped target's included")

	local le1 = c.net.get_client_entity(e1)
	local lt2 = c.net.get_client_entity(t2)
	local lt3 = c.net.get_client_entity(t3)
	expect_equal(
		c.world:get(le1, pair(c.defs.Likes, lnamed)),
		"named-value",
		"the mapping client receives the named run"
	)
	expect_equal(c.world:get(le1, pair(c.defs.Likes, lt2)), "t2-value", "...and t2's run")
	expect_equal(c.world:get(le1, pair(c.defs.Likes, lt3)), "t3-value", "...and t3's run")

	local le1_b = c2.net.get_client_entity(e1)
	local lt2_b = c2.net.get_client_entity(t2)
	local lt3_b = c2.net.get_client_entity(t3)
	expect_equal(
		c2.world:get(le1_b, pair(c2.defs.Likes, lt2_b)),
		"t2-value",
		"the client without the named target still gets t2's run, correctly aligned"
	)
	expect_equal(
		c2.world:get(le1_b, pair(c2.defs.Likes, lt3_b)),
		"t3-value",
		"...and t3's run too, not shifted by the skipped run"
	)
	expect_equal(
		c2.net.get_client_entity(named),
		nil,
		"the named target stayed unmapped for the client that skipped it"
	)
end)

test(
	"a grouped section whose relation the client hasn't mapped is skipped whole, while other sections still apply",
	function(env)
		local s = env.server
		local c2 = make_client_missing(s, "Likes")
		local e1 = s.world:entity()
		local t1 = s.world:entity()
		local t2 = s.world:entity()
		s.world:add(e1, s.net.Replicated)
		s.world:add(t1, s.net.Replicated)
		s.world:add(t2, s.net.Replicated)
		s.world:set(e1, s.defs.Health, 42)
		s.world:set(e1, pair(s.defs.Likes, t1), "x")
		s.world:set(e1, pair(s.defs.Likes, t2), "y")
		expected_warning("section's relation") -- the grouped section's relation (Likes) has no client mapping for c2
		local packet = env.sync(env.player_a, c2)

		-- the skip under test is the grouped one, not two single-target sections each skipped on their own
		local grouped_count = 0
		local legacy_count = 0
		for _, flags in raw_section_flags(packet) do
			if bit32.band(flags, flag_pair) ~= 0 then
				if bit32.band(flags, flag_runs) ~= 0 then
					grouped_count += 1
				else
					legacy_count += 1
				end
			end
		end
		expect_equal(grouped_count, 1, "the two targets shared one grouped section")
		expect_equal(legacy_count, 0, "no single-target pair section carried either target")

		local le1 = c2.net.get_client_entity(e1)
		expect(le1 ~= nil, "the subject still gets mapped via the replicated list")
		expect_equal(
			c2.world:get(le1, c2.defs.Health),
			42,
			"an unrelated unpaired section in the same packet still applies"
		)
		expect_equal(c2.world:target(le1, c2.defs.Likes), nil, "the unmapped relation's grouped section left no trace")
	end
)

test(
	"a client lacking serdes hooks for an unmapped relation skips a grouped section with inline values without erroring",
	function(env)
		local s = env.server
		s.world:set(s.defs.Likes, s.net.Serdes, f64_serdes)
		local c2 = make_client_missing(s, "Likes") -- neither mapped nor given serdes hooks

		local e1 = s.world:entity()
		local t1 = s.world:entity()
		local t2 = s.world:entity()
		s.world:add(e1, s.net.Replicated)
		s.world:add(t1, s.net.Replicated)
		s.world:add(t2, s.net.Replicated)
		s.world:set(e1, s.defs.Health, 7)
		s.world:set(e1, pair(s.defs.Likes, t1), 1.5)
		s.world:set(e1, pair(s.defs.Likes, t2), 2.5)
		expected_warning("section's relation") -- the grouped section's relation (Likes) has no client mapping for c2
		local packet = env.sync(env.player_a, c2) -- must not error despite the missing hooks

		-- the section skipped here has to be the grouped, fully-inline one: its length prefix is the only thing
		-- that can size it for a reader holding no hooks of its own
		local grouped_count = 0
		local legacy_count = 0
		for _, flags in raw_section_flags(packet) do
			if bit32.band(flags, flag_pair) ~= 0 then
				if bit32.band(flags, flag_runs) ~= 0 then
					grouped_count += 1
					expect(bit32.band(flags, flag_side_values) == 0, "both runs packed their values inline")
				else
					legacy_count += 1
				end
			end
		end
		expect_equal(grouped_count, 1, "the two targets shared one grouped section")
		expect_equal(legacy_count, 0, "no single-target pair section carried either target")

		local le1 = c2.net.get_client_entity(e1)
		expect_equal(c2.world:get(le1, c2.defs.Health), 7, "the rest of the packet still reconciled")
		expect_equal(c2.world:target(le1, c2.defs.Likes), nil, "the skipped section left no trace")

		local data = packet.components[pair(s.defs.Likes, t1)]
		expect(
			data ~= nil and data.values ~= nil and data.values[1] == 1.5,
			"the section really did carry inline values, decoded here via the server's own hooks"
		)
	end
)

test(
	"a reliable section referencing an unmapped plain component skips cleanly, while other sections still apply",
	function(env)
		local s = env.server
		local c2 = make_client_missing(s, "Burning")
		local e1 = s.world:entity()
		s.world:add(e1, s.net.Replicated)
		s.world:set(e1, s.defs.Health, 42)
		s.world:add(e1, s.defs.Burning)
		expected_warning("section's component") -- the Burning component has no client mapping for c2
		env.sync(env.player_a, c2)

		local le1 = c2.net.get_client_entity(e1)
		expect(le1 ~= nil, "the subject still gets mapped via the replicated list")
		expect_equal(c2.world:get(le1, c2.defs.Health), 42, "an unrelated section in the same packet still applies")
		expect_equal(c2.world:has(le1, c2.defs.Burning), false, "the unmapped component's section left no trace")
	end
)

test("mapping a previously-unmapped component with set_client_entity lets its later changes apply", function(env)
	local s = env.server
	local c2 = make_client_missing(s, "Health")
	local e1 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:set(e1, s.defs.Health, 1)
	expected_warning("section's component") -- Health has no client mapping for c2 yet, so the initial value is skipped
	env.sync(env.player_a, c2)

	local le1 = c2.net.get_client_entity(e1)
	expect(le1 ~= nil, "the subject still mapped via the replicated list")
	expect_equal(c2.world:get(le1, c2.defs.Health), nil, "the skipped cell never applied")

	-- a second skip of the same id declares no warning of its own: the report is once per id, and the harness
	-- fails the test if a second one fires
	s.world:set(e1, s.defs.Health, 2)
	env.sync(env.player_a, c2)
	expect_equal(c2.world:get(le1, c2.defs.Health), nil, "the second skipped cell never applied either")

	-- map the id after the fact, as the caller is meant to before the server first references it; this also
	-- clears the id's unmapped_warned entry, re-arming the warning for a later skip
	c2.net.set_client_entity(s.defs.Health, c2.defs.Health)

	s.world:set(e1, s.defs.Health, 3)
	env.sync(env.player_a, c2) -- no warning this time: the mapping now resolves before the section arrives

	expect_equal(c2.world:get(le1, c2.defs.Health), 3, "the value applies now that the component id is mapped")
end)

test("pair-specific serdes on one target mixes inline and hookless runs in one grouped section", function(env)
	local s, c = env.server, env.client
	local e1 = s.world:entity()
	local t1 = s.world:entity()
	local t2 = s.world:entity()
	local t3 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(t1, s.net.Replicated)
	s.world:add(t2, s.net.Replicated)
	s.world:add(t3, s.net.Replicated)
	env.sync(env.player_a) -- map every entity before registering the pair-specific hook

	local le1 = c.net.get_client_entity(e1)
	local lt1 = c.net.get_client_entity(t1)
	local lt2 = c.net.get_client_entity(t2)
	local lt3 = c.net.get_client_entity(t3)

	-- Likes itself stays hookless; only pair(Likes, t1) gets serdes hooks
	s.world:set(s.defs.Likes, pair(s.net.Serdes, t1), f64_serdes)
	c.world:set(c.defs.Likes, pair(c.net.Serdes, lt1), f64_serdes)

	s.world:set(e1, pair(s.defs.Likes, t1), 4.5) -- inline run
	s.world:set(e1, pair(s.defs.Likes, t2), "hookless-b") -- hookless run
	s.world:set(e1, pair(s.defs.Likes, t3), "hookless-c") -- hookless run
	local packet = env.sync(env.player_a)

	local grouped_count = 0
	local legacy_count = 0
	for _, flags in raw_section_flags(packet) do
		if bit32.band(flags, flag_pair) ~= 0 then
			if bit32.band(flags, flag_runs) ~= 0 then
				grouped_count += 1
				expect(bit32.band(flags, flag_side_values) ~= 0, "the two hookless runs still ride the side array")
			else
				legacy_count += 1
			end
		end
	end
	expect_equal(grouped_count, 1, "the inline and hookless runs share one grouped section")
	expect_equal(legacy_count, 0, "no run split off into a single-target section of its own")

	-- the mix, pinned: only the hookless runs claim side entries, the inline run's value rides the buffer
	expect(packet.values ~= nil and #packet.values == 1, "the section claims exactly one side entry")
	expect_equal(#packet.values[1], 2, "two of the three runs' values ride it, not all three")

	expect_equal(c.world:get(le1, pair(c.defs.Likes, lt1)), 4.5, "the pair-specific run decoded inline")
	expect_equal(
		c.world:get(le1, pair(c.defs.Likes, lt2)),
		"hookless-b",
		"a hookless run in the same section reconciled"
	)
	expect_equal(c.world:get(le1, pair(c.defs.Likes, lt3)), "hookless-c", "the other hookless run reconciled too")
end)

test("a static-size serdes registration on a relation takes the grouped multi-target path", function(env)
	local s, c = env.server, env.client
	s.world:set(s.defs.Likes, s.net.Serdes, f64_static_serdes)
	c.world:set(c.defs.Likes, c.net.Serdes, f64_static_serdes)

	local e1 = s.world:entity()
	local t1 = s.world:entity()
	local t2 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(t1, s.net.Replicated)
	s.world:add(t2, s.net.Replicated)
	s.world:set(e1, pair(s.defs.Likes, t1), 1.5)
	s.world:set(e1, pair(s.defs.Likes, t2), 2.5)
	local packet = env.sync(env.player_a)

	local grouped_count = 0
	local legacy_count = 0
	for _, flags in raw_section_flags(packet) do
		if bit32.band(flags, flag_pair) ~= 0 then
			if bit32.band(flags, flag_runs) ~= 0 then
				grouped_count += 1
				expect(bit32.band(flags, flag_side_values) == 0, "both runs packed their values inline")
			else
				legacy_count += 1
			end
		end
	end
	expect_equal(grouped_count, 1, "the relation's two targets share one grouped section")
	expect_equal(legacy_count, 0, "no target split off into a single-target section of its own")

	local data_t1 = packet.components[pair(s.defs.Likes, t1)]
	local data_t2 = packet.components[pair(s.defs.Likes, t2)]
	expect(
		data_t1 ~= nil and data_t1.values ~= nil and data_t1.values[1] == 1.5,
		"the first target's value decoded in the merged view"
	)
	expect(
		data_t2 ~= nil and data_t2.values ~= nil and data_t2.values[1] == 2.5,
		"the second target's value decoded in the merged view"
	)

	local le1 = c.net.get_client_entity(e1)
	local lt1 = c.net.get_client_entity(t1)
	local lt2 = c.net.get_client_entity(t2)
	expect_equal(
		c.world:get(le1, pair(c.defs.Likes, lt1)),
		1.5,
		"the first target's pair value decoded via the static-size hooks"
	)
	expect_equal(
		c.world:get(le1, pair(c.defs.Likes, lt2)),
		2.5,
		"the second target's pair value decoded via the static-size hooks"
	)
end)

test("a grouped section mixes a static-size run and a sizeless run for the same relation", function(env)
	local s, c = env.server, env.client
	local e1 = s.world:entity()
	local t1 = s.world:entity()
	local t2 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(t1, s.net.Replicated)
	s.world:add(t2, s.net.Replicated)
	env.sync(env.player_a) -- map every entity before registering the pair-specific hooks

	local le1 = c.net.get_client_entity(e1)
	local lt1 = c.net.get_client_entity(t1)
	local lt2 = c.net.get_client_entity(t2)

	-- pair(Likes, t1) gets a static-size registration, pair(Likes, t2) gets a
	-- sizeless one; Likes itself stays unregistered
	s.world:set(s.defs.Likes, pair(s.net.Serdes, t1), f64_static_serdes)
	c.world:set(c.defs.Likes, pair(c.net.Serdes, lt1), f64_static_serdes)
	s.world:set(s.defs.Likes, pair(s.net.Serdes, t2), varnum_serdes)
	c.world:set(c.defs.Likes, pair(c.net.Serdes, lt2), varnum_serdes)

	s.world:set(e1, pair(s.defs.Likes, t1), 4.5) -- static-size run
	s.world:set(e1, pair(s.defs.Likes, t2), 250) -- sizeless run, the small-value branch
	local packet = env.sync(env.player_a)

	local grouped_count = 0
	local legacy_count = 0
	for _, flags in raw_section_flags(packet) do
		if bit32.band(flags, flag_pair) ~= 0 then
			if bit32.band(flags, flag_runs) ~= 0 then
				grouped_count += 1
				expect(bit32.band(flags, flag_side_values) == 0, "both runs packed their values inline")
			else
				legacy_count += 1
			end
		end
	end
	expect_equal(grouped_count, 1, "both runs share one grouped section")
	expect_equal(legacy_count, 0, "neither run split off into a single-target section of its own")

	expect_equal(c.world:get(le1, pair(c.defs.Likes, lt1)), 4.5, "the static-size run decoded correctly")
	expect_equal(c.world:get(le1, pair(c.defs.Likes, lt2)), 250, "the sizeless run decoded correctly alongside it")
end)

test("buffer-mode serdes on a relation round-trips through a grouped pair section", function(env)
	local s, c = env.server, env.client
	s.world:set(s.defs.Likes, s.net.Serdes, buffer_string_serdes)
	c.world:set(c.defs.Likes, c.net.Serdes, buffer_string_serdes)

	local e1 = s.world:entity()
	local t1 = s.world:entity()
	local t2 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(t1, s.net.Replicated)
	s.world:add(t2, s.net.Replicated)
	s.world:set(e1, pair(s.defs.Likes, t1), "buffer-a")
	s.world:set(e1, pair(s.defs.Likes, t2), "buffer-b-longer-value")
	local packet = env.sync(env.player_a)

	local grouped_count = 0
	local legacy_count = 0
	for _, flags in raw_section_flags(packet) do
		if bit32.band(flags, flag_pair) ~= 0 then
			if bit32.band(flags, flag_runs) ~= 0 then
				grouped_count += 1
				expect(bit32.band(flags, flag_side_values) == 0, "every run packed its values inline, none hookless")
			else
				legacy_count += 1
			end
		end
	end
	expect_equal(grouped_count, 1, "the relation's two targets share one grouped section")
	expect_equal(legacy_count, 0, "no target split off into a single-target section of its own")

	local le1 = c.net.get_client_entity(e1)
	local lt1 = c.net.get_client_entity(t1)
	local lt2 = c.net.get_client_entity(t2)
	expect_equal(c.world:get(le1, pair(c.defs.Likes, lt1)), "buffer-a", "first run reconciled via buffer-mode serdes")
	expect_equal(
		c.world:get(le1, pair(c.defs.Likes, lt2)),
		"buffer-b-longer-value",
		"second run reconciled via buffer-mode serdes"
	)
end)

test(
	"a grouped pair section mixes a relation-level sizeless registration with a pair-specific static-size registration",
	function(env)
		local s, c = env.server, env.client
		s.world:set(s.defs.Likes, s.net.Serdes, f64_serdes)
		c.world:set(c.defs.Likes, c.net.Serdes, f64_serdes)

		local e1 = s.world:entity()
		local t1 = s.world:entity()
		local t2 = s.world:entity()
		s.world:add(e1, s.net.Replicated)
		s.world:add(t1, s.net.Replicated)
		s.world:add(t2, s.net.Replicated)
		env.sync(env.player_a) -- map every entity before registering the pair-specific hook

		local le1 = c.net.get_client_entity(e1)
		local lt1 = c.net.get_client_entity(t1)
		local lt2 = c.net.get_client_entity(t2)

		-- pair(Likes, t1) gets a static-size registration; pair(Likes, t2) falls
		-- back to the relation's sizeless hooks -- the two runs frame their
		-- values differently (one with a length prefix, one without) within
		-- the same grouped section
		s.world:set(s.defs.Likes, pair(s.net.Serdes, t1), buffer_f64_serdes)
		c.world:set(c.defs.Likes, pair(c.net.Serdes, lt1), buffer_f64_serdes)

		s.world:set(e1, pair(s.defs.Likes, t1), 4.5) -- static-size run
		s.world:set(e1, pair(s.defs.Likes, t2), 9.5) -- sizeless run, via the relation's hooks
		local packet = env.sync(env.player_a)

		local grouped_count = 0
		local legacy_count = 0
		for _, flags in raw_section_flags(packet) do
			if bit32.band(flags, flag_pair) ~= 0 then
				if bit32.band(flags, flag_runs) ~= 0 then
					grouped_count += 1
					expect(bit32.band(flags, flag_side_values) == 0, "both runs packed their values inline")
				else
					legacy_count += 1
				end
			end
		end
		expect_equal(grouped_count, 1, "both runs share one grouped section")
		expect_equal(legacy_count, 0, "neither run split off into a single-target section of its own")

		expect_equal(c.world:get(le1, pair(c.defs.Likes, lt1)), 4.5, "the static-size run decoded correctly")
		expect_equal(
			c.world:get(le1, pair(c.defs.Likes, lt2)),
			9.5,
			"the sizeless run decoded correctly via the relation's fallback hooks"
		)
	end
)

-- 22) shared name mapping

test("a named component auto-maps onto a same-named client component without set_client_entity", function(env)
	local s, c = env.server, env.client
	local new_comp = s.world:component()
	s.world:set(new_comp, jecs.Name, "AutoHealth")
	s.world:add(new_comp, s.net.Networked) -- announces "AutoHealth" as a delta this frame

	-- the client defines the same name, but is never told about new_comp manually
	local client_comp = c.world:component()
	c.world:set(client_comp, jecs.Name, "AutoHealth")

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, new_comp, 55)
	local packet = env.sync(env.player_a)

	expect_equal(packet.names[new_comp], "AutoHealth", "the delta carries the announcement")
	expect_equal(c.net.get_client_entity(new_comp), client_comp, "the definition auto-mapped by name")
	local le = c.net.get_client_entity(e)
	expect_equal(c.world:get(le, client_comp), 55, "the value reconciled onto the client's own definition")
end)

test("a late joiner's full packet carries the announced names and auto-maps", function(env)
	local s = env.server
	local new_comp = s.world:component()
	s.world:set(new_comp, jecs.Name, "AutoJoinComp")
	s.world:add(new_comp, s.net.Networked)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, new_comp, 7)
	expected_warning("section's component") -- env.client has no same-named entity, so new_comp went unmapped
	env.sync(env.player_a) -- drain the announcement and value to the existing client first

	local c2 = env.make_client()
	local client_comp = c2.world:component()
	c2.world:set(client_comp, jecs.Name, "AutoJoinComp")

	local player_c = fake_player("PlayerC")
	s.net.add_client(player_c)
	local snapshot = env.frame()
	local packet = env.packet_for(snapshot, player_c)
	env.apply(packet, c2)

	expect_equal(packet.names[new_comp], "AutoJoinComp", "the full packet carries the announced name")
	-- the announcement itself was spent on the earlier frame, so the joiner learns the name from the full
	-- packet's whole announced set rather than from a re-announcement the population would see again
	local packet_a = env.packet_for(snapshot, env.player_a)
	expect_equal(packet_a.names[new_comp], nil, "the already-announced name is not re-announced to A")
	expect_equal(c2.net.get_client_entity(new_comp), client_comp, "the joiner auto-mapped the definition by name")
	local le = c2.net.get_client_entity(e)
	expect_equal(c2.world:get(le, client_comp), 7, "the value reconciled end to end")
end)

test("a named unreplicated pair target auto-maps when a tracked pair first references it", function(env)
	local s, c = env.server, env.client
	local target = s.world:entity() -- named, but never Replicated
	s.world:set(target, jecs.Name, "AutoPairTarget")

	-- the client's same-named entity is never set_client_entity'd
	local client_target = c.world:entity()
	c.world:set(client_target, jecs.Name, "AutoPairTarget")

	local e1 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:set(e1, pair(s.defs.Likes, target), "v")
	local packet = env.sync(env.player_a)

	-- the mapping has to come from the announcement the pair made relevant, not from a creation entry
	expect_equal(packet.names[target], "AutoPairTarget", "the pair reference announced the target's name")
	expect_equal(table.find(packet.replicated, target), nil, "the target never rides a creation entry")
	expect_equal(c.net.get_client_entity(target), client_target, "the target auto-mapped by name")
	local le1 = c.net.get_client_entity(e1)
	expect_equal(c.world:get(le1, pair(c.defs.Likes, client_target)), "v", "the pair reconciled onto the mapped target")
end)

test("a manual mapping to a different client entity wins over the announced name", function(env)
	local s, c = env.server, env.client
	local new_comp = s.world:component()
	s.world:set(new_comp, jecs.Name, "ManualWins")
	s.world:add(new_comp, s.net.Networked)

	local same_named = c.world:component() -- shares the name, but must be ignored
	c.world:set(same_named, jecs.Name, "ManualWins")
	local manual_target = c.world:component()
	c.net.set_client_entity(new_comp, manual_target) -- map to a different entity before any packet arrives

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, new_comp, 9)
	local packet = env.sync(env.player_a)

	-- anchors the scenario: the announcement really did ride this packet, so what follows is precedence rather
	-- than a name that was never announced in the first place
	expect_equal(packet.names[new_comp], "ManualWins", "the announcement rode the delta")
	expect_equal(c.net.get_client_entity(new_comp), manual_target, "the manual mapping still holds")
	expect_equal(c.net.get_server_entity(manual_target), new_comp, "the reverse mapping still names the definition")
	local le = c.net.get_client_entity(e)
	expect_equal(c.world:get(le, manual_target), 9, "the value applied to the manually mapped entity")
	expect_equal(c.world:get(le, same_named), nil, "the same-named entity received nothing")
	expect_equal(c.net.get_server_entity(same_named), nil, "the same-named entity was never mapped at all")
end)

test(
	"a names entry colliding with an entity already mapped to a different server entity warns and leaves the mapping untouched",
	function(env)
		local s, c = env.server, env.client
		local comp_a = s.world:component()
		s.world:set(comp_a, jecs.Name, "Collide")
		local comp_b = s.world:component()
		s.world:set(comp_b, jecs.Name, "Collide")

		local only_named = c.world:component()
		c.world:set(only_named, jecs.Name, "Collide")

		s.world:add(comp_a, s.net.Networked)
		env.sync(env.player_a) -- comp_a auto-maps onto only_named
		expect_equal(c.net.get_client_entity(comp_a), only_named, "the first announcement mapped by name")

		s.world:add(comp_b, s.net.Networked)
		expected_warning("already mapped to server entity")
		env.sync(env.player_a) -- comp_b's announced name collides with the already-mapped only_named

		expect_equal(c.net.get_client_entity(comp_b), nil, "the colliding server entity stays unmapped")
		expect_equal(c.net.get_client_entity(comp_a), only_named, "the existing mapping is untouched")
	end
)

test("a client with no same-named entity skips the announcement, other sections still apply", function(env)
	local s, c = env.server, env.client
	local new_comp = s.world:component()
	s.world:set(new_comp, jecs.Name, "NoLocalMatch")
	s.world:add(new_comp, s.net.Networked)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, new_comp, 3)
	s.world:set(e, s.defs.Health, 12)
	expected_warning("section's component") -- the announcement is skipped silently, but new_comp stays unmapped
	local packet = env.sync(env.player_a)

	-- the server did announce: the skip is the client failing to resolve the name, not the server withholding it
	expect_equal(packet.names[new_comp], "NoLocalMatch", "the announcement still shipped")
	expect_equal(c.net.get_client_entity(new_comp), nil, "no client entity shares the name, so the entry is skipped")
	local le = c.net.get_client_entity(e)
	expect_equal(c.world:get(le, c.defs.Health), 12, "an unrelated unpaired section in the same packet still applies")
end)

test(
	"live Name tracking makes a pair to an unreplicated target visible, then invisible, as the target is (un)named",
	function(env)
		local s, c = env.server, env.client
		local target = s.world:entity() -- unnamed, unreplicated: invisible target
		local e1 = s.world:entity()
		s.world:add(e1, s.net.Replicated)
		s.world:set(e1, pair(s.defs.Likes, target), "hidden")
		local packet = env.sync(env.player_a)
		-- e1's own creation anchors the packet as a real one, so the empty section view below is a genuine
		-- absence rather than the harness's blank-packet fallback
		expect_equal(packet.replicated[1], e1, "e1's creation rode the packet")
		expect_equal(next(packet.components), nil, "a pair to an unnamed, unreplicated target stays invisible")

		local client_target = c.world:entity()
		c.world:set(client_target, jecs.Name, "LateNamed")

		s.world:set(target, jecs.Name, "LateNamed")
		local named_packet = env.sync(env.player_a)

		expect_equal(named_packet.names[target], "LateNamed", "naming the target announces it")
		expect_equal(c.net.get_client_entity(target), client_target, "the target auto-mapped by name once it was named")
		local le1 = c.net.get_client_entity(e1)
		expect_equal(
			c.world:get(le1, pair(c.defs.Likes, client_target)),
			"hidden",
			"the pair became visible and reconciled"
		)

		local likes_target = pair(s.defs.Likes, target) -- captured while the target is still named
		s.world:remove(target, jecs.Name)
		local unnamed_packet = env.sync(env.player_a)

		-- the tracked removal is what clears the pair, with the retraction riding the same packet behind it: the
		-- client-side absence below would also fall out of the retraction's sweep alone, so both are pinned here
		local data = unnamed_packet.components[likes_target]
		expect(
			data ~= nil and data.removed ~= nil and data.removed[1] == e1,
			"unnaming the target ships an explicit pair removal"
		)
		expect_equal(unnamed_packet.names[target], "", "the withdrawal rides as a retraction")
		expect_equal(
			c.world:has(le1, pair(c.defs.Likes, client_target)),
			false,
			"removing the name makes the pair invisible again, removing it on the client"
		)
		expect_equal(c.net.get_client_entity(target), nil, "the retraction ends the name-established mapping")
		expect_equal(c.world:contains(client_target), true, "the client's own named entity is never deleted")
	end
)

test("renaming an auto-mapped definition re-announces the new name while keeping the mapping", function(env)
	local s, c = env.server, env.client
	local new_comp = s.world:component()
	s.world:set(new_comp, jecs.Name, "OldName")
	s.world:add(new_comp, s.net.Networked)

	local same_named = c.world:component()
	c.world:set(same_named, jecs.Name, "OldName")

	env.sync(env.player_a) -- auto-maps via the initial announcement
	expect_equal(c.net.get_client_entity(new_comp), same_named, "the definition auto-mapped")

	s.world:set(new_comp, jecs.Name, "NewName")
	local packet = env.sync(env.player_a)

	expect_equal(packet.names[new_comp], "NewName", "the rename re-announces under the new name")
	expect_equal(c.net.get_client_entity(new_comp), same_named, "the existing mapping survives the rename")

	-- the surviving mapping is still live, not merely still in the table: nothing on the client is named
	-- "NewName", so data landing on the same client definition can only be the pre-rename mapping at work
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, new_comp, 3)
	env.sync(env.player_a)
	expect_equal(c.world:get(c.net.get_client_entity(e), same_named), 3, "the renamed definition still reconciles")
end)

test("a definition that becomes Replicated stops being announced, arriving via the create list instead", function(env)
	local s = env.server
	local new_comp = s.world:component()
	s.world:set(new_comp, jecs.Name, "TurnsReplicated")
	s.world:add(new_comp, s.net.Networked)
	-- a control that stays Networked throughout, so the missing entry below reads as a withdrawal rather than as
	-- a full packet that stopped carrying names at all
	local stays_named = s.world:component()
	s.world:set(stays_named, jecs.Name, "StaysNetworked")
	s.world:add(stays_named, s.net.Networked)
	-- no data ever ships for either definition here, so env.client's unresolved announcements are skipped silently
	env.sync(env.player_a) -- drain the initial announcements to the existing client

	s.world:remove(new_comp, s.net.Networked)
	s.world:add(new_comp, s.net.Replicated)

	local c2 = env.make_client()
	local player_c = fake_player("PlayerC")
	local packet = env.join(player_c, c2)

	expect_equal(packet.names[new_comp], nil, "the announced name is withdrawn once the definition is replicated")
	expect_equal(packet.names[stays_named], "StaysNetworked", "the still-networked control is announced as ever")
	expect(c2.net.get_client_entity(new_comp) ~= nil, "the entity still arrives, via the replicated create list")
end)

-- 23) named pair target death

test("a named unreplicated pair target's death replicates an explicit pair removal", function(env)
	-- companion to "deleting a pair's target omits the redundant pair removal..." (section 5): that
	-- test's target is Replicated, so the client deletes it wholesale and the pair auto-removes with
	-- it. a named (unreplicated) target is owned by the client world and never deleted by
	-- reconciliation, so the server must ship an explicit removal instead. Likes is a data relation
	-- (never a tag pair), sidestepping the jecs 0.9 tag-pair cleanup bug on target deletion.
	local s, c = env.server, env.client
	local target = s.world:entity() -- named, never Replicated
	s.world:set(target, jecs.Name, "DyingNamedTarget")

	-- the client's same-named entity is never set_client_entity'd; it auto-maps
	local client_target = c.world:entity()
	c.world:set(client_target, jecs.Name, "DyingNamedTarget")

	local subject = s.world:entity()
	s.world:add(subject, s.net.Replicated)
	s.world:set(subject, pair(s.defs.Likes, target), "v1")
	env.sync(env.player_a)

	expect_equal(c.net.get_client_entity(target), client_target, "the target auto-mapped by name")
	local le_subject = c.net.get_client_entity(subject)
	expect_equal(
		c.world:get(le_subject, pair(c.defs.Likes, client_target)),
		"v1",
		"the pair reconciled before the target dies"
	)

	local likes_target = pair(s.defs.Likes, target) -- captured before the target dies
	s.world:delete(target)
	local packet = env.sync(env.player_a)

	local data = packet.components[likes_target]
	expect(data ~= nil and data.removed ~= nil and data.removed[1] == subject, "the removal names the dying pair")
	expect_equal(data.target, jecs.ECS_ID(target), "the removal carries the target's dense id")

	expect_equal(c.world:has(le_subject, pair(c.defs.Likes, client_target)), false, "the pair is removed on the client")
	expect_equal(c.world:contains(client_target), true, "the client's own named entity is not touched")
	expect_equal(c.world:get(client_target, jecs.Name), "DyingNamedTarget", "the client entity keeps its name")
	expect_equal(c.net.get_client_entity(target), nil, "the retraction ends the mapping after the removals applied")
end)

test("a Replicated pair target's death still sends no explicit pair removal", function(env)
	local s, c = env.server, env.client
	local target = s.world:entity()
	s.world:add(target, s.net.Replicated)

	local subject = s.world:entity()
	s.world:add(subject, s.net.Replicated)
	s.world:set(subject, pair(s.defs.Likes, target), "v1")
	env.sync(env.player_a)

	local le_subject = c.net.get_client_entity(subject)
	local le_target = c.net.get_client_entity(target)
	expect_equal(
		c.world:get(le_subject, pair(c.defs.Likes, le_target)),
		"v1",
		"the pair reconciled before the target dies"
	)

	local likes_target = pair(s.defs.Likes, target) -- captured before the target dies
	s.world:delete(target)
	local packet = env.sync(env.player_a)

	expect_equal(packet.unreplicated[1], target, "the target's deletion is announced via the unreplicated list")
	expect_equal(
		packet.components[likes_target],
		nil,
		"no explicit pair removal ships; the client's wholesale delete of the target covers it"
	)

	expect_equal(c.world:has(le_subject, pair(c.defs.Likes, le_target)), false, "the pair is gone on the client")
	expect_equal(c.world:contains(le_target), false, "the client's local target entity is deleted wholesale")
	-- and the mapping ends with it: get_client_entity never checks liveness, so a leaked entry would keep
	-- resolving to the dead client entity forever
	expect_equal(c.net.get_client_entity(target), nil, "the mapping ends with the client entity")
end)

test("a staged pair value change does not leak past the target's death in the same frame", function(env)
	local s, c = env.server, env.client
	local target = s.world:entity()
	s.world:set(target, jecs.Name, "DyingValueTarget")
	local client_target = c.world:entity()
	c.world:set(client_target, jecs.Name, "DyingValueTarget")

	local subject = s.world:entity()
	s.world:add(subject, s.net.Replicated)
	s.world:set(subject, pair(s.defs.Likes, target), "v1")
	env.sync(env.player_a)

	-- anchors the scenario: the pair really was on the client as v1, so its absence at the end is a removal
	-- rather than a cell that never arrived
	local le_subject = c.net.get_client_entity(subject)
	expect_equal(c.net.get_client_entity(target), client_target, "the target auto-mapped by name")
	expect_equal(c.world:get(le_subject, pair(c.defs.Likes, client_target)), "v1", "the pair reconciled as v1")

	local likes_target = pair(s.defs.Likes, target) -- captured before the target dies
	s.world:set(subject, pair(s.defs.Likes, target), "v2")
	s.world:delete(target)
	local packet = env.sync(env.player_a)

	local data = packet.components[likes_target]
	expect(data ~= nil and data.removed ~= nil and data.removed[1] == subject, "the removal still ships")
	expect_equal(data.ids, nil, "no id/value send should ship for a pair whose target died this frame")
	expect_equal(data.values, nil, "the staged v2 change must not leak past the removal")

	expect_equal(
		c.world:has(le_subject, pair(c.defs.Likes, client_target)),
		false,
		"the pair is removed on the client, never updated to v2"
	)
end)

test("only a pair's prior viewers receive its named target's death removal", function(env)
	local s, c = env.server, env.client
	local target = s.world:entity()
	s.world:set(target, jecs.Name, "PrivateDyingTarget")
	local client_target = c.world:entity()
	c.world:set(client_target, jecs.Name, "PrivateDyingTarget")

	local subject = s.world:entity()
	s.world:add(subject, s.net.Replicated)
	s.world:set(subject, pair(s.defs.Likes, target), "v1")
	-- a per-component whitelist admits only player_a to the Likes relation
	s.world:set(subject, pair(s.net.Private, s.defs.Likes), { [env.player_a] = true })

	local likes_target = pair(s.defs.Likes, target) -- captured while the target is still alive
	local initial = env.frame()
	env.apply(env.packet_for(initial, env.player_a))
	local le_subject = c.net.get_client_entity(subject)
	expect_equal(
		c.world:get(le_subject, pair(c.defs.Likes, client_target)),
		"v1",
		"A saw the pair before the target dies"
	)
	-- B's own packet is real (the subject entity itself is unrestricted), which is what makes the missing Likes
	-- section an exclusion rather than an absent packet
	local initial_b = env.packet_for(initial, env.player_b)
	expect_equal(initial_b.replicated[1], subject, "B sees the subject entity itself")
	expect_equal(initial_b.components[likes_target], nil, "B was never admitted to the pair")

	s.world:delete(target)
	local final = env.frame()

	local data_a = env.packet_for(final, env.player_a).components[likes_target]
	expect(data_a ~= nil and data_a.removed ~= nil and data_a.removed[1] == subject, "A gets the explicit removal")

	-- names are schema, never gated by privacy, so B receives the retraction and their packet is a real one
	local packet_b = env.packet_for(final, env.player_b)
	expect_equal(packet_b.names[target], "", "B receives the target's retraction")
	expect_equal(packet_b.components[likes_target], nil, "B, who was never admitted to the pair, gets no removal")
end)

-- 24) shared-name retraction provenance and edge cases

test("a retraction never ends a manually mapped id, regardless of generation", function(env)
	local s, c = env.server, env.client
	local target = s.world:entity() -- named, never Replicated
	s.world:set(target, jecs.Name, "ManuallyMappedTarget")

	-- deliberately not named the same on the client, so name resolution can
	-- never be the cause of the mapping below
	local manual_local = c.world:entity()
	c.net.set_client_entity(target, manual_local)

	local subject = s.world:entity()
	s.world:add(subject, s.net.Replicated)
	s.world:set(subject, pair(s.defs.Likes, target), "v1") -- indexes target, announcing its name
	local announced = env.sync(env.player_a)

	-- the announcement carries the mapping's own generation, so provenance -- not the generation check -- is the
	-- only thing that can be keeping the manual mapping alive
	expect_equal(announced.names[target], "ManuallyMappedTarget", "the announcement really rode the packet")
	expect_equal(c.net.get_client_entity(target), manual_local, "the announcement left the manual mapping alone")
	local le_subject = c.net.get_client_entity(subject)
	expect_equal(c.world:get(le_subject, pair(c.defs.Likes, manual_local)), "v1", "the pair rode the manual mapping")

	-- dropping the pair empties target's tracked bucket, retracting the name
	s.world:remove(subject, pair(s.defs.Likes, target))
	local retracted = env.sync(env.player_a)

	expect_equal(retracted.names[target], "", "the emptied bucket really did retract the name")
	expect_equal(
		c.net.get_client_entity(target),
		manual_local,
		"the retraction is a no-op: this mapping was never name-established"
	)
end)

test(
	"a named target that becomes Replicated keeps a viewing client's mapping via adoption, but evicts one it stays invisible to",
	function(env)
		local s, c = env.server, env.client
		local c2 = env.make_client()
		local target = s.world:entity() -- named, unreplicated at first
		s.world:set(target, jecs.Name, "PromotedTarget")

		local client_target = c.world:entity()
		c.world:set(client_target, jecs.Name, "PromotedTarget")
		local client2_target = c2.world:entity()
		c2.world:set(client2_target, jecs.Name, "PromotedTarget")

		local subject = s.world:entity()
		s.world:add(subject, s.net.Replicated)
		s.world:set(subject, pair(s.defs.Likes, target), "v1")
		local initial = env.frame()
		env.apply(env.packet_for(initial, env.player_a))
		env.apply(env.packet_for(initial, env.player_b), c2)

		expect_equal(c.net.get_client_entity(target), client_target, "A auto-mapped the target by name")
		expect_equal(c2.net.get_client_entity(target), client2_target, "B auto-mapped the target by name")
		local le_subject = c.net.get_client_entity(subject)
		local le2_subject = c2.net.get_client_entity(subject)
		expect_equal(c.world:get(le_subject, pair(c.defs.Likes, client_target)), "v1", "A holds the pair")
		expect_equal(c2.world:get(le2_subject, pair(c2.defs.Likes, client2_target)), "v1", "B holds the pair")

		-- the target becomes Replicated, but an entity-level whitelist admits
		-- only A: A's client receives the creation (adopting the mapping out of
		-- name provenance) while B never does
		s.world:add(target, s.net.Replicated)
		s.world:set(target, s.net.Private, { [env.player_a] = true })
		local final = env.frame()
		local packet_a = env.packet_for(final, env.player_a)
		local packet_b = env.packet_for(final, env.player_b)
		env.apply(packet_a)
		env.apply(packet_b, c2)

		expect_equal(packet_a.replicated[1], target, "A receives the target's creation")
		-- both packets carry the withdrawal, so A's surviving mapping is adoption at work rather than a retraction
		-- that never reached them -- and B's packet being a real one is what makes their empty list an absence
		expect_equal(packet_a.names[target], "", "A's packet carries the retraction too")
		expect_equal(packet_b.names[target], "", "B's packet carries the retraction")
		expect_equal(#packet_b.replicated, 0, "B never receives the creation, the entity whitelist excludes them")

		expect_equal(
			c.net.get_client_entity(target),
			client_target,
			"A's mapping survives: the creation adopted it before the retraction applied"
		)
		expect_equal(
			c.world:get(le_subject, pair(c.defs.Likes, client_target)),
			"v1",
			"A's pair rides the adopted mapping unchanged"
		)
		expect_equal(
			c2.net.get_client_entity(target),
			nil,
			"B's mapping is evicted: the retraction reaches a client who never adopted it via creation"
		)
		expect_equal(
			c2.world:has(le2_subject, pair(c2.defs.Likes, client2_target)),
			false,
			"B's pair goes with the target they can no longer see"
		)
	end
)

test("creation adoption refreshes the stored generation for a recycled dense id", function(env)
	local s, c = env.server, env.client
	local e1 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	env.sync(env.player_a)
	local le1 = c.net.get_client_entity(e1)
	expect_equal(c.net.get_server_entity(le1), e1, "the initial mapping stores e1's generation")

	s.world:delete(e1)
	env.sync(env.player_a) -- deletes the mapping client-side entirely
	expect_equal(c.world:contains(le1), false, "the first tenant's client entity went with the deletion")

	-- a stale-gen manual mapping, predicting the recycled dense id's next tenant
	local predicted = c.world:entity()
	c.net.set_client_entity(e1, predicted)

	local e2 = s.world:entity()
	expect(
		jecs.ECS_ID(e2) == jecs.ECS_ID(e1) and e2 ~= e1,
		"precondition: jecs did not recycle the deleted id, scenario cannot be tested"
	)
	s.world:add(e2, s.net.Replicated)
	s.world:set(e2, s.defs.Health, 7)
	env.sync(env.player_a) -- the creation adopts the manually mapped client entity

	expect_equal(c.net.get_client_entity(e2), predicted, "the creation adopted the manually mapped client entity")
	expect_equal(c.net.get_server_entity(predicted), e2, "adoption refreshed the stored generation to e2's")
	expect_equal(c.world:get(predicted, c.defs.Health), 7, "e2's data reconciles onto the adopted client entity")
end)

test("a networked definition with an empty jecs.Name warns and is never announced", function(env)
	local s, c = env.server, env.client
	local new_comp = s.world:component()
	s.world:set(new_comp, jecs.Name, "")
	expected_warning("shared names must not be empty!")
	s.world:add(new_comp, s.net.Networked) -- the shared-name store warns and skips the empty name

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, new_comp, 5)
	expected_warning("section's component") -- the never-announced definition's own section has no client mapping either
	local packet = env.sync(env.player_a)

	expect_equal(packet.names[new_comp], nil, "an empty name is never announced")
	expect_equal(c.net.get_client_entity(new_comp), nil, "the definition never auto-maps without an announcement")
end)

test("a name refused at announce time announces once it's fixed", function(env)
	-- on_name_changed used to only re-announce ids that were already announced
	-- (the store's announced_id(dense) == entity), so a tracked definition whose
	-- name the store refused at tracking time (too long, here) stayed permanently
	-- unannounced even after the name was corrected. on_name_changed now
	-- re-derives announce-relevance with the same condition on_name_added uses,
	-- so the fix reaches the wire.
	local s, c = env.server, env.client
	local new_comp = s.world:component()
	s.world:set(new_comp, jecs.Name, string.rep("x", 300)) -- too long for the wire's u8 length
	expected_warning("shared names must be at most 255 bytes!")
	s.world:add(new_comp, s.net.Networked) -- the shared-name store warns and records nothing

	-- the client holds the corrected name up front, so the late announcement is followed all the way to a usable
	-- mapping rather than checked only as a names entry on the wire
	local client_comp = c.world:component()
	c.world:set(client_comp, jecs.Name, "FixedName")

	s.world:set(new_comp, jecs.Name, "FixedName")
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, new_comp, 8)
	local packet = env.sync(env.player_a)

	expect_equal(packet.names[new_comp], "FixedName", "the corrected name announces once fixed")
	expect_equal(c.net.get_client_entity(new_comp), client_comp, "the late announcement maps on arrival")
	expect_equal(c.world:get(c.net.get_client_entity(e), client_comp), 8, "the definition's data reconciles")
end)

-- 25) mark_client_fresh

test("marking a client fresh replaces their delta with a full packet", function(env)
	local s, c = env.server, env.client
	local e1 = s.world:entity()
	local e2 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(e2, s.net.Replicated)
	s.world:set(e1, s.defs.Health, 100)
	env.sync(env.player_a) -- e1 and e2 are already visible to player_a

	-- a normal delta change and a fresh mark land in the same frame
	s.world:set(e1, s.defs.Health, 55)
	s.net.mark_client_fresh(env.player_a)
	local snapshot = env.frame()
	local packet = env.packet_for(snapshot, env.player_a)
	env.apply(packet)

	-- a delta's replicated list only names entities newly becoming visible this
	-- frame (none here, both already exist); a full packet names every entity
	-- currently visible, which is the signal that the swap took effect
	expect_equal(#packet.replicated, 2, "a full packet names every currently-visible entity, not just the changed one")
	local seen = {}
	for _, entity in packet.replicated do
		seen[entity] = true
	end
	expect(seen[e1] and seen[e2], "both visible entities appear in the full packet's creation list")

	-- the mark is per client: player_b, unmarked, still receives the ordinary delta for the same frame
	local packet_b = env.packet_for(snapshot, env.player_b)
	expect_equal(#packet_b.replicated, 0, "the unmarked client's packet is still a delta")
	local health_b = packet_b.components[s.defs.Health]
	expect(health_b ~= nil and health_b.ids ~= nil and health_b.ids[1] == e1, "B receives only the changed cell")

	local le1 = c.net.get_client_entity(e1)
	expect_equal(
		c.world:get(le1, c.defs.Health),
		55,
		"the fresh client's full packet still carries the frame's own change"
	)
end)

test(
	"a fresh mark's full packet resyncs a fresh world onto exactly the slot's current visibility, then deltas continue correctly",
	function(env)
		local s = env.server
		local slot = fake_player("Slot1")
		s.net.add_client(slot)

		local e_public = s.world:entity()
		local e_admitted = s.world:entity()
		local e_excluded = s.world:entity()
		s.world:add(e_public, s.net.Replicated)
		s.world:add(e_admitted, s.net.Replicated)
		s.world:add(e_excluded, s.net.Replicated)
		s.world:set(e_public, s.defs.Health, 10)
		s.world:set(e_admitted, s.defs.Health, 20)
		s.world:set(e_excluded, s.defs.Health, 30)
		-- a component whitelist admitting only the slot, and an entity-level
		-- blacklist excluding it outright
		s.world:set(e_admitted, pair(s.net.Private, s.defs.Health), { [slot] = true })
		s.world:set(e_excluded, s.net.Private, { [slot] = false })

		env.frame() -- allocates the slot and builds its own join full packet, discarded

		-- a few frames of deltas nobody reconciles for the slot: only its
		-- server-side allocation exists right now, exactly as a persistent slot
		-- kept allocated across a disconnect
		s.world:set(e_public, s.defs.Health, 11)
		env.frame()
		s.world:set(e_public, s.defs.Health, 12)
		env.frame()

		-- the slot's privacy state is edited while "vacant": no client world
		-- currently holds it, only the server-side slot
		s.net.edit_component_privacy(e_admitted, s.defs.Health, slot, false)

		s.net.mark_client_fresh(slot)
		local packets = env.frame()
		local full = packets[slot]

		-- the full describes the slot's current visibility outright: the two entities it can see, no deletes, and
		-- only the surviving Health cell -- a revoked component is absent from a full, never a removal inside one
		expect_equal(#full.replicated, 2, "the full names exactly the entities the slot can currently see")
		expect_equal(#full.unreplicated, 0, "a full packet carries no deletes")
		local health = full.components[s.defs.Health]
		expect(health ~= nil and health.ids ~= nil and #health.ids == 1, "exactly one Health cell rides the full")
		expect_equal(health.ids[1], e_public, "the revoked Health is simply absent from the full")
		expect_equal(health.removed, nil, "and it never ships as a removal either")

		-- a fresh connection takes the slot over and reconciles only the full
		local c2 = env.make_client()
		c2.net.reconcile_packet(full)

		local le_public = c2.net.get_client_entity(e_public)
		local le_admitted = c2.net.get_client_entity(e_admitted)
		local le_excluded = c2.net.get_client_entity(e_excluded)

		expect(le_public ~= nil, "the public entity is present in the fresh world")
		expect_equal(c2.world:get(le_public, c2.defs.Health), 12, "the fresh world reflects the latest value")
		expect(le_admitted ~= nil, "the entity itself is unrestricted and so is present")
		expect_equal(c2.world:has(le_admitted, c2.defs.Health), false, "Health was revoked before the full was built")
		expect_equal(le_excluded, nil, "the entity-level-excluded entity never reaches the fresh world")

		-- continuity: the next delta applies on top of the fresh world with no
		-- duplicate creation, and values keep updating correctly
		s.world:set(e_public, s.defs.Health, 13)
		s.world:set(e_admitted, s.defs.Health, 21) -- still hidden from the slot
		local delta_packets = env.frame()
		local delta = delta_packets[slot]
		c2.net.reconcile_packet(delta)

		-- an unwanted re-creation would be silently adopted by the existing mapping, so the creation list itself
		-- is what has to be empty here, not just the resulting entity
		expect_equal(#delta.replicated, 0, "the delta re-creates nothing: the slot's baseline survived the full")
		expect_equal(c2.net.get_client_entity(e_public), le_public, "no duplicate entity created for the public entity")
		expect_equal(c2.world:get(le_public, c2.defs.Health), 13, "the delta updates the value on the fresh world")
		expect_equal(c2.world:has(le_admitted, c2.defs.Health), false, "the still-hidden component remains absent")
	end
)

test("marking a pending client fresh is a silent no-op", function(env)
	local s = env.server
	local pending = fake_player("PendingFull")
	s.net.add_client(pending)
	s.net.mark_client_fresh(pending) -- a no-op: their join already produces a full

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 5)

	local packets = s.net.generate_packets()
	expect(packets[pending] ~= nil, "the pending client still receives exactly one packet: their join full")
	local decoded = decode_packet(packets[pending])
	expect_equal(#decoded.replicated, 1, "the join full carries the currently-visible entity")
	expect_equal(decoded.replicated[1], e, "the join full names the entity")
end)

test("marking an untracked client fresh warns and does nothing", function(env)
	local s = env.server
	local stranger = fake_player("NeverAdded") -- never passed to add_client

	expected_warning("cannot mark an untracked client fresh!")
	s.net.mark_client_fresh(stranger)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 5)

	local packets = s.net.generate_packets()
	expect_equal(packets[stranger], nil, "an untracked client never receives a packet")
end)

test("remove_client clears a fresh mark", function(env)
	local s = env.server
	local departing = fake_player("Departing")
	s.net.add_client(departing)
	env.frame() -- allocate departing

	s.net.mark_client_fresh(departing)
	s.net.remove_client(departing)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, s.defs.Health, 5)

	local packets = s.net.generate_packets()
	expect_equal(packets[departing], nil, "no packet for the removed client")
	expect(packets[env.player_a] ~= nil, "other clients are unaffected")
end)

-- 26) NetworkedUnreliable (always-replicate mode)

-- shared by the tests below: creates a fresh component tracked via
-- NetworkedUnreliable end to end, with the given serdes hooks (f64_serdes by
-- default) assigned on both sides -- unlike NetworkedOnce, chunk values
-- require hooks, so every unreliable test needs a serdes-backed component.
local function make_unreliable_component(env, serdes)
	local s, c = env.server, env.client
	local serdes_hooks = serdes or f64_serdes
	local comp_s = s.world:component()
	local comp_c = c.world:component()
	c.net.set_client_entity(comp_s, comp_c)
	s.world:set(comp_s, s.net.Serdes, serdes_hooks)
	c.world:set(comp_c, c.net.Serdes, serdes_hooks)
	s.world:add(comp_s, s.net.NetworkedUnreliable)
	return comp_s, comp_c
end

-- like make_unreliable_component, but for a relation (mirroring the ad hoc
-- NetworkedOnce relation tests above): its pairs stream through the
-- unreliable channel using the relation's own serdes hooks.
local function make_unreliable_relation(env, serdes)
	local s, c = env.server, env.client
	local serdes_hooks = serdes or f64_serdes
	local rel_s = s.world:component()
	local rel_c = c.world:component()
	c.net.set_client_entity(rel_s, rel_c)
	s.world:set(rel_s, s.net.Serdes, serdes_hooks)
	c.world:set(rel_c, c.net.Serdes, serdes_hooks)
	s.world:add(rel_s, s.net.NetworkedUnreliable)
	return rel_s, rel_c
end

-- decodes every chunk in `list` (nil-safe, for a client with nothing visible)
-- and reports whether `dense_id` appears in any section's ids or nulled list;
-- shared by the privacy tests below to inspect a client's raw chunks. every
-- unreliable component in this section uses f64_serdes, so a constant
-- resolver suffices.
local function chunk_ids_contain(list, dense_id)
	if list == nil then
		return false
	end
	for _, chunk in list do
		local view = wire.decode_chunk(chunk, function()
			return f64_serdes
		end)
		for _, section in view.sections do
			if section.ids then
				for _, id in section.ids do
					if id == dense_id then
						return true
					end
				end
			end
			if section.nulled then
				for _, id in section.nulled do
					if id == dense_id then
						return true
					end
				end
			end
		end
	end
	return false
end

-- the three tracking tags are mutually exclusive, and one shared guard (guard_networked_added) enforces that
-- for all three add hooks: adding any of them to a definition another already owns errors, undoes the add, and
-- leaves the incumbent's tracking untouched. one table-driven block covers all six ordered (incumbent,
-- intruder) pairs, since the only half that varies is what "tracking untouched" looks like on the wire, and
-- that varies by incumbent alone. it sits in this section rather than with the other guard rails (section 11)
-- because a NetworkedUnreliable incumbent needs make_unreliable_component and the serdes hooks above.
local tracking_tags = {
	{
		name = "Networked",
		-- make_env already networks Health on the server
		make = function(env)
			return env.server.defs.Health, env.client.defs.Health
		end,
		-- continuous tracking: the initial value and every later change replicate reliably
		expect_tracking_intact = function(env, component, client_component)
			local s, c = env.server, env.client
			local e = s.world:entity()
			s.world:add(e, s.net.Replicated)
			s.world:set(e, component, 10)
			env.sync(env.player_a)
			local le = c.net.get_client_entity(e)
			expect_equal(c.world:get(le, client_component), 10, "initial value still replicates")

			s.world:set(e, component, 20)
			env.sync(env.player_a)
			expect_equal(c.world:get(le, client_component), 20, "later changes still replicate")
		end,
	},
	{
		name = "NetworkedOnce",
		-- make_env tracks Cooldown through NetworkedOnce on the server
		make = function(env)
			return env.server.defs.Cooldown, env.client.defs.Cooldown
		end,
		-- initial values and removals replicate, later changes stay suppressed
		expect_tracking_intact = function(env, component, client_component)
			local s, c = env.server, env.client
			local e = s.world:entity()
			s.world:add(e, s.net.Replicated)
			s.world:set(e, component, 5)
			env.sync(env.player_a)
			local le = c.net.get_client_entity(e)
			expect_equal(c.world:get(le, client_component), 5, "initial value still replicates")

			s.world:set(e, component, 3)
			local packet = env.sync(env.player_a)
			expect_equal(next(packet.components), nil, "value change stays suppressed by NetworkedOnce")
			expect_equal(c.world:get(le, client_component), 5, "client value unchanged")

			s.world:remove(e, component)
			env.sync(env.player_a)
			expect_equal(c.world:has(le, client_component), false, "removal still replicates")
		end,
	},
	{
		name = "NetworkedUnreliable",
		make = make_unreliable_component,
		-- the membership add carries the initial value reliably, later changes only stream unreliably
		expect_tracking_intact = function(env, component, client_component)
			local s, c = env.server, env.client
			local e = s.world:entity()
			s.world:add(e, s.net.Replicated)
			s.world:set(e, component, 1.5)
			env.sync(env.player_a)
			local le = c.net.get_client_entity(e)
			expect_equal(c.world:get(le, client_component), 1.5, "initial value still replicates reliably")

			s.world:set(e, component, 9.5)
			local packet = env.sync(env.player_a)
			expect_equal(next(packet.components), nil, "reliable change stays suppressed by NetworkedUnreliable")
			expect_equal(c.world:get(le, client_component), 1.5, "client value unchanged on the reliable path")

			local chunks = s.net.generate_unreliable_chunks()[env.player_a]
			for _, chunk in chunks do
				c.net.reconcile_chunk(chunk)
			end
			expect_equal(c.world:get(le, client_component), 9.5, "the unreliable channel still streams the change")
		end,
	},
}

for _, incumbent in tracking_tags do
	for _, intruder in tracking_tags do
		if intruder == incumbent then
			continue
		end
		test(
			`guard: adding {intruder.name} to a {incumbent.name} component errors, undoes the add, and leaves {incumbent.name} tracking intact`,
			function(env)
				local s = env.server
				local component, client_component = incumbent.make(env)

				expect_error(function()
					s.world:add(component, s.net[intruder.name])
				end, `adding {intruder.name} to a {incumbent.name} component`, "are exclusive")
				expect_equal(
					s.world:has(component, s.net[intruder.name]),
					false,
					`{intruder.name} removed by the guard before erroring`
				)
				expect_equal(s.world:has(component, s.net[incumbent.name]), true, "the incumbent tag is left in place")

				incumbent.expect_tracking_intact(env, component, client_component)
			end
		)
	end
end

test("guard: NetworkedUnreliable cannot be added to tags", function(env)
	local s = env.server
	local Tag = s.world:entity()
	expect_error(function()
		s.world:add(Tag, s.net.NetworkedUnreliable)
	end, "adding NetworkedUnreliable to a tag", "cannot be added to tags")
	expect_equal(
		s.world:has(Tag, s.net.NetworkedUnreliable),
		false,
		"NetworkedUnreliable removed by the guard before erroring"
	)

	-- the refusal has to leave the definition wholly untracked, not merely untagged: the tag check sits ahead
	-- of start_tracking_component, so a refused definition must stream on neither channel. the entity's own
	-- replication is what makes the packet below a real one rather than the harness's blank fallback.
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:add(e, Tag)
	local packet = env.sync(env.player_a)
	expect_equal(#packet.replicated, 1, "the entity itself replicates, so this is a real packet")
	expect_equal(next(packet.components), nil, "the refused tag ships no reliable section")
	expect_equal(next(s.net.generate_unreliable_chunks()), nil, "and no client has unreliable chunks to receive")
end)

test("guard: NetworkedUnreliable cannot be used as a pair", function(env)
	local s = env.server
	local e = s.world:entity()
	local t = s.world:entity()
	expect_error(function()
		s.world:add(e, pair(s.net.NetworkedUnreliable, t))
	end, "adding NetworkedUnreliable as a pair", "NetworkedUnreliable is not meant to be paired")
	expect_equal(
		s.world:has(e, pair(s.net.NetworkedUnreliable, t)),
		false,
		"the pair was removed by the guard before erroring"
	)
end)

test("guard: NetworkedUnreliable is rejected on Replicated entities", function(env)
	local s = env.server
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	expect_error(function()
		s.world:add(e, s.net.NetworkedUnreliable)
	end, "adding NetworkedUnreliable to a Replicated entity", "cannot add NetworkedUnreliable to replicated entities")
	expect_equal(
		s.world:has(e, s.net.NetworkedUnreliable),
		false,
		"NetworkedUnreliable removed by the guard before erroring"
	)
	-- the guard undoes the offending add, never the role it collided with
	expect_equal(s.world:has(e, s.net.Replicated), true, "the Replicated tag is left in place")
end)

test("NetworkedUnreliable's membership add carries the initial value on the reliable path", function(env)
	local s, c = env.server, env.client
	local Position, CPosition = make_unreliable_component(env)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, Position, 4.5)
	local packet = env.sync(env.player_a)

	local data = packet.components[Position]
	expect(data ~= nil and data.values ~= nil and data.values[1] == 4.5, "initial value ships in the reliable delta")
	local le = c.net.get_client_entity(e)
	expect_equal(c.world:get(le, CPosition), 4.5, "client received the initial value reliably")
end)

test("a later world:set on a NetworkedUnreliable component produces no reliable delta", function(env)
	local s, c = env.server, env.client
	local Position, CPosition = make_unreliable_component(env)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, Position, 1)
	env.sync(env.player_a)
	local le = c.net.get_client_entity(e)

	s.world:set(e, Position, 2)
	local packet = env.sync(env.player_a)
	expect_equal(next(packet.components), nil, "the reliable path stays silent for a NetworkedUnreliable value change")
	expect_equal(c.world:get(le, CPosition), 1, "client value unchanged on the reliable path")
end)

test("removing a NetworkedUnreliable component replicates reliably", function(env)
	local s, c = env.server, env.client
	local Position, CPosition = make_unreliable_component(env)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, Position, 1)
	env.sync(env.player_a)
	local le = c.net.get_client_entity(e)
	-- without this, the absence below would hold just as well had the membership add never replicated the cell
	expect_equal(c.world:get(le, CPosition), 1, "precondition: the membership add replicated the cell")

	s.world:remove(e, Position)
	local packet = env.sync(env.player_a)
	local data = packet.components[Position]
	expect(
		data ~= nil and data.removed ~= nil and data.removed[1] == jecs.ECS_ID(e),
		"the reliable delta names the cell in its removed list"
	)
	expect_equal(c.world:has(le, CPosition), false, "removal replicated on the reliable path")
end)

test("a late joiner's full packet carries the current value of a NetworkedUnreliable component", function(env)
	local s = env.server
	local Position = make_unreliable_component(env)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, Position, 7)
	env.frame()

	local c2 = env.make_client()
	local Position_c2 = c2.world:component()
	c2.net.set_client_entity(Position, Position_c2)
	c2.world:set(Position_c2, c2.net.Serdes, f64_serdes)
	local player_c = fake_player("PlayerC")
	env.join(player_c, c2)

	local le = c2.net.get_client_entity(e)
	expect_equal(c2.world:get(le, Position_c2), 7, "the full packet carried the current value")
end)

test("removing NetworkedUnreliable stops tracking and stages a reliable removal", function(env)
	local s, c = env.server, env.client
	local Position, CPosition = make_unreliable_component(env)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, Position, 3)
	env.sync(env.player_a)
	local le = c.net.get_client_entity(e)
	expect_equal(c.world:get(le, CPosition), 3, "precondition: initial value replicated")

	s.world:remove(Position, s.net.NetworkedUnreliable)
	env.sync(env.player_a)
	expect_equal(c.world:has(le, CPosition), false, "stopping tracking staged a removal")

	s.world:set(e, Position, 99)
	local chunks = s.net.generate_unreliable_chunks()
	expect_equal(chunks[env.player_a], nil, "the untracked component no longer produces unreliable chunks")
end)

test("generate_unreliable_chunks round-trips a value through reconcile_chunk", function(env)
	local s, c = env.server, env.client
	local Position, CPosition = make_unreliable_component(env)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, Position, 1)
	env.sync(env.player_a)
	local le = c.net.get_client_entity(e)

	s.world:set(e, Position, 42)
	local chunks = s.net.generate_unreliable_chunks()
	expect(chunks[env.player_a] ~= nil and #chunks[env.player_a] > 0, "player A received at least one chunk")
	for _, chunk in chunks[env.player_a] do
		c.net.reconcile_chunk(chunk)
	end
	expect_equal(c.world:get(le, CPosition), 42, "the unreliable value round-tripped")
end)

test(
	"an entity-level Private filter excludes a NetworkedUnreliable cell from an excluded client's chunks",
	function(env)
		local s = env.server
		local Position = make_unreliable_component(env)

		local shared = s.world:entity()
		s.world:add(shared, s.net.Replicated)
		s.world:set(shared, Position, 1)

		local hidden = s.world:entity()
		s.world:add(hidden, s.net.Replicated)
		s.world:set(hidden, Position, 2)
		s.world:set(hidden, s.net.Private, { [env.player_a] = true })

		env.frame()

		local chunks = s.net.generate_unreliable_chunks()
		local hidden_dense = jecs.ECS_ID(hidden)
		-- chunk_ids_contain reports false for a client with no chunks at all, so the exclusion below would hold
		-- just as happily if the unreliable channel had gone dark for B entirely. the shared cell anchors it: B
		-- has real chunks, and the private id is the one thing missing from them.
		expect(
			chunk_ids_contain(chunks[env.player_b], jecs.ECS_ID(shared)),
			"the excluded client still receives the unfiltered cell"
		)
		expect(chunk_ids_contain(chunks[env.player_a], hidden_dense), "the admitted client sees the private cell")
		expect(not chunk_ids_contain(chunks[env.player_b], hidden_dense), "the excluded client's chunks never carry it")
	end
)

test(
	"a per-component Private filter excludes a NetworkedUnreliable value from an excluded client's chunks",
	function(env)
		local s = env.server
		local Position = make_unreliable_component(env)

		local e = s.world:entity()
		s.world:add(e, s.net.Replicated)
		s.world:set(e, Position, 3)
		s.world:set(e, pair(s.net.Private, Position), { [env.player_a] = true })

		-- an unfiltered cell alongside it, so the unlisted client has chunks of their own: chunk_ids_contain
		-- reports false for an empty chunk list, so without this the exclusion below would hold even if the
		-- unreliable channel had gone dark for B entirely
		local open = s.world:entity()
		s.world:add(open, s.net.Replicated)
		s.world:set(open, Position, 4)

		env.frame()

		local chunks = s.net.generate_unreliable_chunks()
		local dense_id = jecs.ECS_ID(e)
		expect(chunk_ids_contain(chunks[env.player_a], dense_id), "the whitelisted client receives the gated value")
		expect(
			chunk_ids_contain(chunks[env.player_b], jecs.ECS_ID(open)),
			"the unlisted client still receives the unfiltered value"
		)
		expect(
			not chunk_ids_contain(chunks[env.player_b], dense_id),
			"the unlisted client's chunks never carry the gated value"
		)
	end
)

test("chunk buffers are shared by reference between clients with equal visibility", function(env)
	local s = env.server
	local Position = make_unreliable_component(env)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, Position, 9)
	env.frame()

	s.world:set(e, Position, 10)
	local chunks = s.net.generate_unreliable_chunks()
	expect(chunks[env.player_a] ~= nil and chunks[env.player_b] ~= nil, "both players received chunks")
	expect_equal(#chunks[env.player_a], 1, "one chunk for the single shared visibility group")
	expect_equal(#chunks[env.player_b], 1, "one chunk for the single shared visibility group")
	expect_equal(
		chunks[env.player_a][1],
		chunks[env.player_b][1],
		"the chunk buffer is the exact same object for both clients"
	)
end)

test("a NetworkedUnreliable relation's pair values round-trip and encode as single-target pair sections", function(env)
	local s, c = env.server, env.client
	local rel_s, rel_c = make_unreliable_relation(env)

	local e1 = s.world:entity()
	local e2 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(e2, s.net.Replicated)
	s.world:set(e1, pair(rel_s, e2), 11)
	env.sync(env.player_a)
	local le1 = c.net.get_client_entity(e1)
	local le2 = c.net.get_client_entity(e2)
	expect_equal(c.world:get(le1, pair(rel_c, le2)), 11, "initial pair value replicated reliably")

	s.world:set(e1, pair(rel_s, e2), 22)
	local chunks = s.net.generate_unreliable_chunks()[env.player_a]

	local found_pair_section = false
	for _, chunk in chunks do
		local view = wire.decode_chunk(chunk, function()
			return f64_serdes
		end)
		for _, section in view.sections do
			if section.relation == jecs.ECS_ID(rel_s) and section.target == jecs.ECS_ID(e2) then
				found_pair_section = true
				expect(section.ids ~= nil and section.ids[1] == jecs.ECS_ID(e1), "the pair section names the subject")
				expect(section.values ~= nil and section.values[1] == 22, "the pair section carries the changed value")
			end
		end
	end
	expect(found_pair_section, "the pair cell encoded as a single-target pair section")

	for _, chunk in chunks do
		c.net.reconcile_chunk(chunk)
	end
	expect_equal(c.world:get(le1, pair(rel_c, le2)), 22, "the pair value round-tripped through the unreliable channel")
end)

test("a NetworkedUnreliable value transitioning to nil nulls the cell through the unreliable path", function(env)
	local s, c = env.server, env.client
	local Position, CPosition = make_unreliable_component(env)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, Position, 6)
	env.sync(env.player_a)
	local le = c.net.get_client_entity(e)
	expect_equal(c.world:get(le, CPosition), 6, "precondition: initial value replicated")

	s.world:set(e, Position, nil)
	for _, chunk in s.net.generate_unreliable_chunks()[env.player_a] do
		c.net.reconcile_chunk(chunk)
	end
	expect_equal(c.world:has(le, CPosition), true, "the cell is not removed, only nulled")
	expect_equal(c.world:get(le, CPosition), nil, "the value is nil after the nulled transition")
end)

test("a small chunk_bytes budget splits many values across multiple chunks, all round-tripping", function(env)
	local s, c = env.server, env.client
	local Position, CPosition = make_unreliable_component(env)

	local entities = {}
	for i = 1, 50 do
		local e = s.world:entity()
		s.world:add(e, s.net.Replicated)
		s.world:set(e, Position, i + 0.5)
		entities[i] = e
	end
	env.sync(env.player_a)

	for i = 1, 50 do
		s.world:set(entities[i], Position, i + 100.5)
	end
	local chunks = s.net.generate_unreliable_chunks(64)
	expect(#chunks[env.player_a] > 1, `50 values split into multiple chunks (got {#chunks[env.player_a]})`)
	for _, chunk in chunks[env.player_a] do
		expect(buffer.len(chunk) <= 64, "every chunk respects the custom budget")
	end

	for _, chunk in chunks[env.player_a] do
		c.net.reconcile_chunk(chunk)
	end
	local seen = 0
	for i = 1, 50 do
		local le = c.net.get_client_entity(entities[i])
		if le ~= nil and c.world:get(le, CPosition) == i + 100.5 then
			seen += 1
		end
	end
	expect_equal(seen, 50, `all values round-tripped ({seen}/50)`)
end)

test("generate_unreliable_chunks validates chunk_bytes", function(env)
	local s = env.server
	expect_error(function()
		s.net.generate_unreliable_chunks(15)
	end, "chunk_bytes below the minimum", "chunk_bytes must be an integer")
	expect_error(function()
		s.net.generate_unreliable_chunks(65536)
	end, "chunk_bytes above the maximum", "chunk_bytes must be an integer")
	expect_error(function()
		s.net.generate_unreliable_chunks(64.5)
	end, "a non-integer chunk_bytes", "chunk_bytes must be an integer")

	-- both bounds are inclusive, and only the floor's acceptance is pinned (by the test below), so an
	-- off-by-one on the ceiling would leave the widest legal budget refused with nothing catching it. this env
	-- tracks nothing unreliably, so the accepted call also pins the empty map that shape returns.
	expect_equal(
		next(s.net.generate_unreliable_chunks(wire.max_chunk_bytes)),
		nil,
		"the ceiling budget is accepted, and no NetworkedUnreliable definitions means no chunks"
	)
end)

test("generate_unreliable_chunks packs at the chunk_bytes floor and refuses the byte below it", function(env)
	-- both bounds come from the wire layout rather than being picked, and the floor is the smallest budget an
	-- empty chunk can still fit one cell of any section into -- so the floor itself must pack, and the byte
	-- under it must be refused by the same message the other invalid budgets get.
	local s, c = env.server, env.client
	local Position, CPosition = make_unreliable_component(env)

	expect_error(function()
		s.net.generate_unreliable_chunks(wire.min_chunk_bytes - 1)
	end, "chunk_bytes one byte below the floor", "chunk_bytes must be an integer")

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, Position, 7)
	env.sync(env.player_a)
	local le = c.net.get_client_entity(e)
	expect_equal(c.world:get(le, CPosition), 7, "precondition: the initial value replicated reliably")

	-- a nulled cell is the cheapest thing a section can carry -- a bare header, one count, and one id, with no
	-- value to encode -- so it ships inside the floor budget without a value large enough to be pruned for
	-- containment, which is what makes the silence below an assertion that the floor really packs
	s.world:set(e, Position, nil)
	local chunks = s.net.generate_unreliable_chunks(wire.min_chunk_bytes)[env.player_a]
	expect(chunks ~= nil and #chunks == 1, "the floor budget produced a chunk")
	expect(
		buffer.len(chunks[1]) <= wire.min_chunk_bytes,
		`the chunk respects the floor budget (got {buffer.len(chunks[1])})`
	)

	for _, chunk in chunks do
		c.net.reconcile_chunk(chunk)
	end
	expect_equal(c.world:has(le, CPosition), true, "the cell is not removed, only nulled")
	expect_equal(c.world:get(le, CPosition), nil, "the nulled cell round-tripped through a floor-sized chunk")
end)

test("dynamic buffer-mode serdes values round-trip through unreliable chunks", function(env)
	local s, c = env.server, env.client
	local Health, CHealth = make_unreliable_component(env, buffer_string_serdes)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, Health, "short")

	-- a second cell of the same component, so the section carries two values back to back: with no static size
	-- each value rides a u16 length prefix, and only a neighbour past the first can catch a reader that
	-- advances by the wrong amount
	local other = s.world:entity()
	s.world:add(other, s.net.Replicated)
	s.world:set(other, Health, "x")

	env.sync(env.player_a)
	local le = c.net.get_client_entity(e)
	local lother = c.net.get_client_entity(other)
	expect_equal(c.world:get(le, CHealth), "short", "precondition: the initial value replicated reliably")

	s.world:set(e, Health, "a much longer value than the others")
	s.world:set(other, Health, "tiny")
	for _, chunk in s.net.generate_unreliable_chunks()[env.player_a] do
		c.net.reconcile_chunk(chunk)
	end
	expect_equal(
		c.world:get(le, CHealth),
		"a much longer value than the others",
		"dynamic buffer-mode value round-tripped"
	)
	expect_equal(c.world:get(lother, CHealth), "tiny", "the value packed behind it decoded at the right offset")
end)

test("static-size buffer-mode serdes values round-trip through unreliable chunks", function(env)
	local s, c = env.server, env.client
	local Health, CHealth = make_unreliable_component(env, buffer_f64_serdes)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, Health, 1)

	-- a second cell of the same component, so the section carries two values back to back: a declared size
	-- drops the length prefix and the reader strides arithmetically instead, which one value alone can never
	-- exercise
	local other = s.world:entity()
	s.world:add(other, s.net.Replicated)
	s.world:set(other, Health, 2)

	env.sync(env.player_a)
	local le = c.net.get_client_entity(e)
	local lother = c.net.get_client_entity(other)
	expect_equal(c.world:get(le, CHealth), 1, "precondition: the initial value replicated reliably")

	s.world:set(e, Health, 100)
	s.world:set(other, Health, 200)
	for _, chunk in s.net.generate_unreliable_chunks()[env.player_a] do
		c.net.reconcile_chunk(chunk)
	end
	expect_equal(c.world:get(le, CHealth), 100, "static-size buffer-mode value round-tripped")
	expect_equal(c.world:get(lother, CHealth), 200, "the value packed behind it decoded at the right stride")
end)

-- the unreliable counterpart to the reliable encode salvage tests above: finalize_chunks packs each draft
-- under its own pcall (see wire.finalize_chunks), so a user encode failure -- a throwing hook, a violated
-- static size contract, a value no chunk could fit, or missing hooks entirely -- drops exactly the offending
-- values from this call's chunks, with one warning per affected visibility group, instead of erroring the whole
-- call. everything else still ships: the failing component's surviving values, other components, and nulled
-- ids. the always-replicate cadence re-sends every value every call, so a persistent failure warns on every
-- call and a fixed one heals on the following one.

test("a throwing encode hook drops only its own unreliable value, leaving the rest of the chunks intact", function(env)
	local s, c = env.server, env.client
	local poison = -1
	local throwing_serdes = {
		encode = function(value)
			if value == poison then
				error("simulated encode failure")
			end
			local buf = buffer.create(8)
			buffer.writef64(buf, 0, value)
			return buf
		end,
		decode = function(buf)
			return buffer.readf64(buf, 0)
		end,
	}
	local Position, CPosition = make_unreliable_component(env, throwing_serdes)
	local Velocity, CVelocity = make_unreliable_component(env)

	local healthy = s.world:entity()
	local poisoned = s.world:entity()
	s.world:add(healthy, s.net.Replicated)
	s.world:add(poisoned, s.net.Replicated)
	s.world:set(healthy, Position, 1)
	s.world:set(poisoned, Position, 1)
	s.world:set(healthy, Velocity, 1)
	env.sync(env.player_a) -- the membership adds carry the initial values reliably; the chunk path is under test
	local le_healthy = c.net.get_client_entity(healthy)
	local le_poisoned = c.net.get_client_entity(poisoned)

	s.world:set(healthy, Position, 2)
	s.world:set(poisoned, Position, poison)
	s.world:set(healthy, Velocity, 2)
	expected_warning("a serdes encode failed while chunking")
	for _, chunk in s.net.generate_unreliable_chunks()[env.player_a] do
		c.net.reconcile_chunk(chunk)
	end

	expect_equal(c.world:get(le_healthy, CPosition), 2, "the same component's healthy value still shipped")
	expect_equal(c.world:get(le_poisoned, CPosition), 1, "the poisoned value was dropped; the stale value remains")
	expect_equal(c.world:get(le_healthy, CVelocity), 2, "a different component's value is unaffected")
end)

test("a static-size encode throwing on one value keeps every surviving value and intact chunks", function(env)
	local s, c = env.server, env.client
	local poison = -1
	-- the static arm of the pre-encode salvage (static sizes otherwise size arithmetically, with no
	-- per-value framing): the throw fails the draft's pcall before anything packs, the offender is
	-- pruned, and the survivors pack into chunks that must still parse
	local throwing_static_serdes = {
		size = 8,
		encode = function(value)
			if value == poison then
				error("simulated encode failure")
			end
			local buf = buffer.create(8)
			buffer.writef64(buf, 0, value)
			return buf
		end,
		decode = function(buf)
			return buffer.readf64(buf, 0)
		end,
	}
	local Position, CPosition = make_unreliable_component(env, throwing_static_serdes)

	local entities = {}
	for i = 1, 5 do
		local e = s.world:entity()
		s.world:add(e, s.net.Replicated)
		s.world:set(e, Position, i)
		entities[i] = e
	end
	env.sync(env.player_a)

	for i = 1, 5 do
		s.world:set(entities[i], Position, i + 10)
	end
	s.world:set(entities[3], Position, poison) -- mid-list, so survivors flank it on both sides
	expected_warning("a serdes encode failed while chunking")
	local chunks = s.net.generate_unreliable_chunks()[env.player_a]

	-- every chunk still parses, and between them they carry all four surviving values
	local seen = {}
	for _, chunk in chunks do
		local view = wire.decode_chunk(chunk, function()
			return throwing_static_serdes
		end)
		for _, section in view.sections do
			if section.ids ~= nil and section.values ~= nil then
				for index, id in section.ids do
					seen[id] = section.values[index]
				end
			end
		end
	end
	for i = 1, 5 do
		local dense = jecs.ECS_ID(entities[i])
		if i == 3 then
			expect_equal(seen[dense], nil, "the poisoned value is absent from every chunk")
		else
			expect_equal(seen[dense], i + 10, `chunked value for entity {i}`)
		end
	end

	for _, chunk in chunks do
		c.net.reconcile_chunk(chunk)
	end
	for i = 1, 5 do
		local le = c.net.get_client_entity(entities[i])
		local expected = if i == 3 then 3 else i + 10
		expect_equal(c.world:get(le, CPosition), expected, `client value for entity {i}`)
	end
end)

test(
	"a nondeterministic encode hook strips a draft's unreliable values wholesale while its nulled ids still ship",
	function(env)
		local s, c = env.server, env.client
		local armed = false
		local call_count = 0
		-- throws on the initial fit-pass encode (call 1) and again on the resume (call 4) after a salvage whose
		-- per-value re-encodes (calls 2 and 3) both succeeded -- nondeterministic enough to defeat the prune, so
		-- the draft's remaining values are stripped wholesale. armed only after the reliable sync below, whose
		-- own encodes would otherwise consume the count.
		local flaky_serdes = {
			encode = function(value)
				if armed then
					call_count += 1
					if call_count == 1 or call_count >= 4 then
						error(`simulated nondeterministic failure on call {call_count}`)
					end
				end
				local buf = buffer.create(8)
				buffer.writef64(buf, 0, value)
				return buf
			end,
			decode = function(buf)
				return buffer.readf64(buf, 0)
			end,
		}
		local Position, CPosition = make_unreliable_component(env, flaky_serdes)
		local Velocity, CVelocity = make_unreliable_component(env)

		local first = s.world:entity()
		local second = s.world:entity()
		local nulled = s.world:entity()
		for _, e in { first, second, nulled } do
			s.world:add(e, s.net.Replicated)
			s.world:set(e, Position, 1)
		end
		local other = s.world:entity()
		s.world:add(other, s.net.Replicated)
		s.world:set(other, Velocity, 1)
		env.sync(env.player_a)
		local le_first = c.net.get_client_entity(first)
		local le_second = c.net.get_client_entity(second)
		local le_nulled = c.net.get_client_entity(nulled)
		local le_other = c.net.get_client_entity(other)

		s.world:set(first, Position, 2)
		s.world:set(second, Position, 3)
		s.world:set(nulled, Position, nil)
		s.world:set(other, Velocity, 2)
		armed = true
		-- the salvage report carries the first captured error, so the warning must name the initial fit-pass
		-- throw rather than the resume's
		expected_warning("simulated nondeterministic failure on call 1")
		for _, chunk in s.net.generate_unreliable_chunks()[env.player_a] do
			c.net.reconcile_chunk(chunk)
		end

		expect_equal(
			call_count,
			4,
			"the initial pre-encode, both per-value re-encodes, and the failed re-encode each called encode once"
		)
		expect_equal(c.world:get(le_first, CPosition), 1, "the first value was stripped wholesale")
		expect_equal(
			c.world:get(le_second, CPosition),
			1,
			"the second value was stripped wholesale even though the prune kept it"
		)
		expect_equal(c.world:has(le_nulled, CPosition), true, "the nulled cell was not removed")
		expect_equal(c.world:get(le_nulled, CPosition), nil, "the nulled id shipped despite the wholesale strip")
		expect_equal(c.world:get(le_other, CVelocity), 2, "a different component's values are unaffected")
	end
)

test("a visible NetworkedUnreliable value with no serdes hooks is dropped from the chunks with a warning", function(env)
	local s, c = env.server, env.client
	local Position, CPosition = make_unreliable_component(env)
	-- tracked unreliably but never given hooks: chunking needs byte-exact sizing, so its values can never ship
	-- through this channel (its reliable membership add still carries the initial value in the side array)
	local Hookless = s.world:component()
	local CHookless = c.world:component()
	c.net.set_client_entity(Hookless, CHookless)
	s.world:add(Hookless, s.net.NetworkedUnreliable)

	local hooked = s.world:entity()
	local hookless = s.world:entity()
	s.world:add(hooked, s.net.Replicated)
	s.world:add(hookless, s.net.Replicated)
	s.world:set(hooked, Position, 1)
	s.world:set(hookless, Hookless, 5)
	env.sync(env.player_a)
	local le_hooked = c.net.get_client_entity(hooked)
	local le_hookless = c.net.get_client_entity(hookless)
	expect_equal(c.world:get(le_hookless, CHookless), 5, "precondition: the hookless value replicated reliably")

	s.world:set(hooked, Position, 2)
	s.world:set(hookless, Hookless, 6)
	-- the salvage reason the warning must carry: unresolvable hooks, not a throwing or contract-breaking one
	expected_warning("unreliable values cannot be serialized without serdes hooks")
	local chunks = s.net.generate_unreliable_chunks()[env.player_a]
	expect(chunk_ids_contain(chunks, jecs.ECS_ID(hooked)), "the hooked component's value still ships")
	expect(not chunk_ids_contain(chunks, jecs.ECS_ID(hookless)), "the hookless component's value is in no chunk")

	for _, chunk in chunks do
		c.net.reconcile_chunk(chunk)
	end
	expect_equal(c.world:get(le_hooked, CPosition), 2, "the hooked component's value round-tripped")
	expect_equal(c.world:get(le_hookless, CHookless), 5, "the hookless value never reached the client")
end)

test(
	"an unreliable value that cannot fit even an empty chunk is dropped while the component's smaller values ship",
	function(env)
		local s, c = env.server, env.client
		local oversized = "oversized"
		local oversizing_serdes = {
			encode = function(value)
				if value == oversized then
					return buffer.create(100) -- larger than the whole 64-byte budget used below
				end
				local buf = buffer.create(#value)
				buffer.writestring(buf, 0, value)
				return buf
			end,
			decode = function(buf)
				return buffer.readstring(buf, 0, buffer.len(buf))
			end,
		}
		local Position, CPosition = make_unreliable_component(env, oversizing_serdes)

		local first = s.world:entity()
		local huge = s.world:entity()
		local last = s.world:entity()
		for _, e in { first, huge, last } do
			s.world:add(e, s.net.Replicated)
			s.world:set(e, Position, "ok")
		end
		env.sync(env.player_a)
		local le_first = c.net.get_client_entity(first)
		local le_huge = c.net.get_client_entity(huge)
		local le_last = c.net.get_client_entity(last)

		s.world:set(first, Position, "aa")
		s.world:set(huge, Position, oversized)
		s.world:set(last, Position, "bb")
		-- the salvage reason the warning must carry: the budget bound, not a throwing hook or a size-contract
		-- violation
		expected_warning("an unreliable value exceeds the chunk byte budget")
		local chunks = s.net.generate_unreliable_chunks(64)[env.player_a]
		for _, chunk in chunks do
			expect(buffer.len(chunk) <= 64, "every chunk still respects the budget")
			c.net.reconcile_chunk(chunk)
		end

		expect_equal(c.world:get(le_first, CPosition), "aa", "a smaller value of the same component still shipped")
		expect_equal(c.world:get(le_last, CPosition), "bb", "the value queued after the oversized one still shipped")
		expect_equal(c.world:get(le_huge, CPosition), "ok", "the oversized value was dropped; the stale value remains")
	end
)

test("an unreliable value dropped by a failing hook ships on the next call once the hook is fixed", function(env)
	local s, c = env.server, env.client
	local broken = false
	local healing_serdes = {
		encode = function(value)
			if broken then
				error("simulated encode failure")
			end
			local buf = buffer.create(8)
			buffer.writef64(buf, 0, value)
			return buf
		end,
		decode = function(buf)
			return buffer.readf64(buf, 0)
		end,
	}
	local Position, CPosition = make_unreliable_component(env, healing_serdes)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, Position, 1)
	env.sync(env.player_a)
	local le = c.net.get_client_entity(e)

	s.world:set(e, Position, 2)
	broken = true
	expected_warning("a serdes encode failed while chunking")
	for _, chunk in s.net.generate_unreliable_chunks()[env.player_a] do
		c.net.reconcile_chunk(chunk)
	end
	expect_equal(c.world:get(le, CPosition), 1, "the dropped value never reached the client")

	-- the unreliable channel re-sends every visible value every call, so the fixed hook heals the cell with no
	-- fresh world:set behind it
	broken = false
	for _, chunk in s.net.generate_unreliable_chunks()[env.player_a] do
		c.net.reconcile_chunk(chunk)
	end
	expect_equal(c.world:get(le, CPosition), 2, "the next call re-sent the previously-dropped value")
end)

test("a stale-frame chunk is dropped after a newer frame has been applied", function(env)
	local s, c = env.server, env.client
	local Position, CPosition = make_unreliable_component(env)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, Position, 1)
	env.sync(env.player_a)
	local le = c.net.get_client_entity(e)

	s.world:set(e, Position, 10)
	local old_chunks = s.net.generate_unreliable_chunks()[env.player_a]
	for _, chunk in old_chunks do
		c.net.reconcile_chunk(chunk)
	end
	expect_equal(c.world:get(le, CPosition), 10, "the first frame's value applied")

	s.world:set(e, Position, 20)
	local new_chunks = s.net.generate_unreliable_chunks()[env.player_a]
	for _, chunk in new_chunks do
		c.net.reconcile_chunk(chunk)
	end
	expect_equal(c.world:get(le, CPosition), 20, "the newer frame applied")

	for _, chunk in old_chunks do
		c.net.reconcile_chunk(chunk)
	end
	expect_equal(c.world:get(le, CPosition), 20, "the stale chunk was dropped, value did not snap backward")

	-- a redelivery of the same stale chunk stays dropped: a gate that stamped the refused frame as its newest
	-- would read the repeat as another chunk of the current frame and let the stale value through
	for _, chunk in old_chunks do
		c.net.reconcile_chunk(chunk)
	end
	expect_equal(c.world:get(le, CPosition), 20, "the redelivered stale chunk was dropped too")

	-- and dropping does not wedge the gate: the next frame still applies
	s.world:set(e, Position, 30)
	for _, chunk in s.net.generate_unreliable_chunks()[env.player_a] do
		c.net.reconcile_chunk(chunk)
	end
	expect_equal(c.world:get(le, CPosition), 30, "the following frame applied after the stale drops")
end)

test("the has-guard blocks an unreliable chunk from resurrecting a reliably-removed cell", function(env)
	local s = env.server
	local Position = make_unreliable_component(env)

	-- the surviving cell rides the same chunks as the removed one and keeps its component throughout, so its
	-- value landing on the joiner is what proves the stale chunk was applied at all: without it, a chunk that
	-- never reached the apply pass would satisfy the removed cell's assertion vacuously
	local e = s.world:entity()
	local live = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:add(live, s.net.Replicated)
	s.world:set(e, Position, 5)
	s.world:set(live, Position, 7)
	env.frame()

	local old_chunks = s.net.generate_unreliable_chunks()[env.player_a]
	expect(old_chunks ~= nil and #old_chunks > 0, "precondition: chunks were produced for the live cell")

	s.world:remove(e, Position)
	s.world:set(live, Position, 8) -- so the joiner's full packet disagrees with the older value the chunks carry
	env.frame() -- drains the reliable removal

	local c2 = env.make_client()
	local Position_c2 = c2.world:component()
	c2.net.set_client_entity(Position, Position_c2)
	c2.world:set(Position_c2, c2.net.Serdes, f64_serdes)
	local player_c = fake_player("PlayerC")
	env.join(player_c, c2)

	local le2 = c2.net.get_client_entity(e)
	local le_live = c2.net.get_client_entity(live)
	expect(le2 ~= nil, "precondition: the joiner's full packet still created the entity behind the removed cell")
	expect_equal(c2.world:has(le2, Position_c2), false, "precondition: the joiner's full packet omits the removed cell")
	expect_equal(c2.world:get(le_live, Position_c2), 8, "precondition: the full packet carried the surviving cell")

	for _, chunk in old_chunks do
		c2.net.reconcile_chunk(chunk)
	end
	expect_equal(c2.world:has(le2, Position_c2), false, "the has-guard blocked resurrecting the removed cell")
	expect_equal(c2.world:get(le_live, Position_c2), 7, "the same chunk did apply, so the guard is what blocked it")
end)

test(
	"a chunk referencing a not-yet-imported entity skips harmlessly, applying once its creation packet arrives",
	function(env)
		-- generate_packets already stamped this delta into its own bookkeeping
		-- the moment it was drained, whether or not the caller ever reconciles
		-- it -- so holding the packet back and applying it later (rather than
		-- discarding it, which would mean the entity never arrives at all, as
		-- in the buffer-mode alignment test above) is what simulates network
		-- delay rather than an outright drop.
		local s, c = env.server, env.client
		local Position, CPosition = make_unreliable_component(env)

		local e = s.world:entity()
		s.world:add(e, s.net.Replicated)
		s.world:set(e, Position, 1)
		local delayed_packet = env.frame()[env.player_a] -- drained but held back

		s.world:set(e, Position, 2)
		local outrunning_chunks = s.net.generate_unreliable_chunks()[env.player_a]
		expect(
			chunk_ids_contain(outrunning_chunks, jecs.ECS_ID(e)),
			"precondition: the outrunning chunks carry the value of the entity the client cannot map yet"
		)
		for _, chunk in outrunning_chunks do
			c.net.reconcile_chunk(chunk)
		end
		expect_equal(c.net.get_client_entity(e), nil, "the entity is still unmapped; the chunk skipped harmlessly")

		c.net.reconcile_packet(delayed_packet) -- the held-back creation finally arrives
		local le = c.net.get_client_entity(e)
		expect(le ~= nil, "the entity is now mapped")
		expect_equal(c.world:get(le, CPosition), 1, "the delayed packet's own value applied first")

		s.world:set(e, Position, 3)
		for _, chunk in s.net.generate_unreliable_chunks()[env.player_a] do
			c.net.reconcile_chunk(chunk)
		end
		expect_equal(c.world:get(le, CPosition), 3, "a later frame applies once the creation has arrived")
	end
)

test("a changed override applies unreliable chunk values and nulled entries, unguarded by world:has", function(env)
	local s, c = env.server, env.client
	local Position, CPosition = make_unreliable_component(env)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, Position, 1)
	env.sync(env.player_a)
	local le = c.net.get_client_entity(e)

	local calls = {}
	c.net.set_changed_override(CPosition, function(entity, value)
		table.insert(calls, { entity = entity, value = value })
	end)

	s.world:set(e, Position, 2)
	for _, chunk in s.net.generate_unreliable_chunks()[env.player_a] do
		c.net.reconcile_chunk(chunk)
	end
	expect_equal(#calls, 1, "the override ran for the changed chunk value")
	expect_equal(calls[1].entity, le, "override entity")
	expect_equal(calls[1].value, 2, "override value")
	expect_equal(c.world:get(le, CPosition), 1, "the default set is suppressed by the override")

	s.world:set(e, Position, nil)
	for _, chunk in s.net.generate_unreliable_chunks()[env.player_a] do
		c.net.reconcile_chunk(chunk)
	end
	expect_equal(#calls, 2, "the override ran for the nulled entry too")
	expect_equal(calls[2].value, nil, "nulled entries pass nil to the override")

	-- the override owns application, so it fires even where the client entity no longer has the component: the
	-- has-guard gates only the default set
	c.world:remove(le, CPosition)
	s.world:set(e, Position, 4)
	for _, chunk in s.net.generate_unreliable_chunks()[env.player_a] do
		c.net.reconcile_chunk(chunk)
	end
	expect_equal(#calls, 3, "the override ran for an entity that no longer has the component")
	expect_equal(calls[3].value, 4, "override value for the componentless entity")
	expect_equal(c.world:has(le, CPosition), false, "the override did not resurrect the cell it was handed")
end)

test("a relation-level changed override applies to unreliable pair chunk values as a fallback", function(env)
	local s, c = env.server, env.client
	local rel_s, rel_c = make_unreliable_relation(env)

	local e1 = s.world:entity()
	local e2 = s.world:entity()
	s.world:add(e1, s.net.Replicated)
	s.world:add(e2, s.net.Replicated)
	s.world:set(e1, pair(rel_s, e2), 1)
	env.sync(env.player_a)
	local le1 = c.net.get_client_entity(e1)
	local le2 = c.net.get_client_entity(e2)

	local calls = {}
	c.net.set_changed_override(rel_c, function(entity, value)
		table.insert(calls, { entity = entity, value = value })
	end)

	s.world:set(e1, pair(rel_s, e2), 2)
	for _, chunk in s.net.generate_unreliable_chunks()[env.player_a] do
		c.net.reconcile_chunk(chunk)
	end
	expect_equal(#calls, 1, "the relation-level override ran for the pair's chunk value")
	expect_equal(calls[1].entity, le1, "override entity")
	expect_equal(calls[1].value, 2, "override value")
	expect_equal(c.world:get(le1, pair(rel_c, le2)), 1, "the default pair set is suppressed by the override")
end)

-- the client-side counterpart to the reliable decode salvage tests above: apply_chunk_lists
-- (reconcile_chunk) also runs decode under pcall, so a poisoned value no longer takes the
-- whole unreliable channel down -- it is skipped with a warning, and chunks resend every frame, so a
-- later frame with a clean value applies normally.

test(
	"a throwing decode hook skips only the poisoned value in an unreliable chunk, leaving the rest of the chunk intact",
	function(env)
		local s, c = env.server, env.client
		local poison = -1
		local throwing_decode_serdes = {
			encode = function(value)
				local buf = buffer.create(8)
				buffer.writef64(buf, 0, value)
				return buf
			end,
			decode = function(buf)
				local value = buffer.readf64(buf, 0)
				if value == poison then
					error("simulated decode failure")
				end
				return value
			end,
		}
		local Position, CPosition = make_unreliable_component(env, throwing_decode_serdes)

		-- trailing is created last, so its cell sits past the poisoned one: its value applying is what proves
		-- the skip hopped exactly one value and left the id and value cursors aligned
		local healthy = s.world:entity()
		local poisoned = s.world:entity()
		local trailing = s.world:entity()
		s.world:add(healthy, s.net.Replicated)
		s.world:add(poisoned, s.net.Replicated)
		s.world:add(trailing, s.net.Replicated)
		s.world:set(healthy, Position, 1)
		s.world:set(poisoned, Position, 1)
		s.world:set(trailing, Position, 1)
		env.sync(env.player_a) -- the membership add carries its initial value reliably; the chunk path is under test below
		local le_healthy = c.net.get_client_entity(healthy)
		local le_poisoned = c.net.get_client_entity(poisoned)
		local le_trailing = c.net.get_client_entity(trailing)

		s.world:set(healthy, Position, 2)
		s.world:set(poisoned, Position, poison)
		s.world:set(trailing, Position, 3)
		expected_warning("were skipped from this chunk")
		for _, chunk in s.net.generate_unreliable_chunks()[env.player_a] do
			c.net.reconcile_chunk(chunk)
		end

		expect_equal(c.world:get(le_healthy, CPosition), 2, "the healthy entity's chunk value applied")
		expect_equal(c.world:get(le_poisoned, CPosition), 1, "the poisoned entity's stale value was left untouched")
		expect_equal(c.world:get(le_trailing, CPosition), 3, "the value queued after the poisoned one still applied")
	end
)

test("the unreliable channel stays up after a poisoned chunk value, self-healing on the next frame", function(env)
	local s, c = env.server, env.client
	local poison = -1
	local throwing_decode_serdes = {
		encode = function(value)
			local buf = buffer.create(8)
			buffer.writef64(buf, 0, value)
			return buf
		end,
		decode = function(buf)
			local value = buffer.readf64(buf, 0)
			if value == poison then
				error("simulated decode failure")
			end
			return value
		end,
	}
	local Position, CPosition = make_unreliable_component(env, throwing_decode_serdes)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, Position, 1)
	env.sync(env.player_a)
	local le = c.net.get_client_entity(e)

	s.world:set(e, Position, poison)
	expected_warning("were skipped from this chunk")
	for _, chunk in s.net.generate_unreliable_chunks()[env.player_a] do
		c.net.reconcile_chunk(chunk)
	end
	expect_equal(c.world:get(le, CPosition), 1, "the poisoned value was skipped; the stale value remains")

	s.world:set(e, Position, 5)
	for _, chunk in s.net.generate_unreliable_chunks()[env.player_a] do
		c.net.reconcile_chunk(chunk)
	end
	expect_equal(
		c.world:get(le, CPosition),
		5,
		"the next frame's chunk decoded cleanly, confirming the channel stayed up"
	)
end)

test("feeding a chunk into reconcile_packet errors", function(env)
	local s, c = env.server, env.client
	local Position = make_unreliable_component(env)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, Position, 1)
	env.frame()
	local chunk = s.net.generate_unreliable_chunks()[env.player_a][1]

	expect_error(function()
		c.net.reconcile_packet({ data = chunk })
	end, "an unreliable chunk fed to reconcile_packet", "unreliable chunk on the reliable path")
end)

test("feeding a reliable packet into reconcile_chunk errors", function(env)
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	local packet = env.frame()[env.player_a]

	expect_error(function()
		c.net.reconcile_chunk(packet.data)
	end, "a reliable packet fed to reconcile_chunk", "reliable packet on the unreliable path")
end)

-- get_chunk_frame: the chunk-side counterpart to get_packet_frame (whose tests sit with the reliable
-- packet tests above). it validates the version byte exactly like reconcile_chunk, then reads
-- only the header, so it must never touch the staleness gate -- the purity test below is the one that
-- matters, since the accessor exists so a caller can park a chunk's frame in an upvalue and let a changed
-- override stamp what it captures with it.

test("get_chunk_frame reads the chunk frame counter carried in the chunk's buffer", function(env)
	local s, c = env.server, env.client
	local Position = make_unreliable_component(env)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, Position, 1)
	env.frame()

	local chunk = s.net.generate_unreliable_chunks()[env.player_a][1]
	expect_equal(
		c.net.get_chunk_frame(chunk),
		buffer.readu32(chunk, version_width),
		"matches the u32 just past the leading version byte"
	)

	local view = wire.decode_chunk(chunk, function()
		return f64_serdes
	end)
	expect_equal(c.net.get_chunk_frame(chunk), view.frame, "agrees with decode_chunk's view of the same chunk")
end)

test("every chunk from one generate_unreliable_chunks call reports the same chunk frame", function(env)
	local s, c = env.server, env.client
	local Position = make_unreliable_component(env)

	for i = 1, 50 do
		local e = s.world:entity()
		s.world:add(e, s.net.Replicated)
		s.world:set(e, Position, i + 0.5)
	end
	env.frame()

	-- a small budget splits the call across several chunks, all of which must still carry the one frame
	local chunks = s.net.generate_unreliable_chunks(64)
	expect(#chunks[env.player_a] > 1, `50 values split into multiple chunks (got {#chunks[env.player_a]})`)

	local frame = c.net.get_chunk_frame(chunks[env.player_a][1])
	for index, chunk in chunks[env.player_a] do
		expect_equal(c.net.get_chunk_frame(chunk), frame, `chunk {index} carries the call's frame`)
	end
	-- the values are public, so B's chunks come out of the same call and share its frame
	for index, chunk in chunks[env.player_b] do
		expect_equal(c.net.get_chunk_frame(chunk), frame, `player B's chunk {index} carries the call's frame`)
	end
end)

test("the chunk frame advances between successive generate_unreliable_chunks calls", function(env)
	local s, c = env.server, env.client
	local Position = make_unreliable_component(env)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, Position, 1)
	env.frame()

	local first = c.net.get_chunk_frame(s.net.generate_unreliable_chunks()[env.player_a][1])

	s.world:set(e, Position, 2)
	local second = c.net.get_chunk_frame(s.net.generate_unreliable_chunks()[env.player_a][1])

	expect_equal(second, first + 1, "the chunk frame advances by one per call")
	-- the wrap-aware comparison the staleness gate applies: an advance in [1, 2^31) reads as newer
	local advance = (second - first) % 2 ^ 32
	expect(advance >= 1 and advance < 2 ^ 31, "the advance reads as newer under the gate's wrap-aware comparison")
end)

test("feeding a reliable packet into get_chunk_frame errors", function(env)
	local s, c = env.server, env.client
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	local packet = env.frame()[env.player_a]

	expect_error(function()
		c.net.get_chunk_frame(packet.data)
	end, "a reliable packet fed to get_chunk_frame", "reliable packet on the unreliable path")
end)

test("get_chunk_frame errors loudly on a wire format version mismatch", function(env)
	local s, c = env.server, env.client
	local Position = make_unreliable_component(env)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, Position, 1)
	env.frame()

	-- chunk buffers are shared by reference across a visibility node's clients, so bump the copy's version byte
	local chunk = deep_copy(s.net.generate_unreliable_chunks()[env.player_a][1])
	buffer.writeu8(chunk, 0, buffer.readu8(chunk, 0) + 1)
	expect_error(function()
		c.net.get_chunk_frame(chunk)
	end, "reading the frame of a chunk with a mismatched wire format version", "wire format version")
end)

test("get_chunk_frame is a pure read that never advances the staleness gate", function(env)
	local s, c = env.server, env.client
	local Position, CPosition = make_unreliable_component(env)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, Position, 1)
	env.sync(env.player_a)
	local le = c.net.get_client_entity(e)

	s.world:set(e, Position, 10)
	local old_chunks = s.net.generate_unreliable_chunks()[env.player_a]

	s.world:set(e, Position, 20)
	local new_chunks = s.net.generate_unreliable_chunks()[env.player_a]

	-- reading the newer frame must not stand in for reconciling it
	for _, chunk in new_chunks do
		c.net.get_chunk_frame(chunk)
	end

	for _, chunk in old_chunks do
		c.net.reconcile_chunk(chunk)
	end
	expect_equal(c.world:get(le, CPosition), 10, "the older chunk still applied; the read never moved the gate")

	for _, chunk in new_chunks do
		c.net.reconcile_chunk(chunk)
	end
	expect_equal(c.world:get(le, CPosition), 20, "the newer frame applies normally after it is actually reconciled")
end)

test("a frame parked in an upvalue timestamps the values a changed override captures", function(env)
	local s, c = env.server, env.client
	local Position, CPosition = make_unreliable_component(env)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, Position, 1)
	env.sync(env.player_a)
	local le = c.net.get_client_entity(e)

	-- the pattern the accessor exists for: read the frame, park it, reconcile, and let the override stamp
	-- whatever it captures with the frame those values were serialized against
	local current_frame = nil
	local captured = {}
	c.net.set_changed_override(CPosition, function(entity, value)
		table.insert(captured, { frame = current_frame, entity = entity, value = value })
	end)

	local first_chunks = nil
	for i = 1, 3 do
		s.world:set(e, Position, i * 10)
		local chunks = s.net.generate_unreliable_chunks()[env.player_a]
		if first_chunks == nil then
			first_chunks = chunks
		end
		for _, chunk in chunks do
			current_frame = c.net.get_chunk_frame(chunk)
			c.net.reconcile_chunk(chunk)
			current_frame = nil
		end
	end

	expect_equal(#captured, 3, "the override ran once per frame's chunk")
	for i = 1, 3 do
		expect_equal(captured[i].entity, le, `capture {i} entity`)
		expect_equal(captured[i].value, i * 10, `capture {i} value`)
	end
	expect_equal(captured[2].frame, captured[1].frame + 1, "the second capture carries the next frame")
	expect_equal(captured[3].frame, captured[2].frame + 1, "the third capture carries the next frame")

	-- a stale chunk drops whole before any override fires, so a parked frame never stamps stale values -- and
	-- the pure read still hands back the frame the chunk was generated under, two frames behind the gate
	local stale_frames = {}
	for _, chunk in first_chunks do
		current_frame = c.net.get_chunk_frame(chunk)
		table.insert(stale_frames, current_frame)
		c.net.reconcile_chunk(chunk)
		current_frame = nil
	end
	expect_equal(#captured, 3, "the replayed stale chunk never reached the override")
	expect_equal(stale_frames[1], captured[1].frame, "the replayed chunk still reads its original frame")
end)

test("clients in different shards with equal visibility share unreliable chunk buffers by reference", function(env)
	local s = env.server
	join_fillers(env, 30) -- shard 1 now holds its full 32 (A, B, and 30 fillers)

	local cross = fake_player("Cross")
	s.net.add_client(cross)
	env.frame() -- opens shard 2 with cross as its sole occupant

	local Position = make_unreliable_component(env)

	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, Position, 1)
	env.frame() -- everyone, including cross, observes the creation and initial value

	s.world:set(e, Position, 2)
	local chunks = s.net.generate_unreliable_chunks()
	expect(chunks[env.player_a] ~= nil and chunks[cross] ~= nil, "both shard-1 and shard-2 clients received chunks")
	expect_equal(#chunks[env.player_a], 1, "one chunk for the single shared visibility group")
	expect_equal(#chunks[cross], 1, "one chunk for the single shared visibility group")
	expect_equal(
		chunks[env.player_a][1],
		chunks[cross][1],
		"clients in different shards with equal visibility share the exact same chunk buffer"
	)
end)

test("NetworkedUnreliable assigned before the first frame streams through both channels", function()
	local world = jecs.world()
	local net = duplecs.server(world)
	local defs = make_defs(world)

	local Position = world:component()
	world:set(Position, net.Serdes, f64_serdes)
	world:add(Position, net.NetworkedUnreliable)

	local e = world:entity()
	world:add(e, net.Replicated)
	world:set(e, Position, 9)

	local player_a = fake_player("CatchupUnreliableA")
	net.add_client(player_a)

	local packets = net.generate_packets()

	local server = { world = world, net = net, defs = defs }
	local client_a = make_client(server)
	local Position_c = client_a.world:component()
	client_a.net.set_client_entity(Position, Position_c)
	client_a.world:set(Position_c, client_a.net.Serdes, f64_serdes)
	client_a.net.reconcile_packet(deep_copy(packets[player_a]))

	local le = client_a.net.get_client_entity(e)
	expect(le ~= nil, "the first full packet created the entity")
	expect_equal(client_a.world:get(le, Position_c), 9, "the full packet carried the pre-frame value reliably")

	world:set(e, Position, 20)
	local chunks = net.generate_unreliable_chunks()
	expect(
		chunks[player_a] ~= nil,
		"the pre-existing NetworkedUnreliable component streams through the unreliable channel"
	)
	for _, chunk in chunks[player_a] do
		client_a.net.reconcile_chunk(chunk)
	end
	expect_equal(
		client_a.world:get(le, Position_c),
		20,
		"the unreliable channel works for a component tracked before the first frame"
	)
end)

-- 27) name-mapped target recycle (docs/target_recycle.md)

-- when a name-mapped (named, unreplicated) pair target dies and its dense id
-- recycles into another replication-relevant target within one
-- generate_packets interval, the old and new tenants alias one pair-cell key
-- server-side and one mapping slot client-side. the four tests below (one per
-- manifestation) are folded in from the fix's repro script
-- (tests/repro_target_recycle.luau, now deleted); the corner and semantic-delta
-- tests below them cover the traced edges the fix's design doc calls out.
-- Likes (a value relation) and Targeting (a tag relation) are reused so
-- manifestation 3 can recycle via one relation and check the other.

test(
	"a same-subject pair to a recycled named target ends with the new tenant's pair and drops the old one (manifestation 1)",
	function(env)
		local s, c = env.server, env.client
		local subject = s.world:entity()
		s.world:add(subject, s.net.Replicated)
		local target_old = s.world:entity() -- named, never Replicated
		s.world:set(target_old, jecs.Name, "OldRecycleTarget1")
		local client_old = c.world:entity()
		c.world:set(client_old, jecs.Name, "OldRecycleTarget1")
		s.world:set(subject, pair(s.defs.Likes, target_old), 5)
		env.sync(env.player_a)

		local le_subject = c.net.get_client_entity(subject)
		expect_equal(c.net.get_client_entity(target_old), client_old, "old target auto-mapped by name")
		expect_equal(c.world:get(le_subject, pair(c.defs.Likes, client_old)), 5, "baseline pair replicated")

		s.world:delete(target_old)
		local target_new = s.world:entity()
		expect(
			jecs.ECS_ID(target_new) == jecs.ECS_ID(target_old) and target_new ~= target_old,
			"precondition: jecs did not recycle the deleted id, scenario cannot be tested"
		)
		s.world:set(target_new, jecs.Name, "NewRecycleTarget1")
		local client_new = c.world:entity()
		c.world:set(client_new, jecs.Name, "NewRecycleTarget1")
		s.world:set(subject, pair(s.defs.Likes, target_new), 9)
		env.sync(env.player_a)

		expect_equal(
			c.world:get(le_subject, pair(c.defs.Likes, client_new)),
			9,
			"the new tenant's pair reached the client"
		)
		expect_equal(
			c.world:has(le_subject, pair(c.defs.Likes, client_old)),
			false,
			"the old tenant's pair was removed from the client subject"
		)
		expect_equal(c.net.get_server_entity(client_old), nil, "the superseding announcement ended the stale mapping")
		expect_equal(
			c.world:contains(client_old),
			true,
			"the sweep removed the old tenant's cells without deleting the client's own named entity"
		)
	end
)

test(
	"a different subject's pair to the old named tenant is swept even as a same-frame recycle sends the new tenant's pair elsewhere (manifestation 2)",
	function(env)
		local s, c = env.server, env.client
		local e1 = s.world:entity()
		local e2 = s.world:entity()
		s.world:add(e1, s.net.Replicated)
		s.world:add(e2, s.net.Replicated)
		local target_old = s.world:entity()
		s.world:set(target_old, jecs.Name, "OldRecycleTarget2")
		local client_old = c.world:entity()
		c.world:set(client_old, jecs.Name, "OldRecycleTarget2")
		s.world:set(e2, pair(s.defs.Likes, target_old), 5)
		env.sync(env.player_a)

		local le1 = c.net.get_client_entity(e1)
		local le2 = c.net.get_client_entity(e2)
		expect_equal(c.world:get(le2, pair(c.defs.Likes, client_old)), 5, "baseline pair replicated")

		s.world:delete(target_old)
		local target_new = s.world:entity()
		expect(
			jecs.ECS_ID(target_new) == jecs.ECS_ID(target_old) and target_new ~= target_old,
			"precondition: jecs did not recycle the deleted id, scenario cannot be tested"
		)
		s.world:set(target_new, jecs.Name, "NewRecycleTarget2")
		local client_new = c.world:entity()
		c.world:set(client_new, jecs.Name, "NewRecycleTarget2")
		s.world:set(e1, pair(s.defs.Likes, target_new), 9)
		env.sync(env.player_a)

		expect_equal(c.world:get(le1, pair(c.defs.Likes, client_new)), 9, "e1's new pair reached the client")
		expect_equal(
			c.world:has(le2, pair(c.defs.Likes, client_old)),
			false,
			"e2's old-tenant pair was removed from the client"
		)
	end
)

test(
	"a recycled named target's pair under an untouched relation is swept even though the recycle re-indexed via a different relation (manifestation 3)",
	function(env)
		local s, c = env.server, env.client
		local e1 = s.world:entity()
		local e3 = s.world:entity()
		s.world:add(e1, s.net.Replicated)
		s.world:add(e3, s.net.Replicated)
		local target_old = s.world:entity()
		s.world:set(target_old, jecs.Name, "OldRecycleTarget3")
		local client_old = c.world:entity()
		c.world:set(client_old, jecs.Name, "OldRecycleTarget3")
		s.world:add(e3, pair(s.defs.Targeting, target_old))
		env.sync(env.player_a)

		local le1 = c.net.get_client_entity(e1)
		local le3 = c.net.get_client_entity(e3)
		expect_equal(c.world:has(le3, pair(c.defs.Targeting, client_old)), true, "baseline tag pair replicated")

		s.world:delete(target_old)
		local target_new = s.world:entity()
		expect(
			jecs.ECS_ID(target_new) == jecs.ECS_ID(target_old) and target_new ~= target_old,
			"precondition: jecs did not recycle the deleted id, scenario cannot be tested"
		)
		s.world:set(target_new, jecs.Name, "NewRecycleTarget3")
		local client_new = c.world:entity()
		c.world:set(client_new, jecs.Name, "NewRecycleTarget3")
		-- the re-index happens through a different relation's pair than the one
		-- whose old-tenant pair must be swept
		s.world:set(e1, pair(s.defs.Likes, target_new), 9)
		env.sync(env.player_a)

		expect_equal(c.world:get(le1, pair(c.defs.Likes, client_new)), 9, "e1's new pair reached the client")
		expect_equal(
			c.world:has(le3, pair(c.defs.Targeting, client_old)),
			false,
			"e3's Targeting pair on the old tenant was removed from the client"
		)
	end
)

test(
	"a recycled named target turning Replicated mints a fresh client entity instead of adopting the stale name mapping (manifestation 4)",
	function(env)
		local s, c = env.server, env.client
		local subject = s.world:entity()
		s.world:add(subject, s.net.Replicated)
		local target_old = s.world:entity()
		s.world:set(target_old, jecs.Name, "OldRecycleTarget4")
		local client_old = c.world:entity()
		c.world:set(client_old, jecs.Name, "OldRecycleTarget4")
		s.world:set(subject, pair(s.defs.Likes, target_old), 5)
		env.sync(env.player_a)

		local le_subject = c.net.get_client_entity(subject)
		expect_equal(c.net.get_client_entity(target_old), client_old, "old target auto-mapped by name")
		expect_equal(c.world:get(le_subject, pair(c.defs.Likes, client_old)), 5, "baseline pair replicated")

		s.world:delete(target_old)
		local target_new = s.world:entity()
		expect(
			jecs.ECS_ID(target_new) == jecs.ECS_ID(target_old) and target_new ~= target_old,
			"precondition: jecs did not recycle the deleted id, scenario cannot be tested"
		)
		s.world:add(target_new, s.net.Replicated)
		s.world:set(subject, pair(s.defs.Likes, target_new), 9)
		env.sync(env.player_a)

		local lt = c.net.get_client_entity(target_new)
		expect(lt ~= nil, "the new replicated tenant imported")
		expect(
			lt ~= client_old,
			"the new tenant minted a fresh client entity instead of adopting the definition entity"
		)
		expect_equal(c.net.get_server_entity(client_old), nil, "the stale name mapping ended")
		-- the recycle makes the old tenant's removal unshippable (the target dense id already resolves to the new
		-- tenant), so the creation's stale-mapping teardown sweep is the only thing clearing the old pair
		expect_equal(
			c.world:has(le_subject, pair(c.defs.Likes, client_old)),
			false,
			"the creation's teardown swept the old tenant's pair"
		)
		expect_equal(
			c.world:get(le_subject, pair(c.defs.Likes, lt)),
			9,
			"the new tenant's pair reached its fresh entity"
		)

		s.world:delete(target_new)
		env.sync(env.player_a)
		expect_equal(
			c.world:contains(client_old),
			true,
			"the client's named definition entity survived the tenant's deletion"
		)
	end
)

test(
	"an unnamed recycled tenant announces nothing, so the retraction-time sweep alone removes the old tenant's pairs (corner)",
	function(env)
		local s, c = env.server, env.client
		local subject = s.world:entity()
		s.world:add(subject, s.net.Replicated)
		local target_old = s.world:entity()
		s.world:set(target_old, jecs.Name, "OldRecycleTarget5")
		local client_old = c.world:entity()
		c.world:set(client_old, jecs.Name, "OldRecycleTarget5")
		s.world:set(subject, pair(s.defs.Likes, target_old), 5)
		env.sync(env.player_a)

		local le_subject = c.net.get_client_entity(subject)
		expect_equal(c.world:get(le_subject, pair(c.defs.Likes, client_old)), 5, "baseline pair replicated")

		s.world:delete(target_old)
		local target_new = s.world:entity()
		expect(
			jecs.ECS_ID(target_new) == jecs.ECS_ID(target_old) and target_new ~= target_old,
			"precondition: jecs did not recycle the deleted id, scenario cannot be tested"
		)
		-- target_new is neither named nor Replicated: not replication-relevant, so
		-- no announcement overwrites the retraction and no creation ever adopts it
		s.world:set(subject, pair(s.defs.Likes, target_new), 9)
		env.sync(env.player_a)

		expect_equal(
			c.world:has(le_subject, pair(c.defs.Likes, client_old)),
			false,
			"the old tenant's pair was removed from the client subject"
		)
		-- the retraction is what ended the mapping, and its sweep is the only thing that could have removed the
		-- pair above -- the unreplicable new tenant announces nothing and ships nothing
		expect_equal(c.net.get_server_entity(client_old), nil, "the retraction ended the name mapping")
		expect_equal(c.world:contains(client_old), true, "the client's named entity survived the sweep")
		expect_equal(c.net.get_client_entity(target_new), nil, "the unreplicable new tenant never imported")
	end
)

test(
	"a bucket that empties and the same live named target re-indexing in one frame still ships the legitimate removal (corner)",
	function(env)
		local s, c = env.server, env.client
		local subject = s.world:entity()
		local e3 = s.world:entity()
		s.world:add(subject, s.net.Replicated)
		s.world:add(e3, s.net.Replicated)
		local target = s.world:entity() -- named, stays alive the whole scenario
		s.world:set(target, jecs.Name, "StableRebucketTarget")
		local client_target = c.world:entity()
		c.world:set(client_target, jecs.Name, "StableRebucketTarget")
		s.world:set(subject, pair(s.defs.Likes, target), 5)
		env.sync(env.player_a)

		local le_subject = c.net.get_client_entity(subject)
		local le3 = c.net.get_client_entity(e3)
		expect_equal(c.world:get(le_subject, pair(c.defs.Likes, client_target)), 5, "baseline pair replicated")

		-- the only pair to target is removed, emptying its tracked bucket, while a
		-- different pair to the same still-alive target re-indexes it in the same
		-- frame -- the retired and live gens match, so nothing is dropped
		s.world:remove(subject, pair(s.defs.Likes, target))
		s.world:add(e3, pair(s.defs.Targeting, target))
		env.sync(env.player_a)

		expect_equal(
			c.world:has(le_subject, pair(c.defs.Likes, client_target)),
			false,
			"the legitimate removal still shipped and applied"
		)
		expect_equal(
			c.world:has(le3, pair(c.defs.Targeting, client_target)),
			true,
			"the same-target re-index via a different pair still ships"
		)
		expect_equal(c.net.get_client_entity(target), client_target, "the mapping survives, the target never died")
	end
)

test(
	"the mapping-teardown sweep also removes a client-created pair riding an imported relation and subject on a withdrawn name (semantic delta)",
	function(env)
		local s, c = env.server, env.client
		local subject = s.world:entity() -- a server-side pair, only to name-map the target
		local subject2 = s.world:entity() -- purely a vehicle for a client-manufactured pair
		s.world:add(subject, s.net.Replicated)
		s.world:add(subject2, s.net.Replicated)
		local target = s.world:entity()
		s.world:set(target, jecs.Name, "SemanticDeltaTarget")
		local client_target = c.world:entity()
		c.world:set(client_target, jecs.Name, "SemanticDeltaTarget")
		s.world:set(subject, pair(s.defs.Likes, target), 5) -- names the target on the wire
		local likes_pair = pair(s.defs.Likes, target) -- dense pair id, captured before the target dies
		env.sync(env.player_a)

		local le_subject = c.net.get_client_entity(subject)
		local le_subject2 = c.net.get_client_entity(subject2)
		expect_equal(c.net.get_client_entity(target), client_target, "target auto-mapped by name")
		expect_equal(c.world:get(le_subject, pair(c.defs.Likes, client_target)), 5, "baseline pair replicated")

		-- the client locally creates its own pair, riding an imported relation and
		-- an imported subject, targeting the name-mapped entity -- the server
		-- never set this pair
		c.world:set(le_subject2, pair(c.defs.Likes, client_target), "local-only")

		-- the two cells on the far side of the boundary, which the sweep must
		-- leave alone: one whose subject is purely local, one whose relation is
		local local_subject = c.world:entity()
		c.world:set(local_subject, pair(c.defs.Likes, client_target), "local-subject")
		local local_relation = c.world:component()
		c.world:set(le_subject2, pair(local_relation, client_target), "local-relation")

		s.world:delete(target) -- plain death, no recycle
		local packet = env.sync(env.player_a)

		-- no recycle, so the server's own cell is cleaned by an explicit removal that applies before the
		-- retraction; the sweep is left with only the client-created pair
		local likes_section = packet.components[likes_pair]
		expect(
			likes_section ~= nil and likes_section.removed ~= nil and likes_section.removed[1] == subject,
			"the death shipped an explicit removal for the server's own pair"
		)
		expect_equal(
			c.world:has(le_subject, pair(c.defs.Likes, client_target)),
			false,
			"the server's own pair was removed from the client"
		)
		expect_equal(
			c.world:has(le_subject2, pair(c.defs.Likes, client_target)),
			false,
			"the client-created pair was swept when the server withdrew the name"
		)
		expect_equal(
			c.world:get(local_subject, pair(c.defs.Likes, client_target)),
			"local-subject",
			"a pair on a purely local subject is never swept"
		)
		expect_equal(
			c.world:get(le_subject2, pair(local_relation, client_target)),
			"local-relation",
			"a pair riding a purely local relation is never swept"
		)
		expect_equal(c.net.get_server_entity(client_target), nil, "the retraction ended the name mapping")
		expect_equal(c.world:contains(client_target), true, "the client's named entity survived the sweep")
	end
)

test(
	"the mapping-teardown sweep dispatches removals through a registered override instead of world:remove",
	function(env)
		local s, c = env.server, env.client
		local subject = s.world:entity()
		s.world:add(subject, s.net.Replicated)
		local target_old = s.world:entity()
		s.world:set(target_old, jecs.Name, "OverrideSweepOld")
		local client_old = c.world:entity()
		c.world:set(client_old, jecs.Name, "OverrideSweepOld")
		s.world:set(subject, pair(s.defs.Likes, target_old), 5)
		env.sync(env.player_a)

		local le_subject = c.net.get_client_entity(subject)
		expect_equal(c.world:get(le_subject, pair(c.defs.Likes, client_old)), 5, "baseline pair replicated")

		local calls = {}
		c.net.set_removed_override(pair(c.defs.Likes, jecs.Wildcard), function(entity)
			table.insert(calls, entity)
		end)

		-- the recycle drops the server's explicit removal (removed_allowed narrows
		-- to 0), so the override below can only fire via the client sweep
		s.world:delete(target_old)
		local target_new = s.world:entity()
		expect(
			jecs.ECS_ID(target_new) == jecs.ECS_ID(target_old) and target_new ~= target_old,
			"precondition: jecs did not recycle the deleted id, scenario cannot be tested"
		)
		s.world:set(target_new, jecs.Name, "OverrideSweepNew")
		local client_new = c.world:entity()
		c.world:set(client_new, jecs.Name, "OverrideSweepNew")
		s.world:set(subject, pair(s.defs.Likes, target_new), 9)
		env.sync(env.player_a)

		expect_equal(#calls, 1, "the sweep invoked the override exactly once")
		expect_equal(calls[1], le_subject, "the override received the subject")
		expect_equal(
			c.world:get(le_subject, pair(c.defs.Likes, client_old)),
			5,
			"the override suppressed the default world:remove, leaving the old value in place"
		)
		expect_equal(
			c.world:get(le_subject, pair(c.defs.Likes, client_new)),
			9,
			"the new tenant's pair still applied normally"
		)
	end
)

-- 28) definition recycle (docs/target_recycle.md, "the definitions sibling")

-- the same dense-aliasing class one level up: a tracked definition (a
-- Networked tag relation or unpaired tag component minted with world:entity())
-- stop-tracked, deleted, and re-tracked under a recycled dense id within one
-- generate_packets interval misresolves the old definition's staged removals
-- the same way section 27's named targets did. the five tests below (one per
-- scenario) are folded in from the fix's repro script
-- (tests/repro_definition_recycle.luau, now deleted); the corner and
-- semantic-delta tests below them cover the traced edges the fix's design
-- doc calls out. pair cells alias server-side too (packed pair ids carry
-- only the relation's dense half), while unpaired cells alias only on the wire
-- and the client's mapping (unpaired store keys are gen-qualified full ids).

test(
	"a same-subject pair to a recycled tracked relation ends with the new definition's pair and drops the old one (definition scenario 1)",
	function(env)
		local s, c = env.server, env.client
		local subject = s.world:entity()
		s.world:add(subject, s.net.Replicated)
		local target = s.world:entity() -- named, unreplicated: a stable shared pair target
		s.world:set(target, jecs.Name, "DefRecycleTarget1")
		local client_target = c.world:entity()
		c.world:set(client_target, jecs.Name, "DefRecycleTarget1")

		local rel_old = s.world:entity() -- tag relation, name-mapped definition
		s.world:set(rel_old, jecs.Name, "OldRelDef1")
		s.world:add(rel_old, s.net.Networked)
		local client_rel_old = c.world:entity()
		c.world:set(client_rel_old, jecs.Name, "OldRelDef1")

		s.world:add(subject, pair(rel_old, target))
		env.sync(env.player_a)

		local le_subject = c.net.get_client_entity(subject)
		expect_equal(c.net.get_client_entity(rel_old), client_rel_old, "old relation auto-mapped by name")
		expect_equal(c.world:has(le_subject, pair(client_rel_old, client_target)), true, "baseline pair replicated")

		s.world:delete(rel_old)
		local rel_new = s.world:entity()
		expect(
			jecs.ECS_ID(rel_new) == jecs.ECS_ID(rel_old) and rel_new ~= rel_old,
			"precondition: jecs did not recycle the deleted id, scenario cannot be tested"
		)
		s.world:set(rel_new, jecs.Name, "NewRelDef1")
		s.world:add(rel_new, s.net.Networked)
		local client_rel_new = c.world:entity()
		c.world:set(client_rel_new, jecs.Name, "NewRelDef1")
		s.world:add(subject, pair(rel_new, target))
		env.sync(env.player_a)

		expect_equal(
			c.world:has(le_subject, pair(client_rel_new, client_target)),
			true,
			"the new relation's pair reached the client"
		)
		expect_equal(
			c.world:has(le_subject, pair(client_rel_old, client_target)),
			false,
			"the old relation's pair was removed from the client subject"
		)
	end
)

test(
	"a different subject's pair to the old tracked relation is swept even as a same-frame recycle sends the new relation's pair elsewhere (definition scenario 2)",
	function(env)
		local s, c = env.server, env.client
		local e1 = s.world:entity()
		local e2 = s.world:entity()
		s.world:add(e1, s.net.Replicated)
		s.world:add(e2, s.net.Replicated)
		local target = s.world:entity()
		s.world:set(target, jecs.Name, "DefRecycleTarget2")
		local client_target = c.world:entity()
		c.world:set(client_target, jecs.Name, "DefRecycleTarget2")

		local rel_old = s.world:entity()
		s.world:set(rel_old, jecs.Name, "OldRelDef2")
		s.world:add(rel_old, s.net.Networked)
		local client_rel_old = c.world:entity()
		c.world:set(client_rel_old, jecs.Name, "OldRelDef2")

		s.world:add(e2, pair(rel_old, target))
		env.sync(env.player_a)

		local le1 = c.net.get_client_entity(e1)
		local le2 = c.net.get_client_entity(e2)
		expect_equal(c.world:has(le2, pair(client_rel_old, client_target)), true, "baseline pair replicated")

		s.world:delete(rel_old)
		local rel_new = s.world:entity()
		expect(
			jecs.ECS_ID(rel_new) == jecs.ECS_ID(rel_old) and rel_new ~= rel_old,
			"precondition: jecs did not recycle the deleted id, scenario cannot be tested"
		)
		s.world:set(rel_new, jecs.Name, "NewRelDef2")
		s.world:add(rel_new, s.net.Networked)
		local client_rel_new = c.world:entity()
		c.world:set(client_rel_new, jecs.Name, "NewRelDef2")
		s.world:add(e1, pair(rel_new, target))
		env.sync(env.player_a)

		expect_equal(c.world:has(le1, pair(client_rel_new, client_target)), true, "e1's new pair reached the client")
		expect_equal(
			c.world:has(le2, pair(client_rel_old, client_target)),
			false,
			"e2's old-relation pair was removed from the client"
		)
	end
)

test(
	"a different subject's unpaired cell under the old tracked component is swept even as a same-frame recycle sends the new component's cell elsewhere (definition scenario 3)",
	function(env)
		local s, c = env.server, env.client
		local e1 = s.world:entity()
		local e2 = s.world:entity()
		s.world:add(e1, s.net.Replicated)
		s.world:add(e2, s.net.Replicated)

		local comp_old = s.world:entity() -- unpaired tag component, name-mapped definition
		s.world:set(comp_old, jecs.Name, "OldCompDef3")
		s.world:add(comp_old, s.net.Networked)
		local client_comp_old = c.world:entity()
		c.world:set(client_comp_old, jecs.Name, "OldCompDef3")

		s.world:add(e2, comp_old)
		env.sync(env.player_a)

		local le1 = c.net.get_client_entity(e1)
		local le2 = c.net.get_client_entity(e2)
		expect_equal(c.world:has(le2, client_comp_old), true, "baseline unpaired cell replicated")

		s.world:delete(comp_old)
		local comp_new = s.world:entity()
		expect(
			jecs.ECS_ID(comp_new) == jecs.ECS_ID(comp_old) and comp_new ~= comp_old,
			"precondition: jecs did not recycle the deleted id, scenario cannot be tested"
		)
		s.world:set(comp_new, jecs.Name, "NewCompDef3")
		s.world:add(comp_new, s.net.Networked)
		local client_comp_new = c.world:entity()
		c.world:set(client_comp_new, jecs.Name, "NewCompDef3")
		s.world:add(e1, comp_new)
		env.sync(env.player_a)

		expect_equal(c.world:has(le1, client_comp_new), true, "e1's new unpaired cell reached the client")
		expect_equal(c.world:has(le2, client_comp_old), false, "e2's old-definition cell was removed from the client")
	end
)

test(
	"a same-subject unpaired cell recycle resolves to exactly the new component's cell (definition scenario 4)",
	function(env)
		local s, c = env.server, env.client
		local subject = s.world:entity()
		s.world:add(subject, s.net.Replicated)

		local comp_old = s.world:entity()
		s.world:set(comp_old, jecs.Name, "OldCompDef4")
		s.world:add(comp_old, s.net.Networked)
		local client_comp_old = c.world:entity()
		c.world:set(client_comp_old, jecs.Name, "OldCompDef4")

		s.world:add(subject, comp_old)
		env.sync(env.player_a)

		local le = c.net.get_client_entity(subject)
		expect_equal(c.world:has(le, client_comp_old), true, "baseline unpaired cell replicated")

		s.world:delete(comp_old)
		local comp_new = s.world:entity()
		expect(
			jecs.ECS_ID(comp_new) == jecs.ECS_ID(comp_old) and comp_new ~= comp_old,
			"precondition: jecs did not recycle the deleted id, scenario cannot be tested"
		)
		s.world:set(comp_new, jecs.Name, "NewCompDef4")
		s.world:add(comp_new, s.net.Networked)
		local client_comp_new = c.world:entity()
		c.world:set(client_comp_new, jecs.Name, "NewCompDef4")
		s.world:add(subject, comp_new)
		env.sync(env.player_a)

		expect_equal(c.world:has(le, client_comp_new), true, "the new definition's cell reached the client")
		expect_equal(c.world:has(le, client_comp_old), false, "the old definition's cell was removed from the client")
	end
)

test(
	"a recycled tracked relation dense turning Replicated mints a fresh client entity instead of adopting the stale definition mapping (definition scenario 5)",
	function(env)
		local s, c = env.server, env.client
		local subject = s.world:entity()
		s.world:add(subject, s.net.Replicated)
		local target = s.world:entity()
		s.world:set(target, jecs.Name, "DefRecycleTarget5")
		local client_target = c.world:entity()
		c.world:set(client_target, jecs.Name, "DefRecycleTarget5")

		local rel_old = s.world:entity()
		s.world:set(rel_old, jecs.Name, "OldRelDef5")
		s.world:add(rel_old, s.net.Networked)
		local client_rel_old = c.world:entity()
		c.world:set(client_rel_old, jecs.Name, "OldRelDef5")

		s.world:add(subject, pair(rel_old, target))
		env.sync(env.player_a)

		local le_subject = c.net.get_client_entity(subject)
		expect_equal(c.net.get_client_entity(rel_old), client_rel_old, "old relation auto-mapped by name")
		expect_equal(c.world:has(le_subject, pair(client_rel_old, client_target)), true, "baseline pair replicated")

		s.world:delete(rel_old)
		local tenant = s.world:entity()
		expect(
			jecs.ECS_ID(tenant) == jecs.ECS_ID(rel_old) and tenant ~= rel_old,
			"precondition: jecs did not recycle the deleted id, scenario cannot be tested"
		)
		s.world:add(tenant, s.net.Replicated)
		env.sync(env.player_a)

		local lt = c.net.get_client_entity(tenant)
		expect(lt ~= nil, "the new replicated tenant imported")
		expect(
			lt ~= client_rel_old,
			"the new tenant minted a fresh client entity instead of adopting the definition entity"
		)
		expect_equal(c.net.get_server_entity(client_rel_old), nil, "the stale name mapping ended")
		-- the creation's teardown sweep reaches the other walk here: the unmapping entity is the pair's
		-- *relation*, not its target, and the server's own removal misresolves to the fresh tenant on the wire
		expect_equal(
			c.world:has(le_subject, pair(client_rel_old, client_target)),
			false,
			"the pair riding the old definition as its relation was swept"
		)

		s.world:delete(tenant)
		env.sync(env.player_a)
		expect_equal(
			c.world:contains(client_rel_old),
			true,
			"the client's definition entity survived the tenant's deletion"
		)
	end
)

test(
	"an unnamed recycled component re-tracks without announcing, so the retraction-time sweep alone leaves the client clean (definition corner, unpaired)",
	function(env)
		local s, c = env.server, env.client
		local subject = s.world:entity()
		s.world:add(subject, s.net.Replicated)

		local comp_old = s.world:entity()
		s.world:set(comp_old, jecs.Name, "OldCompDef6")
		s.world:add(comp_old, s.net.Networked)
		local client_comp_old = c.world:entity()
		c.world:set(client_comp_old, jecs.Name, "OldCompDef6")

		s.world:add(subject, comp_old)
		env.sync(env.player_a)

		local le = c.net.get_client_entity(subject)
		expect_equal(c.world:has(le, client_comp_old), true, "baseline unpaired cell replicated")

		s.world:delete(comp_old)
		local comp_new = s.world:entity()
		expect(
			jecs.ECS_ID(comp_new) == jecs.ECS_ID(comp_old) and comp_new ~= comp_old,
			"precondition: jecs did not recycle the deleted id, scenario cannot be tested"
		)
		-- comp_new is neither named nor Replicated: no announcement overwrites
		-- the retraction, so the new definition's send misapplies through the
		-- still-live old mapping during sections -- the retraction-time sweep
		-- (post-sections) must remove it along with the old cell
		s.world:add(comp_new, s.net.Networked)
		s.world:add(subject, comp_new)
		env.sync(env.player_a)

		expect_equal(
			c.world:has(le, client_comp_old),
			false,
			"the old cell (and whatever the new definition misapplied through it) was swept"
		)
		expect_equal(c.net.get_server_entity(client_comp_old), nil, "the stale name mapping ended")
	end
)

test(
	"a same-frame stop-and-re-track of the same definition still ships a genuine removal made in between (definition corner)",
	function(env)
		local s, c = env.server, env.client
		local e1 = s.world:entity()
		local e2 = s.world:entity()
		s.world:add(e1, s.net.Replicated)
		s.world:add(e2, s.net.Replicated)

		local comp = s.world:component()
		s.world:set(comp, jecs.Name, "ReTrackSameDef")
		s.world:add(comp, s.net.Networked)
		local client_comp = c.world:component()
		c.world:set(client_comp, jecs.Name, "ReTrackSameDef")

		s.world:set(e1, comp, 1)
		s.world:set(e2, comp, 2)
		env.sync(env.player_a)

		local le1 = c.net.get_client_entity(e1)
		local le2 = c.net.get_client_entity(e2)
		expect_equal(c.world:get(le1, client_comp), 1, "baseline value on e1")
		expect_equal(c.world:get(le2, client_comp), 2, "baseline value on e2")

		-- genuinely remove e1's cell, then stop and immediately re-track the
		-- same definition in the same frame -- the retired gen equals the live
		-- gen (the same component, not a recycled one), so the recycle-signature
		-- drop must not fire
		s.world:remove(e1, comp)
		s.world:remove(comp, s.net.Networked)
		s.world:add(comp, s.net.Networked)
		env.sync(env.player_a)

		expect_equal(c.world:has(le1, client_comp), false, "e1's genuine removal still shipped and applied")
		expect_equal(c.world:get(le2, client_comp), 2, "e2's untouched cell survives the re-track")
	end
)

test(
	"un-networking a definition (no deletion) sweeps a client-created cell while the server's own removal still ships, and the definition entity survives (semantic delta)",
	function(env)
		local s, c = env.server, env.client
		local subject = s.world:entity() -- holds a genuine server-side cell
		local subject2 = s.world:entity() -- purely a vehicle for a client-manufactured cell
		s.world:add(subject, s.net.Replicated)
		s.world:add(subject2, s.net.Replicated)

		local comp = s.world:entity()
		s.world:set(comp, jecs.Name, "UnNetworkedComp")
		s.world:add(comp, s.net.Networked)
		local client_comp = c.world:entity()
		c.world:set(client_comp, jecs.Name, "UnNetworkedComp")

		s.world:add(subject, comp)
		env.sync(env.player_a)

		local le_subject = c.net.get_client_entity(subject)
		local le_subject2 = c.net.get_client_entity(subject2)
		expect_equal(c.net.get_client_entity(comp), client_comp, "the component auto-mapped by name")
		expect_equal(c.world:has(le_subject, client_comp), true, "baseline unpaired cell replicated")

		-- the client locally adds the imported component to a different
		-- imported subject -- the server never set this cell
		c.world:add(le_subject2, client_comp)

		-- the cell on the far side of the boundary, which the sweep must leave
		-- alone: the same imported component on a purely local subject
		local local_subject = c.world:entity()
		c.world:add(local_subject, client_comp)

		s.world:remove(comp, s.net.Networked) -- un-networking, no deletion, no recycle
		env.sync(env.player_a)

		expect_equal(c.world:has(le_subject, client_comp), false, "the server's own removal still shipped and applied")
		expect_equal(
			c.world:has(le_subject2, client_comp),
			false,
			"the client-created cell was swept when the server withdrew the definition's name"
		)
		expect_equal(c.world:has(local_subject, client_comp), true, "the cell on a purely local subject is untouched")
		expect_equal(c.net.get_server_entity(client_comp), nil, "the un-networked definition's mapping ended")
		expect_equal(c.world:contains(client_comp), true, "the client's definition entity survived")
	end
)

test(
	"the mapping-teardown sweep dispatches an unpaired cell's removal through a registered override instead of world:remove",
	function(env)
		local s, c = env.server, env.client
		local subject = s.world:entity()
		s.world:add(subject, s.net.Replicated)

		local comp_old = s.world:entity()
		s.world:set(comp_old, jecs.Name, "OverrideSweepUnpairedOld")
		s.world:add(comp_old, s.net.Networked)
		local client_comp_old = c.world:entity()
		c.world:set(client_comp_old, jecs.Name, "OverrideSweepUnpairedOld")

		s.world:add(subject, comp_old)
		env.sync(env.player_a)

		local le_subject = c.net.get_client_entity(subject)
		expect_equal(c.world:has(le_subject, client_comp_old), true, "baseline unpaired cell replicated")

		local calls = {}
		c.net.set_removed_override(client_comp_old, function(entity)
			table.insert(calls, entity)
		end)

		-- the recycle drops the server's explicit removal (removed_allowed
		-- narrows to 0), so the override below can only fire via the client sweep
		s.world:delete(comp_old)
		local comp_new = s.world:entity()
		expect(
			jecs.ECS_ID(comp_new) == jecs.ECS_ID(comp_old) and comp_new ~= comp_old,
			"precondition: jecs did not recycle the deleted id, scenario cannot be tested"
		)
		s.world:set(comp_new, jecs.Name, "OverrideSweepUnpairedNew")
		s.world:add(comp_new, s.net.Networked)
		local client_comp_new = c.world:entity()
		c.world:set(client_comp_new, jecs.Name, "OverrideSweepUnpairedNew")
		s.world:add(subject, comp_new)
		env.sync(env.player_a)

		expect_equal(#calls, 1, "the sweep invoked the override exactly once")
		expect_equal(calls[1], le_subject, "the override received the subject")
		expect_equal(
			c.world:has(le_subject, client_comp_old),
			true,
			"the override suppressed the default world:remove, leaving the old cell in place"
		)
		expect_equal(c.world:has(le_subject, client_comp_new), true, "the new definition's cell still applied normally")
		-- the sweep is only half the teardown: the superseding announcement must also have ended the old
		-- mapping, or the recycled dense id would keep resolving to the retired definition's client entity
		expect_equal(c.net.get_server_entity(client_comp_old), nil, "the superseded name mapping ended")
		expect_equal(c.net.get_client_entity(comp_new), client_comp_new, "the recycled id rebound to the new name")
	end
)

-- 29) jecs instance mismatch guard

-- the world's first duplecs contact probes it with world:query(jecs.Component) and compares the result's
-- metatable against jecs.Query (see the JECS INSTANCE CHECK comment in shared.luau): every uncached query is
-- stamped with its creator module's exported Query table, so a mismatch means the world came from a different
-- jecs module instance than the one duplecs requires. jecs.luau has no requires of its own, so loading it a
-- second time through luau.load mints an independent module instance -- its own Query table, its own World
-- metatable -- to exercise the mismatch without needing a second jecs release. the guard only warns, so
-- construction still succeeds; these tests cover exactly that: the warning fires and the returned instance
-- looks right. the probe rides the per-world component set, so it fires once per world at whichever accessor
-- touches it first, not once per constructed half.
local foreign_jecs = luau.load(fs.readFile("roblox_packages/jecs.luau"), { debugName = "foreign_jecs" })()

test("duplecs.server on a foreign jecs instance's world warns but still constructs", function()
	local world = foreign_jecs.world()

	expected_warning("created by a different jecs instance")
	local net = duplecs.server(world)

	expect_equal(type(net.generate_packets), "function", "generate_packets is exported")
	expect(net.Replicated ~= nil, "Replicated is exported")
	expect(net.Networked ~= nil, "Networked is exported")
	expect(net.NetworkedOnce ~= nil, "NetworkedOnce is exported")
	expect(net.NetworkedUnreliable ~= nil, "NetworkedUnreliable is exported")
	expect(net.Private ~= nil, "Private is exported")
	expect(net.InheritsPrivacy ~= nil, "InheritsPrivacy is exported")
	expect(net.Serdes ~= nil, "Serdes is exported")
end)

test("duplecs.client on a foreign jecs instance's world warns but still constructs", function()
	local world = foreign_jecs.world()

	expected_warning("created by a different jecs instance")
	local net = duplecs.client(world)

	expect_equal(type(net.reconcile_packet), "function", "reconcile_packet is exported")
	expect(net.Imported ~= nil, "Imported is exported")
	expect(net.Serdes ~= nil, "Serdes is exported")
end)

test("the foreign jecs instance warning fires once per world, at its first duplecs contact", function()
	-- the component set is minted once per world, so the probe runs once: constructing both halves on one
	-- foreign world -- and re-reading the accessors afterwards -- must not warn a second time.
	local world = foreign_jecs.world()

	expected_warning("created by a different jecs instance")
	local components = duplecs.shared(world)

	local server_net = duplecs.server(world)
	local client_net = duplecs.client(world)

	-- the re-reads are what a second probe would ride: each must hand back the first call's result untouched
	expect_equal(duplecs.shared(world), components, "the second shared call returned the world's minted set")
	expect_equal(duplecs.server(world), server_net, "the second server call returned the memoized instance")
	expect_equal(duplecs.client(world), client_net, "the second client call returned the memoized instance")

	expect_equal(server_net.Networked, components.Networked, "the server half returned the world's minted set")
	expect_equal(client_net.Imported, components.Imported, "the client half returned the world's minted set")
end)

-- 30) the injectable warn hook (set_warn_hook)

-- both instances export set_warn_hook, replacing the sink that instance's warnings emit through (the global
-- warn by default, restored by passing nil). the hook receives exactly the string the global would have
-- printed, prefix included, so these tests assert the message itself and its argument shape rather than
-- leaving it to the harness's capture, which a hook of the test's own diverts warnings away from (a warning
-- reaching the global sink again after set_warn_hook(nil) is back under the capture, and declared as usual).
-- errors are unaffected by the hook and are covered by expect_error elsewhere.

test("a server warn hook receives the instance's warning as one prefixed string", function(env)
	local s = env.server
	local stranger = fake_player("HookStranger") -- never passed to add_client

	local captured = {}
	local extra_argument_counts = {}
	s.net.set_warn_hook(function(message, ...)
		table.insert(captured, message)
		table.insert(extra_argument_counts, select("#", ...))
	end)
	s.net.mark_client_fresh(stranger)

	expect_equal(#captured, 1, "the hook fired exactly once")
	expect_equal(extra_argument_counts[1], 0, "the hook receives exactly one argument")
	expect_equal(type(captured[1]), "string", "the hook receives the message as a string")
	expect_equal(
		string.sub(captured[1], 1, #message_prefix),
		message_prefix,
		"the captured message carries the shared prefix"
	)
	expect(
		string.find(captured[1], "cannot mark an untracked client fresh!", 1, true) ~= nil,
		"the captured message carries the warning's own text"
	)
end)

test("clearing a server warn hook with nil restores the default sink", function(env)
	local s = env.server
	local stranger = fake_player("RestoredStranger")

	local captured = 0
	s.net.set_warn_hook(function()
		captured += 1
	end)
	s.net.mark_client_fresh(stranger)
	expect_equal(captured, 1, "the installed hook saw the first warning")

	s.net.set_warn_hook(nil)
	expected_warning("cannot mark an untracked client fresh!") -- the same warning again, back on the global sink
	s.net.mark_client_fresh(stranger)

	expect_equal(captured, 1, "the cleared hook never sees another warning")
end)

test("a warn hook applies to the instance it was installed on only", function(env)
	-- a second server instance on its own world: the reporters are per instance, so a hook must never see the
	-- other instance's warnings, in either direction.
	local other_world = jecs.world()
	local other_net = duplecs.server(other_world)

	local s = env.server
	local own_captured = {}
	local other_captured = {}
	s.net.set_warn_hook(function(message)
		table.insert(own_captured, message)
	end)
	other_net.set_warn_hook(function(message)
		table.insert(other_captured, message)
	end)

	s.net.mark_client_fresh(fake_player("IsolatedStranger"))
	expect_equal(#own_captured, 1, "the warning reached the hook of the instance that emitted it")
	expect_equal(#other_captured, 0, "the other instance's hook saw nothing")

	other_net.mark_client_fresh(fake_player("OtherStranger"))
	expect_equal(#other_captured, 1, "the second instance's warning reached its own hook")
	expect_equal(#own_captured, 1, "the first instance's hook saw nothing new")
end)

test("the client half's warn hook captures its own warnings, independently of the server's", function(env)
	local s, c = env.server, env.client
	-- unnamed and never mapped, so nothing announces it and its section has no client mapping on arrival
	local unmapped = s.world:component()

	local server_captured = {}
	local client_captured = {}
	s.net.set_warn_hook(function(message)
		table.insert(server_captured, message)
	end)
	c.net.set_warn_hook(function(message)
		table.insert(client_captured, message)
	end)

	s.world:add(unmapped, s.net.Networked)
	local e = s.world:entity()
	s.world:add(e, s.net.Replicated)
	s.world:set(e, unmapped, 1)
	env.sync(env.player_a) -- generation stays silent; reconciliation warns about the unmapped component

	expect_equal(#client_captured, 1, "the client's hook captured the reconcile warning")
	expect_equal(
		string.sub(client_captured[1], 1, #message_prefix),
		message_prefix,
		"the client's captured message carries the shared prefix"
	)
	expect(
		string.find(client_captured[1], "has no client mapping!", 1, true) ~= nil,
		"the captured message names the section's missing client mapping"
	)
	expect_equal(#server_captured, 0, "the server instance's hook saw nothing: the halves report independently")

	-- the other direction, without which a server hook that was never installed at all would satisfy the zero
	-- above: make the server warn, and check the two hooks stay separate
	s.net.mark_client_fresh(fake_player("HookHalvesStranger"))
	expect_equal(#server_captured, 1, "the server's own warning reached the server hook")
	expect_equal(#client_captured, 1, "the client's hook saw nothing new")
end)

-- 31) the per-world accessors and pre-construction schema

-- the module root returns three per-world accessors: duplecs.server and duplecs.client construct their half
-- on the first call for a world and return that same instance ever after, and duplecs.shared returns the
-- world's full component set, minted at the world's first duplecs contact whichever accessor that is. the set
-- therefore can predate construction, so a side-agnostic schema module may tag definitions, filter privacy,
-- and register serdes hooks before either half exists; construction then replays that pre-existing state
-- through the same handlers the live hooks use (see the CONSTRUCTION CATCH-UP section in server.luau). the
-- tests below cover the accessors' identity, the replay's equivalence with a post-construction schema, and
-- the two seams the replay has: a pre-existing misuse errors from the construction call rather than from the
-- offending add, and a *valued* privacy filter sanitizes against a tracked-client set that is necessarily
-- empty before construction, so every client it names is pruned.

test("the per-world accessors memoize their instance and share one component set", function()
	-- one world per side, as production has: an instance is memoized per world and per half, while the
	-- component set is minted once per world for both halves and the schema to share.
	local server_world = jecs.world()
	local components = duplecs.shared(server_world)
	local server_net = duplecs.server(server_world)

	expect_equal(duplecs.server(server_world), server_net, "duplecs.server returns the first call's instance")
	expect_equal(duplecs.shared(server_world), components, "duplecs.shared returns the world's minted set")
	expect_equal(table.isfrozen(components), true, "the shared set is frozen")

	expect_equal(server_net.Networked, components.Networked, "Networked comes from the shared set")
	expect_equal(server_net.NetworkedOnce, components.NetworkedOnce, "NetworkedOnce comes from the shared set")
	expect_equal(
		server_net.NetworkedUnreliable,
		components.NetworkedUnreliable,
		"NetworkedUnreliable comes from the shared set"
	)
	expect_equal(server_net.Replicated, components.Replicated, "Replicated comes from the shared set")
	expect_equal(server_net.Private, components.Private, "Private comes from the shared set")
	expect_equal(server_net.InheritsPrivacy, components.InheritsPrivacy, "InheritsPrivacy comes from the shared set")
	expect_equal(server_net.Serdes, components.Serdes, "Serdes comes from the shared set")

	-- shared hands back the whole set whichever half constructs; an instance carries only its own side's slice
	expect(components.Imported ~= nil, "the shared set carries the client-side entry too")
	expect_equal(server_net.Imported, nil, "the server instance omits the client-side slice")

	-- this world's first contact is the client accessor itself, so it is what mints the set
	local client_world = jecs.world()
	local client_net = duplecs.client(client_world)
	local client_components = duplecs.shared(client_world)

	expect_equal(duplecs.client(client_world), client_net, "duplecs.client returns the first call's instance")
	expect_equal(duplecs.shared(client_world), client_components, "duplecs.shared returns the world's minted set")
	expect_equal(table.isfrozen(client_components), true, "the shared set is frozen whichever accessor minted it")
	expect_equal(client_components.Imported, client_net.Imported, "Imported comes from the shared set")
	expect_equal(client_components.Serdes, client_net.Serdes, "Serdes comes from the shared set")
	expect_equal(client_net.Networked, nil, "the client instance omits the server-side slice")

	-- each world mints its own set, so nothing here is module-level state two worlds could share
	expect(client_components ~= components, "the second world minted a set of its own")
end)

test("a schema tagged through duplecs.shared before construction replicates like one tagged after", function()
	-- the whole schema goes in first -- definitions, tracking tags, serdes hooks, gameplay values, privacy,
	-- delegation, and a relation with a live pair -- and only then is the server half constructed.
	local world = jecs.world()
	local components = duplecs.shared(world)
	local defs = make_defs(world)

	-- Networked plus a shared name, with no set_client_entity for it on the client: the announcement the
	-- catch-up makes is what maps it there
	world:set(defs.Health, jecs.Name, "PreSchemaHealth")
	world:add(defs.Health, components.Networked)
	world:add(defs.Burning, components.Networked)
	world:add(defs.Cooldown, components.NetworkedOnce)
	world:add(jecs.ChildOf, components.Networked)

	-- the serdes store predates every possible registration (it is minted with the set), so an unreliable
	-- component can be configured in full here
	local Position = world:component()
	world:set(Position, components.Serdes, f64_serdes)
	world:add(Position, components.NetworkedUnreliable)

	local visible = world:entity()
	world:add(visible, components.Replicated)
	world:set(visible, defs.Health, 100)
	world:set(visible, defs.Cooldown, 5)
	world:set(visible, Position, 3)

	-- an empty unpaired Private is a whitelist naming nobody: it blocks everyone
	local hidden = world:entity()
	world:add(hidden, components.Replicated)
	world:set(hidden, defs.Health, 1)
	world:set(hidden, components.Private, {})

	-- the same empty filter scoped to one component: the entity replicates, that one component does not
	local gated = world:entity()
	world:add(gated, components.Replicated)
	world:set(gated, defs.Health, 2)
	world:add(gated, defs.Burning)
	world:set(gated, pair(components.Private, defs.Health), {})

	local group = world:entity()
	world:set(group, components.Private, {})
	local delegated = world:entity()
	world:add(delegated, components.Replicated)
	world:set(delegated, defs.Health, 3)
	world:add(delegated, pair(components.InheritsPrivacy, group))

	local parent = world:entity()
	local child = world:entity()
	world:add(parent, components.Replicated)
	world:add(child, components.Replicated)
	world:add(child, pair(jecs.ChildOf, parent))

	local net = duplecs.server(world)
	expect_equal(net.Networked, components.Networked, "the constructed half returned the world's minted set")

	local client_world = jecs.world()
	local client_net = duplecs.client(client_world)
	local client_defs = make_defs(client_world)
	client_world:set(client_defs.Health, jecs.Name, "PreSchemaHealth") -- mapped by the shared name alone
	client_net.set_client_entity(defs.Burning, client_defs.Burning)
	client_net.set_client_entity(defs.Cooldown, client_defs.Cooldown)
	client_net.set_client_entity(jecs.ChildOf, jecs.ChildOf)
	local client_position = client_world:component()
	client_world:set(client_position, client_net.Serdes, f64_serdes)
	client_net.set_client_entity(Position, client_position)

	local player = fake_player("PreSchemaViewer")
	net.add_client(player)
	client_net.reconcile_packet(deep_copy(net.generate_packets()[player]))

	local le_visible = client_net.get_client_entity(visible)
	expect(le_visible ~= nil, "the joiner's full packet created the replicated entity")
	expect_equal(client_world:get(le_visible, client_defs.Health), 100, "the Networked value arrived, mapped by name")
	expect_equal(client_world:get(le_visible, client_defs.Cooldown), 5, "the NetworkedOnce value arrived")
	expect_equal(
		client_world:get(le_visible, client_position),
		3,
		"NetworkedUnreliable's reliable membership carried the pre-construction value"
	)

	expect_equal(client_net.get_client_entity(hidden), nil, "the empty unpaired-Private entity is blocked for everyone")

	local le_gated = client_net.get_client_entity(gated)
	expect(le_gated ~= nil, "the per-component filter leaves the entity itself replicating")
	expect_equal(
		client_world:has(le_gated, client_defs.Health),
		false,
		"the pair(Private, Health)-gated cell stayed server-side"
	)
	expect_equal(client_world:has(le_gated, client_defs.Burning), true, "its ungated tag still arrived")

	expect_equal(client_net.get_client_entity(delegated), nil, "the delegating entity inherits the group's gate")

	local le_child = client_net.get_client_entity(child)
	local le_parent = client_net.get_client_entity(parent)
	expect(le_child ~= nil and le_parent ~= nil, "both ends of the pre-existing pair replicated")
	expect_equal(
		client_world:has(le_child, pair(jecs.ChildOf, le_parent)),
		true,
		"the pre-existing pair resolved against the client's own ids"
	)

	-- the catch-up's hooks drive later changes exactly as a post-construction tag's would, including the two
	-- modes that connect no changed hook at all: their edits below must stay off the reliable delta
	world:set(visible, defs.Health, 55)
	world:set(visible, defs.Cooldown, 42)
	world:set(visible, Position, 9)
	client_net.reconcile_packet(deep_copy(net.generate_packets()[player]))
	expect_equal(client_world:get(le_visible, client_defs.Health), 55, "a delta ships for a pre-construction tag")
	expect_equal(client_world:get(le_visible, client_defs.Cooldown), 5, "the NetworkedOnce edit stayed server-side")
	expect_equal(
		client_world:get(le_visible, client_position),
		3,
		"the NetworkedUnreliable edit did not ride the reliable delta"
	)

	local chunks = net.generate_unreliable_chunks()
	expect(chunks[player] ~= nil, "the pre-construction unreliable cell streams once its membership has shipped")
	for _, chunk in chunks[player] do
		client_net.reconcile_chunk(chunk)
	end
	expect_equal(client_world:get(le_visible, client_position), 9, "the unreliable chunk applied the new value")
end)

test("a multi-parent delegation DAG built before construction gates and fans out like a live one", function()
	-- the equivalence test above covers a single delegation edge; this builds the whole shape before
	-- duplecs.server exists -- a two-level chain (group_b -> root), a standalone group_a, a leaf inheriting one
	-- gate from each side, and a sibling hanging off each group alone -- so the replay has to seed both of the
	-- leaf's edges and the transitive level, not just whichever edge it happens to walk first.
	--
	-- the pre-construction filter has to be the empty one: a *valued* filter names clients, and no client can be
	-- tracked before construction, so every client it named would be pruned at sanitization (the pruning tests
	-- below cover that seam). the client-specific narrowing is therefore a post-construction edit -- which is
	-- also what makes the two edits below assertions about the seeded mirror rather than about the replay.
	local world = jecs.world()
	local components = duplecs.shared(world)
	local defs = make_defs(world)
	world:add(defs.Health, components.Networked)

	local root = world:entity()
	local group_b = world:entity()
	world:add(group_b, pair(components.InheritsPrivacy, root))
	-- an empty whitelist names nobody, so group_a blocks every client it gates
	local group_a = world:entity()
	world:set(group_a, components.Private, {})

	local leaf = world:entity()
	world:add(leaf, components.Replicated)
	world:set(leaf, defs.Health, 1)
	world:add(leaf, pair(components.InheritsPrivacy, group_a))
	world:add(leaf, pair(components.InheritsPrivacy, group_b))

	local sibling_a = world:entity()
	world:add(sibling_a, components.Replicated)
	world:set(sibling_a, defs.Health, 2)
	world:add(sibling_a, pair(components.InheritsPrivacy, group_a))

	local sibling_b = world:entity()
	world:add(sibling_b, components.Replicated)
	world:set(sibling_b, defs.Health, 3)
	world:add(sibling_b, pair(components.InheritsPrivacy, group_b))

	-- an unfiltered entity anchors every packet below as a real delivery, so a missing leaf reads as its gate's
	-- doing rather than as an empty packet
	local open = world:entity()
	world:add(open, components.Replicated)
	world:set(open, defs.Health, 4)

	local net = duplecs.server(world)

	local player = fake_player("PreDagViewer")
	net.add_client(player)
	local server = { world = world, net = net, defs = defs }
	local client = make_client(server)
	local function sync()
		local packets = net.generate_packets()
		if packets[player] ~= nil then
			client.net.reconcile_packet(deep_copy(packets[player]))
		end
	end

	sync() -- allocates the slot and drains the joiner's full packet

	local le_open = client.net.get_client_entity(open)
	expect(le_open ~= nil, "the unfiltered entity arrived, so the full packet was real")
	expect_equal(client.world:get(le_open, client.defs.Health), 4, "and carried its value")

	expect_equal(net.is_entity_visible(leaf, player), false, "group_a blocks everyone, so the leaf's gate does too")
	expect_equal(net.is_entity_visible(sibling_a, player), false, "and the sibling under group_a alone")
	expect_equal(net.is_entity_visible(sibling_b, player), true, "while nothing along group_b's chain restricts anyone")
	expect_equal(client.net.get_client_entity(leaf), nil, "the leaf never reached the client")
	expect_equal(client.net.get_client_entity(sibling_a), nil, "nor did group_a's other member")
	local le_sibling_b = client.net.get_client_entity(sibling_b)
	expect(le_sibling_b ~= nil, "group_b's member did")
	expect_equal(client.world:get(le_sibling_b, client.defs.Health), 3, "with its value")

	-- a widening edit on group_a: the replay seeded the fan-out both ways, so dropping the filter re-derives
	-- both members rather than only group_a itself
	world:remove(group_a, components.Private)
	expect_equal(net.is_entity_visible(leaf, player), true, "the leaf's remaining gates restrict nobody")
	expect_equal(net.is_entity_visible(sibling_a, player), true, "and group_a's other member is unrestricted too")
	sync()
	local le_leaf = client.net.get_client_entity(leaf)
	expect(le_leaf ~= nil, "the widened leaf reached the client")
	expect_equal(client.world:get(le_leaf, client.defs.Health), 1, "with its value")
	local le_sibling_a = client.net.get_client_entity(sibling_a)
	expect(le_sibling_a ~= nil, "and so did the sibling widened alongside it")
	expect_equal(client.world:get(le_sibling_a, client.defs.Health), 2, "with its own")

	-- and a narrowing edit two levels up: disallowing with no filter present starts a blacklist (see
	-- edit_privacy), and root reaches the leaf only through root -> group_b -> leaf -- the transitive level and
	-- the leaf's second edge, both of them seeded by the replay
	net.edit_entity_privacy(root, player, false)
	expect_equal(net.is_entity_visible(leaf, player), false, "root's blacklist reached the leaf through group_b")
	expect_equal(net.is_entity_visible(sibling_b, player), false, "and group_b's own member")
	expect_equal(net.is_entity_visible(sibling_a, player), true, "group_a's member hangs off neither, so it stays")
	sync()
	expect_equal(client.net.get_client_entity(leaf), nil, "the leaf was torn down on the client")
	expect_equal(client.net.get_client_entity(sibling_b), nil, "along with group_b's member")
	expect(client.net.get_client_entity(sibling_a) ~= nil, "while group_a's member is untouched")
end)

test("guard: a tracking tag paired before construction errors from the construction call", function()
	local world = jecs.world()
	local components = duplecs.shared(world)
	local target = world:entity()
	local entity = world:entity()
	world:add(entity, pair(components.Networked, target))

	expect_error(function()
		duplecs.server(world)
	end, "constructing over a pre-existing Networked pair", "Networked is not meant to be paired")
	expect_equal(
		world:has(entity, pair(components.Networked, target)),
		false,
		"the pair was removed by the guard before erroring"
	)
end)

test("guard: Replicated paired before construction errors from the construction call", function()
	local world = jecs.world()
	local components = duplecs.shared(world)
	local target = world:entity()
	local entity = world:entity()
	world:add(entity, pair(components.Replicated, target))

	expect_error(function()
		duplecs.server(world)
	end, "constructing over a pre-existing Replicated pair", "Replicated is not meant to be paired")
	expect_equal(
		world:has(entity, pair(components.Replicated, target)),
		false,
		"the pair was removed by the guard before erroring"
	)
end)

test("guard: Networked on a Replicated entity before construction errors from the construction call", function()
	local world = jecs.world()
	local components = duplecs.shared(world)
	local entity = world:entity()
	world:add(entity, components.Replicated)
	world:add(entity, components.Networked)

	expect_error(function()
		duplecs.server(world)
	end, "constructing over a Networked Replicated entity", "cannot add Networked to replicated entities")
	expect_equal(world:has(entity, components.Networked), false, "Networked removed by the guard before erroring")
	expect_equal(world:has(entity, components.Replicated), true, "the Replicated tag the mirror already accepted stays")
end)

test("guard: two tracking tags on one definition before construction error from the construction call", function()
	local world = jecs.world()
	local components = duplecs.shared(world)
	local Health = world:component()
	world:add(Health, components.Networked)
	world:add(Health, components.NetworkedOnce)

	expect_error(function()
		duplecs.server(world)
	end, "constructing over a doubly-tagged definition", "are exclusive")
	-- the catch-up walks Networked first, so that is the tag whose replayed add the guard undoes
	expect_equal(world:has(Health, components.Networked), false, "the replayed tag was removed by the guard")
	expect_equal(world:has(Health, components.NetworkedOnce), true, "the tag it collided with is left in place")
end)

test("guard: NetworkedUnreliable on a tag before construction errors from the construction call", function()
	local world = jecs.world()
	local components = duplecs.shared(world)
	local Tag = world:entity()
	world:add(Tag, components.NetworkedUnreliable)

	expect_error(function()
		duplecs.server(world)
	end, "constructing over an unreliable tag definition", "cannot be added to tags")
	expect_equal(
		world:has(Tag, components.NetworkedUnreliable),
		false,
		"NetworkedUnreliable removed by the guard before erroring"
	)
end)

test("guard: an unpaired InheritsPrivacy added before construction errors from the construction call", function()
	local world = jecs.world()
	local components = duplecs.shared(world)
	local entity = world:entity()
	world:add(entity, components.InheritsPrivacy)

	expect_error(function()
		duplecs.server(world)
	end, "constructing over an unpaired InheritsPrivacy", "must be paired with a group entity")
	expect_equal(
		world:has(entity, components.InheritsPrivacy),
		false,
		"the tag was removed by the guard before erroring"
	)
end)

test("guard: an InheritsPrivacy cycle added before construction errors from the construction call", function()
	-- no hooks exist yet, so the raw adds below cannot be rejected as they are made -- unlike a live cycle,
	-- which the add closing it errors on. the catch-up replays the edges in turn, and the second one closes
	-- the cycle over the first.
	local world = jecs.world()
	local components = duplecs.shared(world)
	local a = world:entity()
	local b = world:entity()
	world:add(a, pair(components.InheritsPrivacy, b))
	world:add(b, pair(components.InheritsPrivacy, a))

	expect_error(function()
		duplecs.server(world)
	end, "constructing over an InheritsPrivacy cycle", "cannot contain cycles")
	-- whichever edge the walk replayed second is the one the guard removed, so exactly one of the two
	-- survives: the first edge is a legal delegation and must be left standing
	local a_to_b = world:has(a, pair(components.InheritsPrivacy, b))
	local b_to_a = world:has(b, pair(components.InheritsPrivacy, a))
	expect(a_to_b ~= b_to_a, "the edge that closed the cycle was removed by the guard, and only that edge")
end)

test(
	"guard: an InheritsPrivacy cycle reachable only through a multi-parent path errors from the construction call",
	function()
		-- the same guard over a loop that closes through a fan-in rather than head-on: root -> e is a legal edge
		-- against either of e's parents alone, and it is the pair of them that puts root back under itself, so the
		-- reachability walk only finds it by following every parent edge (and remembering where it has been).
		local world = jecs.world()
		local components = duplecs.shared(world)
		local root = world:entity()
		local g1 = world:entity()
		local g2 = world:entity()
		local e = world:entity()
		world:add(g1, pair(components.InheritsPrivacy, root))
		world:add(g2, pair(components.InheritsPrivacy, root))
		world:add(e, pair(components.InheritsPrivacy, g1))
		world:add(e, pair(components.InheritsPrivacy, g2))
		world:add(root, pair(components.InheritsPrivacy, e)) -- closes the loop only through the g1/g2 fan-in

		expect_error(function()
			duplecs.server(world)
		end, "constructing over an InheritsPrivacy cycle through a multi-parent path", "cannot contain cycles")
		-- the catch-up replays the edges in archetype order, so which of the five arrives last -- and is therefore
		-- the one the guard removes -- is not determined; what is determined is that exactly one goes, leaving four
		-- edges standing (the ones the abort never reached among them)
		local edges = { { g1, root }, { g2, root }, { e, g1 }, { e, g2 }, { root, e } }
		local surviving = 0
		for _, edge in edges do
			if world:has(edge[1], pair(components.InheritsPrivacy, edge[2])) then
				surviving += 1
			end
		end
		expect_equal(surviving, 4, "exactly the edge that closed the cycle was removed, whichever one that was")
	end
)

test("guard: a mixed-polarity Private value set before construction errors from the construction call", function()
	local world = jecs.world()
	local components = duplecs.shared(world)
	local entity = world:entity()
	world:add(entity, components.Replicated)
	world:set(entity, components.Private, { [fake_player("PreMixedA")] = true, [fake_player("PreMixedB")] = false })

	expect_error(function()
		duplecs.server(world)
	end, "constructing over a mixed-polarity Private value", "cannot mix")
	-- a fresh add has no previous filter to revert to, so the revert removes the value outright
	expect_equal(world:has(entity, components.Private), false, "the value was reverted by the guard before erroring")
end)

test("guard: Imported added before construction errors from the client construction call", function()
	local world = jecs.world()
	local components = duplecs.shared(world)
	local entity = world:entity()
	world:add(entity, components.Imported)

	expect_error(function()
		duplecs.client(world)
	end, "constructing over a pre-existing Imported tag", "cannot be added to entities with no server mapping")
	expect_equal(world:has(entity, components.Imported), false, "Imported removed by the guard before erroring")
end)

test("guard: a paired Imported added before construction errors from the client construction call", function()
	local world = jecs.world()
	local components = duplecs.shared(world)
	local target = world:entity()
	local entity = world:entity()
	world:add(entity, pair(components.Imported, target))

	expect_error(function()
		duplecs.client(world)
	end, "constructing over a pre-existing Imported pair", "Imported is not meant to be paired")
	expect_equal(
		world:has(entity, pair(components.Imported, target)),
		false,
		"the pair was removed by the guard before erroring"
	)
end)

test("a valued whitelist set before construction is pruned to a filter blocking everyone", function()
	-- no client can be tracked before construction, so the client this whitelist names is pruned at
	-- sanitization -- leaving an empty whitelist, value and cache alike, which blocks everyone -- and joining
	-- later cannot restore a standing the filter never held.
	local world = jecs.world()
	local components = duplecs.shared(world)
	local defs = make_defs(world)
	world:add(defs.Health, components.Networked)

	local player_a = fake_player("PrunedWhitelistViewer")
	local entity = world:entity()
	world:add(entity, components.Replicated)
	world:set(entity, defs.Health, 7)
	world:set(entity, components.Private, { [player_a] = true })

	-- an unfiltered neighbour: it anchors the joiner's full packet as real, so the filtered entity's absence
	-- below is the pruned whitelist's doing rather than an empty packet's
	local open = world:entity()
	world:add(open, components.Replicated)
	world:set(open, defs.Health, 9)

	-- the catch-up replays the filter through the ordinary set handler, so the prune it forces warns from the
	-- construction call itself
	expected_warning("untracked client(s)! they were pruned from it")
	local net = duplecs.server(world)
	expect_equal(world:has(entity, components.Private), true, "the value itself stays on the entity")
	local pruned = world:get(entity, components.Private)
	expect_equal(pruned[player_a], nil, "the catch-up pruned the component's own value, not just the cache")
	expect_equal(next(pruned), nil, "the whitelist pruned of its only client is an empty table")
	expect_equal(table.isfrozen(pruned), true, "the pruned value is frozen like any cached filter")

	net.add_client(player_a)
	local packets = net.generate_packets()
	local server = { world = world, net = net, defs = defs }
	local client = make_client(server)
	client.net.reconcile_packet(deep_copy(packets[player_a]))

	local le_open = client.net.get_client_entity(open)
	expect(le_open ~= nil, "the unfiltered neighbour arrived, so the full packet was real")
	expect_equal(client.world:get(le_open, client.defs.Health), 9, "and carried its value")
	expect_equal(net.is_entity_visible(open, player_a), true, "the joiner's slot was allocated")

	expect_equal(net.is_entity_visible(entity, player_a), false, "the server gates the named-but-pruned client out")
	expect_equal(client.net.get_client_entity(entity), nil, "the joiner's full packet excludes the entity")
end)

test("a valued blacklist naming only untracked clients is removed at construction", function()
	-- the mirror image: a blacklist pruned to empty restricts nobody, and an empty table has to keep meaning a
	-- block-everyone whitelist, so the value is removed outright -- exactly what an emptying edit does.
	local world = jecs.world()
	local components = duplecs.shared(world)
	local defs = make_defs(world)
	world:add(defs.Health, components.Networked)

	local player_a = fake_player("PrunedBlacklistViewer")
	local entity = world:entity()
	world:add(entity, components.Replicated)
	world:set(entity, defs.Health, 8)
	world:set(entity, components.Private, { [player_a] = false })

	expected_warning("blacklist named only untracked clients! it was removed outright")
	local net = duplecs.server(world)
	expect_equal(world:has(entity, components.Private), false, "the emptied blacklist was removed from the entity")
	expect_equal(world:get(entity, components.Private), nil, "and it holds no value either")

	net.add_client(player_a)
	local packets = net.generate_packets()
	expect_equal(net.is_entity_visible(entity, player_a), true, "the server gates nobody out of the entity")
	local server = { world = world, net = net, defs = defs }
	local client = make_client(server)
	client.net.reconcile_packet(deep_copy(packets[player_a]))

	local le = client.net.get_client_entity(entity)
	expect(le ~= nil, "nothing restricts the client, so the entity replicates to them")
	expect_equal(client.world:get(le, client.defs.Health), 8, "its value arrived with it")

	-- the removal took the cached filter with it, not just the value on the entity: admitting a client where no
	-- filter is configured warns and does nothing, where an empty blacklist left behind in the cache would
	-- instead un-name a client it never named, silently.
	expected_warning("cannot allow a client without a whitelist")
	net.edit_entity_privacy(entity, player_a, true)
	expect_equal(world:has(entity, components.Private), false, "the refused admission left no filter behind")
	expect_equal(net.is_entity_visible(entity, player_a), true, "and changed nothing about what the client sees")
end)

test("both pre-construction filter forms are pruned, each warning once, in the catch-up's order", function()
	-- the paired form replays through the same handler as the unpaired one, so it is pruned and warned about the
	-- same way -- once per filter, never once per client. the two filters name different numbers of clients so
	-- the counts in their messages tell them apart: the catch-up replays the unpaired holders before the paired
	-- ones, and the declared order pins that.
	local world = jecs.world()
	local components = duplecs.shared(world)
	local defs = make_defs(world)
	world:add(defs.Health, components.Networked)

	local viewer = fake_player("PrePairedViewer")
	local extra = fake_player("PrePairedExtra")

	local unpaired = world:entity()
	world:add(unpaired, components.Replicated)
	world:set(unpaired, defs.Health, 11)
	world:set(unpaired, components.Private, { [viewer] = true })

	local gated = world:entity()
	world:add(gated, components.Replicated)
	world:set(gated, defs.Health, 12)
	world:set(gated, pair(components.Private, defs.Health), { [viewer] = true, [extra] = true })

	expected_warning("named 1 untracked client(s)")
	expected_warning("named 2 untracked client(s)")
	local net = duplecs.server(world)

	local unpaired_filter = world:get(unpaired, components.Private)
	expect(unpaired_filter ~= nil and next(unpaired_filter) == nil, "the entity-level filter was pruned empty")
	local paired_filter = world:get(gated, pair(components.Private, defs.Health))
	expect(paired_filter ~= nil and next(paired_filter) == nil, "and the paired one with it")

	net.add_client(viewer)
	local packets = net.generate_packets()
	local server = { world = world, net = net, defs = defs }
	local client = make_client(server)
	client.net.reconcile_packet(deep_copy(packets[viewer]))

	expect_equal(net.is_entity_visible(unpaired, viewer), false, "the pruned entity-level filter blocks the entity")
	expect_equal(client.net.get_client_entity(unpaired), nil, "so the joiner's full packet never creates it")
	local le_gated = client.net.get_client_entity(gated)
	expect(le_gated ~= nil, "the paired filter gates only its component, so its entity still replicates")
	expect_equal(client.world:has(le_gated, client.defs.Health), false, "with the pruned filter blocking the value")
end)

test("valueless Private filters set before construction survive it as empty filters", function()
	-- the nil normalization warns rather than erroring, so the catch-up rewrites both levels and construction
	-- runs to completion -- leaving both cells blocked to everyone, exactly as a live valueless add would have.
	local world = jecs.world()
	local components = duplecs.shared(world)
	local defs = make_defs(world)
	world:add(defs.Health, components.Networked)

	local unpaired = world:entity()
	world:add(unpaired, components.Replicated)
	world:set(unpaired, defs.Health, 4)
	world:add(unpaired, components.Private)

	local gated = world:entity()
	world:add(gated, components.Replicated)
	world:set(gated, defs.Health, 6)
	world:add(gated, pair(components.Private, defs.Health))

	-- the catch-up replays the unpaired holders before the paired ones, so the two warnings fire in that order
	expected_warning("cannot have a nil value")
	expected_warning("cannot have a nil value")
	local net = duplecs.server(world)
	expect_equal(world:has(unpaired, components.Private), true, "the unpaired filter survived the catch-up")
	local unpaired_filter = world:get(unpaired, components.Private)
	expect(unpaired_filter ~= nil and next(unpaired_filter) == nil, "carrying an empty filter in place of the nil")
	expect_equal(world:has(gated, pair(components.Private, defs.Health)), true, "and so did the per-component one")
	-- the normalized value is one frozen empty table shared across the instance, so both cells hold the very
	-- same filter by reference -- deliberate, since cached filters are only read, cloned, or replaced wholesale
	expect_equal(
		world:get(gated, pair(components.Private, defs.Health)),
		unpaired_filter,
		"the same shared empty filter"
	)

	local player_a = fake_player("PreValuelessViewer")
	net.add_client(player_a)
	local packets = net.generate_packets()
	local server = { world = world, net = net, defs = defs }
	local client = make_client(server)
	client.net.reconcile_packet(deep_copy(packets[player_a]))

	expect_equal(
		net.is_entity_visible(unpaired, player_a),
		false,
		"the normalized unpaired filter blocks the entity outright"
	)
	expect_equal(client.net.get_client_entity(unpaired), nil, "so the joiner's full packet never creates it")
	local le_gated = client.net.get_client_entity(gated)
	expect(le_gated ~= nil, "the other entity replicates, its own gate being per-component")
	expect_equal(client.world:has(le_gated, client.defs.Health), false, "but the normalized pair blocks its component")
end)

test("unpaired Private edits stay live when both Private forms are set before construction", function()
	-- pins the jecs 0.11.0 unpaired-hook bug: a listener registered while both an unpaired and a pair record
	-- for the component already exist never fires for the unpaired id (the pairs keep firing). Private is
	-- documented in both forms, so a schema module setting one of each -- as the two seeds below do -- puts
	-- duplecs.server's own hook registration in exactly that position, and the construction catch-up masks it
	-- by replaying the pre-existing filters through the handlers directly. deleting either seed as pointless
	-- is exactly what this test guards against: without them the bug is unreachable here and every assertion
	-- below passes regardless.
	local world = jecs.world()
	local components = duplecs.shared(world)
	local defs = make_defs(world)
	world:add(defs.Health, components.Networked)

	-- the entity-level form creates Private's unpaired record
	local seeded_entity = world:entity()
	world:add(seeded_entity, components.Replicated)
	world:set(seeded_entity, defs.Health, 1)
	world:set(seeded_entity, components.Private, {})

	-- and the per-component form its pair record
	local seeded_component = world:entity()
	world:add(seeded_component, components.Replicated)
	world:set(seeded_component, defs.Health, 2)
	world:set(seeded_component, pair(components.Private, defs.Health), {})

	local net = duplecs.server(world)

	local player_a = fake_player("UnpairedPrivateViewer")
	local player_b = fake_player("UnpairedPrivateOutsider")
	net.add_client(player_a)
	net.add_client(player_b)

	local server = { world = world, net = net, defs = defs }
	local client_a = make_client(server)
	local client_b = make_client(server)

	local function sync()
		local packets = net.generate_packets()
		if packets[player_a] ~= nil then
			client_a.net.reconcile_packet(deep_copy(packets[player_a]))
		end
		if packets[player_b] ~= nil then
			client_b.net.reconcile_packet(deep_copy(packets[player_b]))
		end
	end

	sync() -- allocates both slots and drains their full packets

	local goblin = world:entity()
	world:add(goblin, components.Replicated)
	world:set(goblin, defs.Health, 100)
	expect_equal(net.is_entity_visible(goblin, player_a), true, "precondition: nothing gates the entity yet")
	expect_equal(net.is_entity_visible(goblin, player_b), true, "for either viewer")
	sync()
	expect(client_a.net.get_client_entity(goblin) ~= nil, "the ungated entity reached the first viewer")
	expect(client_b.net.get_client_entity(goblin) ~= nil, "and the second")

	-- the unpaired added hook: an empty whitelist names nobody, so it blocks everyone
	world:set(goblin, components.Private, {})
	expect_equal(net.is_entity_visible(goblin, player_a), false, "the added hook applied the empty whitelist")
	expect_equal(net.is_entity_visible(goblin, player_b), false, "to both viewers")
	sync()
	expect_equal(client_a.net.get_client_entity(goblin), nil, "so the entity was torn down on the first client")
	expect_equal(client_b.net.get_client_entity(goblin), nil, "and on the second")

	-- the unpaired changed hook: replacing the value wholesale readmits exactly the client it names
	world:set(goblin, components.Private, { [player_a] = true })
	expect_equal(net.is_entity_visible(goblin, player_a), true, "the changed hook readmitted the named client")
	expect_equal(net.is_entity_visible(goblin, player_b), false, "and left the unnamed one blocked")
	sync()
	local le_a = client_a.net.get_client_entity(goblin)
	expect(le_a ~= nil, "the readmitted client received the entity again")
	expect_equal(client_a.world:get(le_a, client_a.defs.Health), 100, "with its value")
	expect_equal(client_b.net.get_client_entity(goblin), nil, "while the blocked client still has nothing")

	-- the unpaired removed hook: dropping the filter lifts the gate for everyone
	world:remove(goblin, components.Private)
	expect_equal(net.is_entity_visible(goblin, player_a), true, "the removed hook lifted the filter")
	expect_equal(net.is_entity_visible(goblin, player_b), true, "for the previously blocked viewer too")
	sync()
	local le_b = client_b.net.get_client_entity(goblin)
	expect(le_b ~= nil, "the previously blocked client received the entity")
	expect_equal(client_b.world:get(le_b, client_b.defs.Health), 100, "with its value")
end)

-- 32) documentation guards

-- two of the docs sitting above the sources are pinned to them mechanically rather than by convention, because
-- both drifted in practice: a diagnostic shipped with no matching spec change, another kept its old wording in
-- one appendix section after being reworded elsewhere, and is_entity_replicated was simply missing from
-- docs/api.md. so the suite reads them: docs/api.md must carry a `####` heading for every key the server and
-- client instances return (underscore-prefixed debug exports excepted, being deliberately undocumented), and
-- docs/spec.md's warnings-and-errors appendix must quote every message the module's warn( and fail( calls
-- raise. each doc is checked in both directions -- forwards, so nothing the sources have goes undocumented,
-- and backwards, so a rename or a removal cannot leave stale text behind -- which is what makes the backwards
-- direction catch what a reviewer adding an entry never looks at.
--
-- messages are compared run by run: each one is split on its interpolated parts (`{...}` in the sources,
-- `<...>` in the appendix) and every run shorter than 8 characters after trimming is skipped, since short glue
-- like `(`, `)`, ` -> `, or `encoded` sits in every second message and would match or miss for reasons that
-- have nothing to do with the message it came from. a message the floor leaves nothing of is reported rather
-- than passed over, since it would otherwise be compared against nothing at all. and the counts the tests
-- floor are today's counts exactly, so a single message an extractor stops reading -- one rewritten into a
-- composed string, one entry filed under a fourth label, one heading demoted a level -- fails outright
-- instead of quietly dropping out of the comparison; raise a floor when the surface it counts really grows.

-- every `####` heading's leading identifier, signature and type parameters stripped
local function collect_api_headings()
	local headings = {}
	for line in string.gmatch(fs.readFile("docs/api.md"), "[^\n]+") do
		if string.sub(line, 1, 5) ~= "#### " then
			continue
		end
		local span = string.match(line, "`([^`]+)`")
		expect(span ~= nil, `an api.md heading names nothing in backticks: {line}`)
		local name = string.match(span, "^[^(<]+")
		headings[string.match(name, "^%s*(.-)%s*$")] = true
	end
	return headings
end

-- the appendix's own span of docs/spec.md: its heading through the next `##` heading, or the end of the file
local function read_diagnostics_appendix()
	local spec = fs.readFile("docs/spec.md")
	local heading = "## Appendix: Warnings and Errors"
	local start = string.find(spec, heading, 1, true)
	expect(start ~= nil, "docs/spec.md has no warnings-and-errors appendix")
	local stop = string.find(spec, "\n## ", start + #heading, true)
	if stop == nil then
		return string.sub(spec, start)
	end
	return string.sub(spec, start, stop - 1)
end

-- one documented message's literal runs: its text split on the `<...>` placeholders standing in for the
-- interpolated parts
local function split_placeholders(text)
	local runs = {}
	local index = 1
	while true do
		local open = string.find(text, "<", index, true)
		if open == nil then
			table.insert(runs, string.sub(text, index))
			return runs
		end
		table.insert(runs, string.sub(text, index, open - 1))
		local close = string.find(text, ">", open + 1, true)
		expect(close ~= nil, `an appendix message has an unterminated placeholder: {text}`)
		index = close + 1
	end
end

-- every diagnostic entry of the appendix, as its documented message's literal runs plus that message whole
-- (for failure messages). an entry's message is the first code span on its line. a bullet opening with a bold
-- label has to carry one of the three labels the appendix files entries under: one filed under a fourth would
-- otherwise be skipped in silence, taking its message out of both directions of the comparison.
local function collect_appendix_messages(appendix)
	local messages = {}
	for line in string.gmatch(appendix, "[^\n]+") do
		local label = string.match(line, "^%-%s+%*%*(%a+)%*%*")
		if label == nil then
			continue
		end
		expect(
			label == "errors" or label == "warns" or label == "reports",
			`an appendix entry is labelled **{label}**, which is none of errors, warns, and reports: {line}`
		)
		local text = string.match(line, "`([^`]+)`")
		expect(text ~= nil, `an appendix entry quotes no message: {line}`)
		table.insert(messages, { runs = split_placeholders(text), text = text })
	end
	return messages
end

-- reads one backtick-delimited interpolated string starting at data[start] (source[start] == "`"),
-- returning the literal runs between its interpolations and the offset just past the closing backtick
local function read_interpolated(source, start)
	local runs = {}
	local current = {}
	local index = start + 1
	while index <= #source do
		local char = string.sub(source, index, index)
		if char == "\\" then
			table.insert(current, string.sub(source, index, index + 1))
			index += 2
			continue
		end
		if char == "`" then
			table.insert(runs, table.concat(current))
			return runs, index + 1
		end
		if char == "{" then
			table.insert(runs, table.concat(current))
			current = {}
			local depth = 1
			index += 1
			while index <= #source and depth > 0 do
				local inner = string.sub(source, index, index)
				if inner == "{" then
					depth += 1
				elseif inner == "}" then
					depth -= 1
				end
				index += 1
			end
			continue
		end
		table.insert(current, char)
		index += 1
	end
	fail("unterminated interpolated string in a src/ diagnostic")
end

-- every `fail(` / `warn(` call in src/ whose argument is an interpolated string literal, as its literal
-- runs plus the file it came from. a call opening with a plain quoted string is refused outright rather than
-- skipped: every diagnostic in the tree is written with backticks, and reading only those is what makes this
-- extraction tractable, so a plain-string message would otherwise slip past the appendix check unnoticed. a
-- call whose argument is neither (a composed message, or diagnostics.luau's own `fail` definition) is passed
-- over -- nothing can be read out of it statically, so such a message has to be documented by hand.
local function collect_source_messages()
	local messages = {}
	for _, entry in fs.readDir("src") do
		if string.sub(entry, -5) ~= ".luau" then
			continue
		end
		local source = fs.readFile(`src/{entry}`)
		for _, name in { "fail", "warn" } do
			local search = 1
			while true do
				local start, stop = string.find(source, `{name}(`, search, true)
				if start == nil then
					break
				end
				search = stop + 1
				-- a word character before the name means a different identifier ending in it
				if string.match(string.sub(source, start - 1, start - 1), "[%w_]") then
					continue
				end
				local index = stop + 1
				while string.match(string.sub(source, index, index), "%s") do
					index += 1
				end
				local opener = string.sub(source, index, index)
				if opener == '"' or opener == "'" then
					fail(`src/{entry}: a {name}( message is a plain quoted string; diagnostics must use backticks`)
				end
				if opener ~= "`" then
					continue
				end
				table.insert(messages, { runs = read_interpolated(source, index), file = entry })
			end
		end
	end
	return messages
end

-- the whole `src/` text, for the direction that asks whether a documented message still exists anywhere. a few
-- contract-failure messages are built as plain strings inside wire.luau's salvage passes and reach callers as
-- the tail of a containment warning, so they are documented without being raise sites of their own.
local function read_source_text()
	local sources = {}
	for _, entry in fs.readDir("src") do
		if string.sub(entry, -5) ~= ".luau" then
			continue
		end
		table.insert(sources, fs.readFile(`src/{entry}`))
	end
	return table.concat(sources, "\n")
end

-- a run is only worth comparing if trimming leaves 8 characters of it, per the floor described above
local function significant_run(run)
	local text = string.match(run, "^%s*(.-)%s*$")
	if #text < 8 then
		return nil
	end
	return text
end

test("docs/api.md has a heading for every server and client export", function(env)
	local headings = collect_api_headings()

	-- Serdes is the one export documented under a bare heading: both sides export it and api.md documents it
	-- once, under a heading naming neither side. every other key is looked up side-qualified, so an export
	-- sharing its name with a type heading (Packet, Privacy, Components) cannot ride that heading undocumented.
	local function expect_heading(side, key)
		if key == "Serdes" then
			expect(
				headings.Serdes ~= nil or headings[`{side}.Serdes`] ~= nil,
				`docs/api.md has no heading for {side}.Serdes, shared or side-qualified`
			)
			return
		end
		expect(headings[`{side}.{key}`] ~= nil, `docs/api.md has no heading for {side}.{key}`)
	end

	local server_keys = 0
	for key in env.server.net do
		-- underscore-prefixed debug exports are deliberately undocumented
		if string.sub(key, 1, 1) == "_" then
			continue
		end
		server_keys += 1
		expect_heading("server", key)
	end

	local client_keys = 0
	for key in env.client.net do
		if string.sub(key, 1, 1) == "_" then
			continue
		end
		client_keys += 1
		expect_heading("client", key)
	end

	-- the floors are today's public surfaces exactly, so an export that disappears from an instance fails here
	-- too rather than quietly shrinking what this test covers; raise them when the surface really grows
	expect(server_keys >= 23, `only {server_keys} server exports were checked against docs/api.md`)
	expect(client_keys >= 14, `only {client_keys} client exports were checked against docs/api.md`)
end)

test("docs/api.md documents no module-root, server, or client export that no longer exists", function(env)
	local instances = { duplecs = duplecs, server = env.server.net, client = env.client.net }

	local checked = 0
	for heading in collect_api_headings() do
		local side, key = string.match(heading, "^(%a+)%.(.+)$")
		if side == nil then
			continue
		end
		-- every side a heading names today is covered, so this skip guards a future one rather than filtering
		-- the current set: the type headings carry no side at all and already fell out at the match above
		local instance = instances[side]
		if instance == nil then
			continue
		end
		checked += 1
		expect(instance[key] ~= nil, `docs/api.md documents {heading}, which the {side} instance no longer exports`)
	end

	-- today's count of side-qualified headings exactly: a heading that stops reading as one -- demoted a level,
	-- reformatted out of its backticks -- fails here instead of leaving this direction with less to check
	expect(checked >= 38, `only {checked} side-qualified api.md headings were checked against the instances`)
end)

test("the spec's warnings-and-errors appendix quotes every message the sources raise", function()
	local messages = collect_source_messages()
	expect(#messages >= 44, `only {#messages} src/ diagnostics were collected: the extractor no longer reads them`)

	-- the entries' quoted messages, not the appendix whole: a message that survives only in an entry's prose
	-- has no entry of its own, which is exactly the drift this direction exists to catch
	local quoted = {}
	for _, entry in collect_appendix_messages(read_diagnostics_appendix()) do
		table.insert(quoted, entry.text)
	end
	local documented = table.concat(quoted, "\n")

	for _, message in messages do
		local checked = 0
		for _, run in message.runs do
			local text = significant_run(run)
			if text == nil then
				continue
			end
			checked += 1
			expect(
				string.find(documented, text, 1, true) ~= nil,
				`src/{message.file}: the spec's warnings-and-errors appendix does not quote "{text}"`
			)
		end
		expect(
			checked > 0,
			`src/{message.file}: no run of "{table.concat(message.runs, "<...>")}" is long enough to compare`
		)
	end
end)

test("the spec's warnings-and-errors appendix quotes no message the sources no longer raise", function()
	local source_text = read_source_text()
	local messages = collect_appendix_messages(read_diagnostics_appendix())
	expect(#messages >= 41, `only {#messages} appendix entries were collected: the extractor no longer reads them`)

	for _, message in messages do
		local checked = 0
		for _, run in message.runs do
			local text = significant_run(run)
			if text == nil then
				continue
			end
			checked += 1
			expect(
				string.find(source_text, text, 1, true) ~= nil,
				`the appendix quotes "{text}", which src/ no longer raises (in "{message.text}")`
			)
		end
		expect(checked > 0, `the appendix entry "{message.text}" has no run long enough to compare against src/`)
	end
end)

-- runner

local passed = 0
local failed = {}

print(`[duplecsTest] running {#tests} tests...`)

for _, case in tests do
	table.clear(captured_warnings)
	table.clear(expected_warnings)
	capturing_warnings = true
	local ok, err = xpcall(function()
		case.fn(make_env())
		-- part of the case: a body that returns without its declared warnings having fired still fails
		check_warnings()
	end, function(message)
		return tostring(message)
	end)
	capturing_warnings = false
	if ok then
		passed += 1
		print(`[PASS] {case.name}`)
	else
		table.insert(failed, case.name)
		warn(`[FAIL] {case.name} — {err}`)
	end
end

if #failed == 0 then
	print(`✅ All {passed} duplecs tests passed`)
else
	warn(`❌ {#failed} of {#tests} duplecs test(s) failed:`)
	for _, name in failed do
		warn(`  - {name}`)
	end
	-- warn never fails the process, so CI needs the exit code set explicitly
	process.exit(1)
end
