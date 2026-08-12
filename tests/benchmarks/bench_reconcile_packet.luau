--!native
--!optimize 2

-- duplecs reconcile_packet benchmark — the real module on both ends: a server
-- world generates each frame's packets and a client world reconciles them, with
-- only reconcile_packet() timed. each scenario isolates one packet shape:
--   values         unpaired-component value changes (ids + side-array values)
--   adds_removes   component add/remove churn (ids + removed lists)
--   churn          entity creation/deletion (replicated/unreplicated lists,
--                  plus a data component and a tag on every churned entity)
--   pair_values    pair value changes across many distinct targets of one
--                  relation (the relation-grouped section shape)
--   pair_retarget  pair add/remove churn as subjects cycle across targets
--   full           a joiner's full-packet snapshot into a fresh client world
--
-- packet sizes print alongside times: this benchmark exists to compare
-- encoding-changing commits, and sizes are deterministic where times are noisy.
-- no serdes hooks are assigned, so every value travels the hookless side array.

local jecs = require("../../roblox_packages/jecs")
local pair = jecs.pair

local duplecs = require("../../src")

-- constructor adapter so the same file runs at older commits (patch the
-- require above to "../../duplecs" there): at HEAD the module returns
-- { client, server, shared } -- per-world memoized accessors -- earlier
-- commits returned { create_client, create_server }, and at v0.3.0 the
-- require returns a single constructor whose instance carries both halves.
local create_server = if type(duplecs) == "function" then duplecs else duplecs.server or duplecs.create_server
local create_client = if type(duplecs) == "function" then duplecs else duplecs.client or duplecs.create_client

local REPS = 300
local FULL_REPS = 100

-- id alignment: different duplecs versions create different numbers of
-- internal ids, shifting every id created afterwards and with it the hash
-- iteration order of the tracked set -- which reorders packet sections and
-- with them the client's archetype creation order, swinging reconcile times
-- by up to ~18% between otherwise identical workloads. padding both id
-- ranges to fixed floors makes every version allocate identical ids.
local COMPONENT_ID_FLOOR = 16
local ENTITY_ID_FLOOR = 320

local function align_ids(world)
	while (world:component() :: any) < COMPONENT_ID_FLOOR do
	end
	while (world:entity() :: any) < ENTITY_ID_FLOOR do
	end
end

local NUM_COMPONENTS = 4
local ENTITIES_PER_COMPONENT = 256
local TOGGLE_ENTITIES = 1024
local CHURN_LIVE = 1024
local CHURN_PER_FRAME = 128
local PAIR_TARGETS = 512
local RETARGET_SUBJECTS = 256
local FULL_BASE = 1024
local FULL_PAIRS = 256

-- ---- harness ----------------------------------------------------------------

-- one server/client pairing: the server world generates, the client world
-- reconciles. the viewer stand-in is only ever a table key.
local function create_link()
	local server_world = jecs.World.new()
	local server = create_server(server_world)
	align_ids(server_world)

	local client_world = jecs.World.new()
	local client = create_client(client_world)
	align_ids(client_world)

	local viewer = {}
	server.add_client(viewer)

	return {
		server_world = server_world,
		server = server,
		client_world = client_world,
		client = client,
		viewer = viewer,
	}
end

-- a networked data component on the server world, pre-mapped to a fresh
-- client-side component so its sections resolve locally
local function map_component(link)
	local server_component = link.server_world:component()
	link.server_world:add(server_component, link.server.Networked)
	local client_component = link.client_world:component()
	link.client.set_client_entity(server_component, client_component)
	return server_component, client_component
end

-- same for a valueless tag
local function map_tag(link)
	local server_tag = link.server_world:entity()
	link.server_world:add(server_tag, link.server.Networked)
	local client_tag = link.client_world:entity()
	link.client.set_client_entity(server_tag, client_tag)
	return server_tag, client_tag
end

-- the first generate_packets allocates the viewer's slot and builds its full
-- packet; reconciling it seeds the client's entity map (untimed)
local function sync_initial(link)
	local packets = link.server.generate_packets()
	link.client.reconcile_packet(packets[link.viewer])
end

-- drives reps frames: dirty(rep) mutates the server world untimed, the
-- viewer's packet reconciles timed. returns total seconds and summed bytes.
local function run_frames(link, reps, dirty)
	local reconcile_packet = link.client.reconcile_packet
	local elapsed = 0
	local bytes = 0
	for rep = 1, reps do
		dirty(rep)
		local packets = link.server.generate_packets()
		local packet = packets[link.viewer]
		bytes += buffer.len(packet.data)
		local t = os.clock()
		reconcile_packet(packet)
		elapsed += os.clock() - t
	end
	return elapsed, bytes
end

local function check(condition, label)
	if not condition then
		error(`sanity check failed: {label}`)
	end
end

local function report(name, ops_per_frame, reps, elapsed, bytes)
	local ms = 1000 * elapsed
	print(
		string.format(
			"%-14s ops/frame=%5d | reconcile=%8.2fms  (%.4fms/frame) | packet avg=%7.0f B",
			name,
			ops_per_frame,
			ms,
			ms / reps,
			bytes / reps
		)
	)
end

-- ---- values: unpaired-component value changes -----------------------------------

local function run_values()
	local link = create_link()
	local server_world = link.server_world

	local server_components = table.create(NUM_COMPONENTS)
	local client_components = table.create(NUM_COMPONENTS)
	for c = 1, NUM_COMPONENTS do
		server_components[c], client_components[c] = map_component(link)
	end

	-- ENTITIES_PER_COMPONENT distinct entities per component, every entity
	-- Replicated and holding exactly one of the components
	local count = NUM_COMPONENTS * ENTITIES_PER_COMPONENT
	local entities = table.create(count)
	local entity_components = table.create(count)
	local index = 0
	for c = 1, NUM_COMPONENTS do
		local component = server_components[c]
		for _ = 1, ENTITIES_PER_COMPONENT do
			index += 1
			local entity = server_world:entity()
			server_world:add(entity, link.server.Replicated)
			server_world:set(entity, component, index)
			entities[index] = entity
			entity_components[index] = component
		end
	end

	sync_initial(link)

	local elapsed, bytes = run_frames(link, REPS, function(rep)
		for i = 1, count do
			server_world:set(entities[i], entity_components[i], i * 7 + rep)
		end
	end)

	local last_local = link.client.get_client_entity(entities[count])
	check(last_local ~= nil, "values: last entity mapped")
	check(
		link.client_world:get(last_local, client_components[NUM_COMPONENTS]) == count * 7 + REPS,
		"values: last value applied"
	)

	report("values", count, REPS, elapsed, bytes)
end

-- ---- adds_removes: component add/remove churn --------------------------------

local function run_adds_removes()
	local link = create_link()
	local server_world = link.server_world
	local server_component, client_component = map_component(link)

	local entities = table.create(TOGGLE_ENTITIES)
	for i = 1, TOGGLE_ENTITIES do
		local entity = server_world:entity()
		server_world:add(entity, link.server.Replicated)
		-- half start with the component so every frame is half adds, half removes
		if i % 2 == 0 then
			server_world:set(entity, server_component, i)
		end
		entities[i] = entity
	end

	sync_initial(link)

	local elapsed, bytes = run_frames(link, REPS, function(rep)
		for i = 1, TOGGLE_ENTITIES do
			if (i + rep) % 2 == 0 then
				server_world:set(entities[i], server_component, i + rep)
			else
				server_world:remove(entities[i], server_component)
			end
		end
	end)

	local even_local = link.client.get_client_entity(entities[2])
	local odd_local = link.client.get_client_entity(entities[1])
	check(link.client_world:get(even_local, client_component) == 2 + REPS, "adds_removes: added value applied")
	check(link.client_world:has(odd_local, client_component) == false, "adds_removes: removal applied")

	report("adds_removes", TOGGLE_ENTITIES, REPS, elapsed, bytes)
end

-- ---- churn: entity creation/deletion -----------------------------------------

local function run_churn()
	local link = create_link()
	local server_world = link.server_world
	local server_component, client_component = map_component(link)
	local server_tag, client_tag = map_tag(link)

	local last_spawned, last_value
	local function spawn(value)
		local entity = server_world:entity()
		server_world:add(entity, link.server.Replicated)
		server_world:set(entity, server_component, value)
		server_world:add(entity, server_tag)
		last_spawned = entity
		last_value = value
		return entity
	end

	-- ring buffer of live entities; each frame deletes the oldest slice and
	-- creates a fresh one in its place
	local live = table.create(CHURN_LIVE)
	for i = 1, CHURN_LIVE do
		live[i] = spawn(i)
	end
	local first_spawned = live[1]

	sync_initial(link)
	local first_local = link.client.get_client_entity(first_spawned)

	local cursor = 0
	local elapsed, bytes = run_frames(link, REPS, function(rep)
		for k = 1, CHURN_PER_FRAME do
			local slot = cursor + k
			server_world:delete(live[slot])
			live[slot] = spawn(rep * CHURN_PER_FRAME + k)
		end
		cursor = (cursor + CHURN_PER_FRAME) % CHURN_LIVE
	end)

	-- the first entity's dense id has long been recycled by the churn ring, so
	-- its server id resolves to the slot's current tenant; the deletion itself
	-- is observable through its client entity being gone
	check(link.client_world:contains(first_local :: any) == false, "churn: deleted entity's client entity deleted")
	local newest_local = link.client.get_client_entity(last_spawned)
	check(newest_local ~= nil, "churn: newest entity mapped")
	check(link.client_world:get(newest_local, client_component) == last_value, "churn: newest value applied")
	check(link.client_world:has(newest_local, client_tag) == true, "churn: newest tag applied")

	report("churn", CHURN_PER_FRAME * 2, REPS, elapsed, bytes)
end

-- ---- pair_values: pair value changes across many targets ---------------------

local function run_pair_values()
	local link = create_link()
	local server_world = link.server_world
	local server_relation, client_relation = map_component(link)

	-- one subject per target, each holding a data pair to its own target, so
	-- one relation spans PAIR_TARGETS distinct pair ids
	local subjects = table.create(PAIR_TARGETS)
	local targets = table.create(PAIR_TARGETS)
	local server_pairs = table.create(PAIR_TARGETS)
	for i = 1, PAIR_TARGETS do
		local target = server_world:entity()
		server_world:add(target, link.server.Replicated)
		targets[i] = target
		local subject = server_world:entity()
		server_world:add(subject, link.server.Replicated)
		server_world:set(subject, pair(server_relation, target), i)
		subjects[i] = subject
		server_pairs[i] = pair(server_relation, target)
	end

	sync_initial(link)

	local elapsed, bytes = run_frames(link, REPS, function(rep)
		for i = 1, PAIR_TARGETS do
			server_world:set(subjects[i], server_pairs[i], i * 3 + rep)
		end
	end)

	local subject_local = link.client.get_client_entity(subjects[PAIR_TARGETS])
	local target_local = link.client.get_client_entity(targets[PAIR_TARGETS])
	check(
		link.client_world:get(subject_local, pair(client_relation, target_local)) == PAIR_TARGETS * 3 + REPS,
		"pair_values: last pair value applied"
	)

	report("pair_values", PAIR_TARGETS, REPS, elapsed, bytes)
end

-- ---- pair_retarget: pair add/remove churn across targets ---------------------

local function run_pair_retarget()
	local link = create_link()
	local server_world = link.server_world
	local server_relation, client_relation = map_component(link)

	local targets = table.create(RETARGET_SUBJECTS)
	for j = 1, RETARGET_SUBJECTS do
		local target = server_world:entity()
		server_world:add(target, link.server.Replicated)
		targets[j] = target
	end

	-- subject i starts at target i and advances one slot per frame, so every
	-- frame touches every target's run with one add and one remove
	local subjects = table.create(RETARGET_SUBJECTS)
	for i = 1, RETARGET_SUBJECTS do
		local subject = server_world:entity()
		server_world:add(subject, link.server.Replicated)
		server_world:set(subject, pair(server_relation, targets[i]), i)
		subjects[i] = subject
	end

	sync_initial(link)

	local elapsed, bytes = run_frames(link, REPS, function(rep)
		for i = 1, RETARGET_SUBJECTS do
			local old_target = targets[((i - 1 + rep - 1) % RETARGET_SUBJECTS) + 1]
			local new_target = targets[((i - 1 + rep) % RETARGET_SUBJECTS) + 1]
			server_world:remove(subjects[i], pair(server_relation, old_target))
			server_world:set(subjects[i], pair(server_relation, new_target), i * 3 + rep)
		end
	end)

	local subject_local = link.client.get_client_entity(subjects[1])
	local final_target = targets[(REPS % RETARGET_SUBJECTS) + 1]
	local final_target_local = link.client.get_client_entity(final_target)
	check(
		link.client_world:get(subject_local, pair(client_relation, final_target_local)) == 3 + REPS,
		"pair_retarget: final pair applied"
	)
	local start_target_local = link.client.get_client_entity(targets[1])
	check(
		link.client_world:has(subject_local, pair(client_relation, start_target_local)) == false,
		"pair_retarget: stale pair removed"
	)

	report("pair_retarget", RETARGET_SUBJECTS * 2, REPS, elapsed, bytes)
end

-- ---- full: a joiner's snapshot into a fresh client world ---------------------

local function run_full()
	local server_world = jecs.World.new()
	local server = create_server(server_world)
	align_ids(server_world)

	local server_components = table.create(NUM_COMPONENTS)
	for c = 1, NUM_COMPONENTS do
		local component = server_world:component()
		server_world:add(component, server.Networked)
		server_components[c] = component
	end
	local server_tag = server_world:entity()
	server_world:add(server_tag, server.Networked)
	local server_relation = server_world:component()
	server_world:add(server_relation, server.Networked)

	-- every entity holds one of the data components, every 4th the tag, and
	-- the first FULL_PAIRS pair-target the next FULL_PAIRS
	local entities = table.create(FULL_BASE)
	for i = 1, FULL_BASE do
		local entity = server_world:entity()
		server_world:add(entity, server.Replicated)
		server_world:set(entity, server_components[((i - 1) % NUM_COMPONENTS) + 1], i)
		if i % 4 == 0 then
			server_world:add(entity, server_tag)
		end
		entities[i] = entity
	end
	for i = 1, FULL_PAIRS do
		server_world:set(entities[FULL_PAIRS + i], pair(server_relation, entities[i]), i * 3)
	end

	-- one joiner's full packet, reconciled into a fresh client world each rep
	-- (world construction and component mapping untimed)
	local viewer = {}
	server.add_client(viewer)
	local packet = server.generate_packets()[viewer]

	local elapsed = 0
	local last_world, last_client, last_components, last_relation
	for _ = 1, FULL_REPS do
		local client_world = jecs.World.new()
		local client = create_client(client_world)
		align_ids(client_world)
		local client_components = table.create(NUM_COMPONENTS)
		for c = 1, NUM_COMPONENTS do
			client_components[c] = client_world:component()
			client.set_client_entity(server_components[c], client_components[c])
		end
		client.set_client_entity(server_tag, client_world:entity())
		local client_relation = client_world:component()
		client.set_client_entity(server_relation, client_relation)
		last_world = client_world
		last_client = client
		last_components = client_components
		last_relation = client_relation

		local t = os.clock()
		client.reconcile_packet(packet)
		elapsed += os.clock() - t
	end

	local last_local = last_client.get_client_entity(entities[FULL_BASE])
	check(
		last_world:get(last_local, last_components[((FULL_BASE - 1) % NUM_COMPONENTS) + 1]) == FULL_BASE,
		"full: last value applied"
	)
	local subject_local = last_client.get_client_entity(entities[FULL_PAIRS + 1])
	local target_local = last_client.get_client_entity(entities[1])
	check(last_world:get(subject_local, pair(last_relation, target_local)) == 3, "full: pair value applied")

	local cells = FULL_BASE + FULL_BASE // 4 + FULL_PAIRS
	report("full", cells, FULL_REPS, elapsed, FULL_REPS * buffer.len(packet.data))
end

-- ---- run ---------------------------------------------------------------------

print(string.format("reps=%d full_reps=%d (hookless values)", REPS, FULL_REPS))
run_values()
run_adds_removes()
run_churn()
run_pair_values()
run_pair_retarget()
run_full()

return true
