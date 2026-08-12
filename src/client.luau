--!strict
--!native
--!optimize 2

-- the client half of duplecs: server/client entity mapping, reconciliation overrides, and packet
-- reconciliation. constructed per world by the first duplecs.client call (see init.luau); later calls return
-- the same memoized instance.

-- note: in warn/error strings, `$` prefixes verified-live entity ids and `?` unverifiable ones (dead, or
-- server-namespace ids this world can't check) -- see diagnostics.luau, which owns the convention and the
-- [duplecs] prefix every message carries.

local jecs = require("../roblox_packages/jecs")
local pair = jecs.pair

local types = require("./types")
local wire = require("./wire")
local get_shared = require("./shared")
local hooks = require("./hooks")
local diagnostics = require("./diagnostics")

local fail = diagnostics.fail
local id_to_string = diagnostics.id_to_string

-- CONSTANTS

-- wire-format flag bits, widths, id encoding, and the shared header readers; the layouts are documented in
-- wire.luau.
local flag_inline_values = wire.flag_inline_values
local flag_side_values = wire.flag_side_values
local flag_wide = wire.flag_wide
local id_width = wire.id_width
local gen_id_width = wire.gen_id_width
local chunk_header_width = wire.chunk_header_width
local read_id = wire.read_id
local read_gen_id = wire.read_gen_id
local check_version = wire.check_version
local read_packet_frame = wire.read_packet_frame
local read_packet_header = wire.read_packet_header
local read_name = wire.read_name
local read_section_header = wire.read_section_header
local read_run_header = wire.read_run_header
local check_chunk_version = wire.check_chunk_version
local read_chunk_frame = wire.read_chunk_frame
local read_chunk_section_header = wire.read_chunk_section_header

-- TYPES

type World = types.World
type Entity = types.Entity
type Component<T = any> = types.Component<T>
type Id<T = any> = types.Id<T>
type Packet = types.Packet

export type ChangedOverride<T = any> = (Entity, T) -> ()
export type RemovedOverride = (Entity) -> ()

local function create_client(world: World, shared_record: get_shared.Record)
	-- DIAGNOSTICS

	-- the instance's warn reporter (see diagnostics.luau): the local below shadows the global warn so every
	-- warning in this half rides the shared prefix and the injectable hook (set_warn_hook in the instance
	-- table).
	local reporter = diagnostics.create_reporter()
	local warn = reporter.warn

	-- COMPONENTS

	-- the client-relevant slice of the world's shared component set (see shared.luau)
	local Imported = shared_record.components.Imported

	-- GENERAL FUNCTIONS

	local dense = (jecs.ECS_ID :: any) :: (entity_gen: number) -> number

	-- jecs never replaces this container on a live world (unlike world.archetypes, which world:cleanup
	-- rebuilds), so the sweep's record walks share one fetch
	local component_index = world.component_index

	-- ENTITY MAPPING

	-- client entities key by the *dense* half of their server id -- all a section wire id carries -- while
	-- server_entity_map (and both maps' values) keeps the full gen-qualified id: the creation and names lists
	-- are where a client learns the generation, which get_server_entity must expose for client->server requests.
	-- dense keys stay unambiguous because the server never holds two live entities on one dense id and reconcile
	-- applies deletes before creates, so a recycled id's old mapping always ends before its new tenant arrives.
	local client_entity_map = {} :: { [number]: Entity }
	local server_entity_map = {} :: { [Entity]: number }

	-- dense server ids whose mapping was established by a shared-name announcement (see map_shared_name): a name
	-- retraction may only end these -- a creation-established mapping ends through the unreplicated list, and a
	-- manual one belongs to the caller. cleared whenever the mapping ends or a creation entry adopts it.
	local name_mapped = {} :: { [number]: true }

	-- dense server ids already reported for arriving unmapped (see warn_unmapped): one warning per id per
	-- unmapped stretch rather than one per section, cleared when the id maps so a later regression warns anew.
	local skip_warned = {} :: { [number]: true }

	-- wire-facing: server_entity is a dense id straight off the wire
	local function get_client_entity_from_dense(server_entity: number): Entity?
		return client_entity_map[server_entity]
	end

	local function set_client_entity(server_entity_gen: number, client_entity: Entity)
		local dense_id = dense(server_entity_gen)
		client_entity_map[dense_id] = client_entity
		server_entity_map[client_entity] = server_entity_gen
		skip_warned[dense_id] = nil
		world:add(client_entity, Imported)
	end

	local function get_server_entity(client_entity: Entity): number?
		return server_entity_map[client_entity]
	end

	-- warns when a reliable section references an unmapped component, relation, or pair target. unresolvable
	-- ids skip by design, but the server only references ids the client was given the means to map -- pair
	-- cells never ship to a client that lacks the target, and definitions are the caller's mapping
	-- responsibility -- so an unmapped id reaching reconcile means the contract was missed: the matching client
	-- entity wasn't named (or mapped via set_client_entity) before the server first referenced the id. the
	-- resulting holes are permanent (deltas are exactly-once; a mapping formed later only receives what changes
	-- afterward), so silence would hide the bug indefinitely. the unreliable path stays silent instead: chunks
	-- legitimately outrun the reliable packet that maps their ids (see reconcile_chunk).
	local function warn_unmapped(dense_id: number, role: string)
		if skip_warned[dense_id] ~= nil then
			return
		end
		skip_warned[dense_id] = true
		warn(
			`a received section's {role} (server {id_to_string(dense_id)}) has no client mapping! its cells were skipped -- map the id before the server first references it: give the matching client entity the shared jecs.Name, or map it with set_client_entity at startup`
		)
	end

	-- the mapping-teardown sweep, forward-declared for the mapping enders below and defined past the overrides
	-- (whose removal dispatch it shares).
	local sweep_imported_cells: (client_target: Entity) -> ()

	-- a creation for an already-mapped server id adopts the mapping silently: pre-mapping an id the server is
	-- about to create is the prediction flow set_client_entity exists for, so the prepared client entity simply
	-- starts receiving the entity's data. the creation is authoritative for the generation (a manual mapping may
	-- have been made with a stale one), and the adopted mapping now ends through the entity's deletion, never a
	-- name retraction. one exception: a *name-established* mapping holding a different generation is a stale
	-- older tenant of the dense id, never a prediction -- the named target died and its id recycled into a
	-- Replicated tenant within one interval, so adopting would hand the client's own named entity to the new
	-- tenant (its cells would apply onto it, and its eventual deletion would delete it outright) -- so the stale
	-- mapping is torn down (and its cells swept) and a fresh client entity minted instead. a name-established
	-- mapping with a *matching* generation keeps adopting: that is the named-target-turned-Replicated flow. a
	-- mapping left pointing at a dead client entity is replaced like it never existed.
	local function create_client_entity(server_entity_gen: number)
		local dense_id = dense(server_entity_gen)
		local existing_entity = client_entity_map[dense_id]
		if existing_entity ~= nil and world:contains(existing_entity) then
			if name_mapped[dense_id] == nil or server_entity_map[existing_entity] == server_entity_gen then
				server_entity_map[existing_entity] = server_entity_gen
				name_mapped[dense_id] = nil
				return
			end
			-- the Imported removed hook tears the stale mapping down; the entity belongs to this world and stays
			world:remove(existing_entity, Imported)
			sweep_imported_cells(existing_entity)
		end
		local client_entity = world:entity() :: Entity
		set_client_entity(server_entity_gen, client_entity)
	end

	-- public lookups resolve through the dense half (all a wire id carries), but the caller's full generation
	-- must match the mapping's: a stale generation names an older or newer tenant of the dense slot, not the
	-- entity the caller asked for, so it resolves to nil rather than a false positive (see spec.md). the inverse
	-- get_server_entity always returns the full gen-qualified id, so a round-tripped id matches exactly.
	local function get_client_entity(server_entity: number): Entity?
		local client_entity = client_entity_map[dense(server_entity)]
		if client_entity ~= nil and server_entity_map[client_entity] == server_entity then
			return client_entity
		end
		return nil
	end

	local function set_client_entity_public(server_entity_gen: number, client_entity: Entity)
		local existing_entity = client_entity_map[dense(server_entity_gen)]
		if existing_entity == nil or world:contains(existing_entity) ~= true then
			set_client_entity(server_entity_gen, client_entity)
		else
			fail(`server entity {id_to_string(dense(server_entity_gen))} is already mapped to a client entity!`)
		end
	end

	local function remove_references(client_entity: Entity, server_entity: number)
		server_entity_map[client_entity] = nil
		local dense_id = dense(server_entity)
		-- the dense slot may already belong to a newer mapping that replaced this one; only the mapping's own entry
		-- (and provenance) end with it
		if client_entity_map[dense_id] == client_entity then
			client_entity_map[dense_id] = nil
			name_mapped[dense_id] = nil
		end
	end

	-- prevents cascading (OnDeleteTarget, Delete) for imported entities since the entity might still exist on
	-- the server and have Replicated dependents. note: pairs referencing this entity that exist only locally are
	-- *not* renewed if the entity gets Replicated again.
	local function safe_delete(client_entity: Entity)
		-- walk the local (OnDeleteTarget, Delete) closure without deleting anything yet: detach imported dependents
		-- (removing the currently-iterated pair is iteration-safe) and queue local ones. the visited set keeps
		-- cyclical relations from re-queueing an entity.
		local queue = { client_entity }
		local visited = { [client_entity] = true } :: { [Entity]: true }
		local count = 1
		local index = 0
		while index < count do
			index += 1
			local entity = queue[index]
			for relation in world:each(pair(jecs.OnDeleteTarget, jecs.Delete)) do
				for dependent in world:each(pair(relation, entity)) do
					if get_server_entity(dependent) then
						world:remove(dependent, pair(relation, entity))
					elseif visited[dependent] == nil then
						visited[dependent] = true
						count += 1
						queue[count] = dependent
					end
				end
			end
		end

		-- with every imported dependent detached, deletion order is free; an entity a prior iteration already
		-- cascade-deleted is skipped.
		for i = 1, count do
			local entity = queue[i]
			if world:contains(entity) then
				world:delete(entity)
			end
		end
	end

	local function delete_client_entity(server_entity: number)
		local client_entity = client_entity_map[server_entity]
		if client_entity then
			remove_references(client_entity, server_entity)
			safe_delete(client_entity)
		end
	end

	local function on_imported_added(client_entity: Entity, id: Id)
		if id ~= Imported then
			world:remove(client_entity, id)
			fail(`Imported is not meant to be paired! ({id_to_string(client_entity :: any, world)})`)
		end
		if not get_server_entity(client_entity) then
			world:remove(client_entity, Imported)
			fail(
				`Imported cannot be added to entities with no server mapping! ({id_to_string(
					client_entity :: any,
					world
				)})`
			)
		end
	end

	hooks.added(world, Imported, on_imported_added)

	hooks.removed(world, Imported, function(client_entity: Entity, id: Id)
		-- a pair using Imported as its relation never owns a mapping
		if id ~= Imported then
			return
		end
		-- covers deletions that bypass delete_client_entity (e.g. cascades). note: the client should avoid adding
		-- (OnDeleteTarget, Delete) to imported entities; the resulting server/client mismatch is *not*
		-- auto-corrected.
		local server_entity = get_server_entity(client_entity)
		if server_entity then
			remove_references(client_entity, server_entity)
		end
	end)

	-- construction catch-up: the shared component set (see shared.luau) can predate this instance, so entities
	-- may already carry Imported -- always a misuse, since mappings are minted by this instance's own paths and
	-- none existed before construction. replay the guard over pre-collected holders (its remove would
	-- invalidate a live world:each walk), surfacing the same error a live add would have raised.
	local imported_holders = {} :: { Entity }
	for client_entity in world:each(Imported) do
		table.insert(imported_holders, client_entity)
	end
	local imported_pair_holders = {} :: { Entity }
	for client_entity in world:each(pair(Imported, jecs.Wildcard)) do
		table.insert(imported_pair_holders, client_entity)
	end
	for _, client_entity in imported_holders do
		on_imported_added(client_entity, Imported)
	end
	for _, client_entity in imported_pair_holders do
		on_imported_added(client_entity, pair(Imported, world:target(client_entity, Imported) :: any))
	end

	-- NAME INDEX

	-- client entities by jecs.Name, kept live by the hooks below (seeded by a catch-up walk at construction) so
	-- announced shared names resolve without scanning. entity_names mirrors the current name per entity so a
	-- rename clears its old index entry. names used for shared definitions must be unique in this world; on a
	-- collision the latest indexed entity wins.
	local entities_by_name = {} :: { [string]: Entity }
	local entity_names = {} :: { [Entity]: string }

	local function index_name(client_entity: Entity, name: unknown)
		if type(name) ~= "string" then
			return
		end
		local old_name = entity_names[client_entity]
		if old_name ~= nil and old_name ~= name and entities_by_name[old_name] == client_entity then
			entities_by_name[old_name] = nil
		end
		entity_names[client_entity] = name
		entities_by_name[name] = client_entity
	end

	local function deindex_name(client_entity: Entity)
		local name = entity_names[client_entity]
		if name == nil then
			return
		end
		entity_names[client_entity] = nil
		if entities_by_name[name] == client_entity then
			entities_by_name[name] = nil
		end
	end

	hooks.added(world, jecs.Name, function(client_entity: Entity, id: Id, name: unknown)
		if id == (jecs.Name :: any) then
			index_name(client_entity, name)
		end
	end)

	hooks.changed(world, jecs.Name, function(client_entity: Entity, id: Id, name: unknown)
		if id == (jecs.Name :: any) then
			index_name(client_entity, name)
		end
	end)

	hooks.removed(world, jecs.Name, function(client_entity: Entity, id: Id)
		if id == (jecs.Name :: any) then
			deindex_name(client_entity)
		end
	end)

	for client_entity in world:each(jecs.Name) do
		index_name(client_entity, world:get(client_entity, jecs.Name))
	end

	-- maps one announced shared name: ids the server names on the wire (networked definitions and named pair
	-- targets) bind to the client entity carrying the same jecs.Name, sparing the startup set_client_entity
	-- calls. a server id already mapped with the announced generation is left alone (a manual mapping wins), but
	-- a mapping holding a *different* generation is for an older tenant of the dense id -- the announcement is
	-- authoritative for the current one, so the stale mapping ends first and its cells are swept before the new
	-- tenant's sections apply (this is also what resolves a same-frame die-and-recycle, where the old tenant's
	-- retraction collapses into the new tenant's announcement -- the server drops the old tenant's tainted
	-- removals, so the sweep is the only thing removing its cells). a name with no live client entity is skipped
	-- silently, not warned: announcements ride to every client regardless of privacy (names are schema), so a
	-- client legitimately lacks entities for definitions whose data never reaches it (server-only components
	-- among them) -- data arriving for a still-unmapped id is what warn_unmapped reports. a client entity
	-- already mapped to a different server id warns -- two shared definitions resolving to one client entity is
	-- a naming collision worth surfacing.
	local function map_shared_name(server_entity_gen: number, name: string)
		local dense_id = dense(server_entity_gen)
		local existing_entity = client_entity_map[dense_id]
		if existing_entity ~= nil and world:contains(existing_entity) then
			if server_entity_map[existing_entity] == server_entity_gen then
				return
			end
			-- the Imported removed hook tears the stale mapping down
			world:remove(existing_entity, Imported)
			sweep_imported_cells(existing_entity)
		end
		local client_entity = entities_by_name[name]
		if client_entity == nil or world:contains(client_entity) ~= true then
			return
		end
		local mapped_server = get_server_entity(client_entity)
		if mapped_server ~= nil and mapped_server ~= server_entity_gen then
			warn(
				`shared name "{name}" resolves to a client entity already mapped to server entity {id_to_string(
					dense(mapped_server)
				)}!`
			)
			return
		end
		set_client_entity(server_entity_gen, client_entity)
		name_mapped[dense_id] = true
	end

	-- ends the mapping a retracted announcement established (see the names layout in wire.luau): the server
	-- withdrew the id's name -- its named target died, lost its name, or stopped being replication-relevant --
	-- so the mapping must not survive to misbind the dense id's next tenant. only name-established mappings end
	-- here, and only while they still hold the retracted generation: a creation in the same packet has already
	-- adopted the mapping out of name provenance (a named target that became Replicated keeps its mapping
	-- wherever the entity is visible), and a newer tenant's mapping is never for the retracted announcement.
	-- ending the mapping also sweeps the entity's cells -- retractions apply after the sections, so a plain
	-- death's explicit removals have already applied and the sweep finds nothing, but when the dense id recycled
	-- into an unreplicable (or unnamed tracked) tenant within one interval no announcement overwrote the
	-- retraction and the server dropped the old tenant's tainted removals, so this sweep is the only cleanup
	-- those cells get -- and it also clears whatever an unnamed tracked tenant's sections misapplied through
	-- this still-live mapping moments earlier.
	local function unmap_shared_name(server_entity_gen: number)
		local dense_id = dense(server_entity_gen)
		if name_mapped[dense_id] == nil then
			return
		end
		local client_entity = client_entity_map[dense_id]
		if client_entity ~= nil and server_entity_map[client_entity] == server_entity_gen then
			-- the Imported removed hook tears the mapping down; the client entity itself belongs to this world
			-- and stays
			world:remove(client_entity, Imported)
			sweep_imported_cells(client_entity)
		end
	end

	-- SERDES

	-- the per-world serdes store (see shared.luau / serdes.luau): its Serdes component and validation hooks
	-- predate every possible registration, so there is nothing to catch up on here
	local Serdes = shared_record.components.Serdes
	local resolve_serdes = shared_record.resolve_serdes

	-- OVERRIDES

	local changed_overrides = {} :: { [Id]: ChangedOverride? }
	local removed_overrides = {} :: { [Id]: RemovedOverride? }

	-- overrides are keyed by a concrete component or pair, with a (relation, Wildcard) pair normalizing to the
	-- unpaired relation; a pair without overrides of its own falls back to its relation's (reconcile_section).
	local function normalize_component_key(component: Id): Id
		if jecs.IS_PAIR(component) and jecs.ECS_PAIR_SECOND(component) == jecs.Wildcard then
			return jecs.pair_first(world, component)
		end
		return component
	end

	local function set_changed_override<T>(component: Id<T>, on_changed: ChangedOverride<T>?)
		changed_overrides[normalize_component_key(component)] = on_changed
	end

	local function set_removed_override(component: Id, on_removed: RemovedOverride?)
		removed_overrides[normalize_component_key(component)] = on_removed
	end

	-- the getters return exactly what was registered for the normalized key (never the relation fallback
	-- reconcile applies); mainly for swapping out an existing override and later swapping it back in.
	local function get_changed_override<T>(component: Id<T>): ChangedOverride<T>?
		return changed_overrides[normalize_component_key(component)]
	end

	local function get_removed_override(component: Id): RemovedOverride?
		return removed_overrides[normalize_component_key(component)]
	end

	-- MAPPING-TEARDOWN SWEEP

	-- removes every cell on an imported subject that references client_target through otherwise-imported
	-- halves -- pairs targeting it whose relation is imported, pairs using it as the relation whose target is
	-- imported, and unpaired cells using it as the component -- dispatching each removal exactly like
	-- apply_lists' removed entries (cell-level override, relation-level fallback, else world:remove). this is
	-- the out-of-band cleanup for cells referencing a name-mapped entity the server withdrew: explicit
	-- removals are the only thing cleaning them (the entity is client-owned and never deleted by
	-- reconciliation), and the server drops the removals of a dense id that retired one tenant and re-bound
	-- another within one interval -- they would misresolve to the new tenant on the wire (see
	-- resolve_visibility_cells in server.luau) -- so the client owns them at exactly the moments a mapping
	-- ends without its client entity dying: a retraction unmap, a superseding announcement's teardown, and a
	-- creation's stale-name-mapping teardown. cells riding purely local ids and local subjects are untouched;
	-- the semantic edge -- client-created cells whose other halves are imported are swept too -- is documented
	-- in docs/spec.md. deliberately *not* hooked on the Imported removal itself: that fires
	-- mid-archetype-transition, and a genuine deletion's pairs are removed by jecs with the dying entity.
	-- removals are collected before any is applied, since applying moves subjects between archetypes under
	-- the walk.
	function sweep_imported_cells(client_target: Entity)
		local target_dense = dense(client_target :: any)
		local subjects: { Entity } = {}
		local cell_ids: { Id } = {}
		local count = 0

		-- the three walks below drive off the ids' component records directly (an uncached
		-- world:query():archetypes() call rebuilds exactly the record's archetype list, and world:each pays a
		-- closure plus a call per subject); world.archetypes is re-read per sweep since world:cleanup rebuilds it.
		local world_archetypes = world.archetypes

		-- pairs targeting the entity, the relation recovered from archetype.types. pairs sharing a *target* are
		-- not contiguous in types (pair ids pack relation-major, and types is sorted by id), so unlike the
		-- relation-wildcard walk below this scans each archetype's types, with the record's count as an early
		-- exit once every targeting pair has been seen.
		local idr_target = component_index[pair(jecs.Wildcard, client_target) :: any]
		if idr_target ~= nil then
			local target_counts = idr_target.counts
			for archetype_id in idr_target.records do
				local archetype = world_archetypes[archetype_id]
				local entities = archetype.entities
				if #entities == 0 then
					continue
				end
				local remaining = target_counts[archetype_id]
				for _, id in archetype.types do
					if jecs.IS_PAIR(id :: any) and (jecs.ECS_PAIR_SECOND(id :: any) :: any) == target_dense then
						local relation = jecs.pair_first(world, id :: any)
						if server_entity_map[relation :: any] ~= nil then
							for _, subject in entities do
								if server_entity_map[subject :: any] ~= nil then
									count += 1
									subjects[count] = subject :: any
									cell_ids[count] = id :: any
								end
							end
						end
						remaining -= 1
						if remaining == 0 then
							break
						end
					end
				end
			end
		end

		-- pairs using the entity as the relation: same-relation pairs sit contiguously in types, so the record's
		-- records/counts give each archetype's exact slice (see the server's each_target). the entity's own
		-- mapping ended just before this sweep, so the target check must allow the entity itself alongside
		-- imported targets -- which also collects a self-targeting pair exactly once, the walk above having
		-- skipped it for its no-longer-imported relation.
		local idr_relation = component_index[pair(client_target, jecs.Wildcard) :: any]
		if idr_relation ~= nil then
			local relation_counts = idr_relation.counts
			for archetype_id, slice_start in idr_relation.records do
				local archetype = world_archetypes[archetype_id]
				local entities = archetype.entities
				if #entities == 0 then
					continue
				end
				local archetype_types = archetype.types
				for i = slice_start, slice_start + relation_counts[archetype_id] - 1 do
					local id = archetype_types[i]
					local pair_target = jecs.pair_second(world, id :: any)
					if
						(pair_target :: any) == (client_target :: any)
						or server_entity_map[pair_target :: any] ~= nil
					then
						for _, subject in entities do
							if server_entity_map[subject :: any] ~= nil then
								count += 1
								subjects[count] = subject :: any
								cell_ids[count] = id :: any
							end
						end
					end
				end
			end
		end

		-- unpaired cells using the entity as the component
		local idr_unpaired = component_index[client_target :: any]
		if idr_unpaired ~= nil then
			for archetype_id in idr_unpaired.records do
				for _, subject in world_archetypes[archetype_id].entities do
					if server_entity_map[subject :: any] ~= nil then
						count += 1
						subjects[count] = subject :: any
						cell_ids[count] = client_target :: any
					end
				end
			end
		end

		for i = 1, count do
			local subject = subjects[i]
			local id = cell_ids[i]
			local removed_override = removed_overrides[id]
			if removed_override == nil and jecs.IS_PAIR(id) then
				removed_override = removed_overrides[jecs.pair_first(world, id)]
			end
			if removed_override then
				removed_override(subject)
			else
				world:remove(subject, id)
			end
		end
	end

	-- RECONCILE

	-- applies one section's -- or one grouped run's -- lists at data[offset]: ids with inline or side-array
	-- values, then nulled, then removed. these are the fused parse-and-apply loops, shared so both layouts
	-- stream through identical code; side_base is the caller's cursor into the side array (always 0 for a plain
	-- section, which owns its array whole), and relation_changed / relation_removed are the relation-level
	-- override fallbacks, fixed for a whole section so the caller resolves them once rather than per run.
	-- returns the offset just past the lists.
	local function apply_lists(
		data: buffer,
		offset: number,
		component: Id,
		relation: Id?,
		inline: boolean,
		ids_count: number,
		nulled_count: number,
		removed_count: number,
		side_values: { any }?,
		side_base: number,
		relation_changed: ChangedOverride?,
		relation_removed: RemovedOverride?
	): number
		local changed_override = changed_overrides[component]
		if changed_override == nil then
			changed_override = relation_changed
		end

		if ids_count > 0 then
			if inline then
				local serdes = resolve_serdes(component, relation)
				if serdes == nil then
					fail(
						`received serialized values for {id_to_string(component :: any, world)} but no serdes hooks are assigned!`
					)
				end
				local hooks = serdes :: any
				local decode = hooks.decode
				-- ids and values advance in lockstep: ids at offset, values past them. each value decodes from a fresh
				-- value-sized buffer, its length read off the u16 prefix unless the registration declares a static size;
				-- unmapped entities hop the value by its length without decoding it. decode runs under pcall: the
				-- framing gives every value's length before it decodes, so a throwing hook skips exactly its own value --
				-- keeping the stream aligned for the rest of the packet, which a mid-reconcile unwind would lose
				-- unrecoverably (deltas are exactly-once and applied entries aren't safely re-appliable) -- with one
				-- warning per list carrying the first error
				local static: number? = hooks.size
				local value_offset = offset + ids_count * id_width
				local skipped = 0
				local first_error: any = nil
				if changed_override then
					for _ = 1, ids_count do
						local entity = get_client_entity_from_dense(read_id(data, offset))
						offset += id_width
						local length: number
						if static ~= nil then
							length = static
						else
							length = buffer.readu16(data, value_offset)
							value_offset += 2
						end
						if entity then
							local encoded = buffer.create(length)
							buffer.copy(encoded, 0, data, value_offset, length)
							local ok, value = pcall(decode, encoded)
							if ok then
								changed_override(entity, value)
							else
								skipped += 1
								if first_error == nil then
									first_error = value
								end
							end
						end
						value_offset += length
					end
				else
					for _ = 1, ids_count do
						local entity = get_client_entity_from_dense(read_id(data, offset))
						offset += id_width
						local length: number
						if static ~= nil then
							length = static
						else
							length = buffer.readu16(data, value_offset)
							value_offset += 2
						end
						if entity then
							local encoded = buffer.create(length)
							buffer.copy(encoded, 0, data, value_offset, length)
							local ok, value = pcall(decode, encoded)
							if ok then
								world:set(entity, component, value)
							else
								skipped += 1
								if first_error == nil then
									first_error = value
								end
							end
						end
						value_offset += length
					end
				end
				offset = value_offset
				if skipped > 0 then
					warn(
						`a serdes decode hook threw while decoding {id_to_string(component :: any, world)}! {skipped} value(s) were skipped and their cells will not update until they next change server-side: {first_error}`
					)
				end
			else
				local side = side_values :: { any }
				if changed_override then
					for i = 1, ids_count do
						local entity = get_client_entity_from_dense(read_id(data, offset))
						offset += id_width
						if entity then
							changed_override(entity, side[side_base + i])
						end
					end
				else
					for i = 1, ids_count do
						local entity = get_client_entity_from_dense(read_id(data, offset))
						offset += id_width
						if entity then
							world:set(entity, component, side[side_base + i])
						end
					end
				end
			end
		end

		if nulled_count > 0 then
			if changed_override then
				for _ = 1, nulled_count do
					local entity = get_client_entity_from_dense(read_id(data, offset))
					offset += id_width
					if entity then
						changed_override(entity)
					end
				end
			elseif jecs.is_tag(world, component) then
				for _ = 1, nulled_count do
					local entity = get_client_entity_from_dense(read_id(data, offset))
					offset += id_width
					if entity then
						world:add(entity, component)
					end
				end
			else
				-- data components must be nulled with :set(); world:add is a no-op when the component is already present
				for _ = 1, nulled_count do
					local entity = get_client_entity_from_dense(read_id(data, offset))
					offset += id_width
					if entity then
						world:set(entity, component, nil)
					end
				end
			end
		end

		if removed_count > 0 then
			local removed_override = removed_overrides[component]
			if removed_override == nil then
				removed_override = relation_removed
			end
			if removed_override then
				for _ = 1, removed_count do
					local entity = get_client_entity_from_dense(read_id(data, offset))
					offset += id_width
					if entity then
						removed_override(entity)
					end
				end
			else
				for _ = 1, removed_count do
					local entity = get_client_entity_from_dense(read_id(data, offset))
					offset += id_width
					if entity then
						world:remove(entity, component)
					end
				end
			end
		end

		return offset
	end

	-- stream-parses one section at data[section_offset] (the headers through wire.read_section_header /
	-- read_run_header, the id lists inline), applying cells as it reads, and returns the offset just past the
	-- section plus the advanced packet-values cursor. sections whose component or pair halves don't resolve
	-- locally are skipped -- whole via the length prefix, or run by run for a grouped section's unmapped targets --
	-- with a once-per-id warning (warn_unmapped), but skipped hookless lists still consume their side-array
	-- entries, keeping the cursor aligned for whatever follows.
	local function reconcile_section(
		data: buffer,
		section_offset: number,
		packet_values: { { any } }?,
		values_index: number
	): (number, number)
		local flags, next_offset, offset, first_id, target_id, ids_count, nulled_count, removed_count, run_count =
			read_section_header(data, section_offset)

		if run_count ~= nil then
			-- grouped pair section: relation resolves once, then every per-target run applies as its own mini section
			local side_values: { any }? = nil
			if bit32.band(flags, flag_side_values) ~= 0 then
				values_index += 1
				side_values = (packet_values :: { { any } })[values_index]
			end

			local client_relation = get_client_entity_from_dense(first_id)
			if client_relation == nil then
				-- unresolvable relation: skip the whole section; the side entry (when flagged) is already consumed above
				warn_unmapped(first_id, "relation")
				return next_offset, values_index
			end

			-- the relation-level override fallbacks, shared by every run
			local relation_changed = changed_overrides[client_relation]
			local relation_removed = removed_overrides[client_relation]

			local wide = bit32.band(flags, flag_wide) ~= 0
			local side_cursor = 0
			for _ = 1, run_count do
				local run_flags, list_offset, run_target, run_end, run_ids, run_nulled, run_removed =
					read_run_header(data, offset, wide)
				local inline = bit32.band(run_flags, flag_inline_values) ~= 0
				local client_target = get_client_entity_from_dense(run_target)
				if client_target == nil then
					-- unresolvable target: skip the run -- inline runs via their length prefix, the rest by their counted
					-- lists, with hookless runs still claiming their side entries
					warn_unmapped(run_target, "pair target")
					if inline then
						offset = run_end :: number
					else
						if run_ids > 0 then
							side_cursor += run_ids
						end
						offset = list_offset + (run_ids + run_nulled + run_removed) * id_width
					end
				else
					offset = apply_lists(
						data,
						list_offset,
						pair(client_relation, client_target),
						client_relation,
						inline,
						run_ids,
						run_nulled,
						run_removed,
						side_values,
						side_cursor,
						relation_changed,
						relation_removed
					)
					if not inline and run_ids > 0 then
						side_cursor += run_ids
					end
				end
			end

			return next_offset, values_index
		end

		local component: Id?
		local relation: Id?
		if target_id ~= nil then
			local client_relation = get_client_entity_from_dense(first_id)
			local client_target = get_client_entity_from_dense(target_id)
			if client_relation ~= nil and client_target ~= nil then
				component = pair(client_relation, client_target)
				relation = client_relation
			else
				if client_relation == nil then
					warn_unmapped(first_id, "relation")
				end
				if client_target == nil then
					warn_unmapped(target_id :: number, "pair target")
				end
			end
		else
			component = get_client_entity_from_dense(first_id)
			if component == nil then
				warn_unmapped(first_id, "component")
			end
		end

		local inline = bit32.band(flags, flag_inline_values) ~= 0
		local values: { any }? = nil
		if ids_count > 0 and not inline then
			values_index += 1
			values = (packet_values :: { { any } })[values_index]
		end

		if component == nil then
			return next_offset, values_index
		end

		local relation_changed = if relation then changed_overrides[relation] else nil
		local relation_removed = if relation then removed_overrides[relation] else nil
		apply_lists(
			data,
			offset,
			component,
			relation,
			inline,
			ids_count,
			nulled_count,
			removed_count,
			values,
			0,
			relation_changed,
			relation_removed
		)

		return next_offset, values_index
	end

	-- applies one unreliable chunk section's lists at data[offset]: ids with their serdes-encoded values, then
	-- nulled. the unreliable stream only *updates* cells -- membership is authoritative on the reliable path --
	-- so with no override registered a value applies only where the entity currently has the component: a chunk
	-- arriving after the reliable removal of a cell (drops and reordering make that inevitable) must not
	-- resurrect it with a stale value the server would never correct, since the cell is no longer streamed. a
	-- registered override is invoked unguarded instead -- it owns application, and cannot resurrect anything.
	-- values of unmapped or guarded entities are hopped by their length without decoding.
	local function apply_chunk_lists(
		data: buffer,
		offset: number,
		component: Id,
		relation: Id?,
		ids_count: number,
		nulled_count: number
	): number
		local changed_override = changed_overrides[component]
		if changed_override == nil and relation ~= nil then
			changed_override = changed_overrides[relation]
		end

		if ids_count > 0 then
			local serdes = resolve_serdes(component, relation)
			if serdes == nil then
				fail(
					`received serialized values for {id_to_string(component :: any, world)} but no serdes hooks are assigned!`
				)
			end
			local hooks = serdes :: any
			local decode = hooks.decode
			-- ids and values advance in lockstep: ids at offset, values past them. each value decodes from a fresh
			-- value-sized buffer, its length read off the u16 prefix unless the registration declares a static size;
			-- skipped entities hop the value by its length without decoding it. decode runs under pcall like
			-- apply_lists': a throwing hook skips exactly its own value with a warning -- a poisoned value would
			-- otherwise error every chunk carrying it, taking the whole unreliable channel down until the value
			-- changes -- and chunks are self-healing frame to frame, so the skipped cell is only stale, never lost
			local static: number? = hooks.size
			local value_offset = offset + ids_count * id_width
			local skipped = 0
			local first_error: any = nil
			if changed_override then
				for _ = 1, ids_count do
					local entity = get_client_entity_from_dense(read_id(data, offset))
					offset += id_width
					local length: number
					if static ~= nil then
						length = static
					else
						length = buffer.readu16(data, value_offset)
						value_offset += 2
					end
					if entity then
						local encoded = buffer.create(length)
						buffer.copy(encoded, 0, data, value_offset, length)
						local ok, value = pcall(decode, encoded)
						if ok then
							changed_override(entity, value)
						else
							skipped += 1
							if first_error == nil then
								first_error = value
							end
						end
					end
					value_offset += length
				end
			else
				for _ = 1, ids_count do
					local entity = get_client_entity_from_dense(read_id(data, offset))
					offset += id_width
					local length: number
					if static ~= nil then
						length = static
					else
						length = buffer.readu16(data, value_offset)
						value_offset += 2
					end
					if entity ~= nil and world:has(entity, component) then
						local encoded = buffer.create(length)
						buffer.copy(encoded, 0, data, value_offset, length)
						local ok, value = pcall(decode, encoded)
						if ok then
							world:set(entity, component, value)
						else
							skipped += 1
							if first_error == nil then
								first_error = value
							end
						end
					end
					value_offset += length
				end
			end
			offset = value_offset
			if skipped > 0 then
				warn(
					`a serdes decode hook threw while decoding {id_to_string(component :: any, world)}! {skipped} value(s) were skipped from this chunk; they re-send next frame: {first_error}`
				)
			end
		end

		if nulled_count > 0 then
			-- unreliable components are never tags (the server refuses them), so nulled entries always apply as data
			-- nulls
			if changed_override then
				for _ = 1, nulled_count do
					local entity = get_client_entity_from_dense(read_id(data, offset))
					offset += id_width
					if entity then
						changed_override(entity)
					end
				end
			else
				for _ = 1, nulled_count do
					local entity = get_client_entity_from_dense(read_id(data, offset))
					offset += id_width
					if entity ~= nil and world:has(entity, component) then
						world:set(entity, component, nil)
					end
				end
			end
		end

		return offset
	end

	-- stream-parses one chunk section at data[section_offset], applying cells as it reads, and returns the
	-- offset just past the section. a section whose component or pair halves don't resolve locally skips whole
	-- via its length prefix (chunks carry no side arrays, so there is no cursor to keep aligned) -- silently,
	-- unlike the reliable path's warn_unmapped: a chunk outrunning the reliable packet that maps its ids is
	-- routine, not a contract violation, and the reliable path reports any id that genuinely never maps.
	local function reconcile_chunk_section(data: buffer, section_offset: number): number
		local _, next_offset, offset, first_id, target_id, ids_count, nulled_count =
			read_chunk_section_header(data, section_offset)

		local component: Id?
		local relation: Id?
		if target_id ~= nil then
			local client_relation = get_client_entity_from_dense(first_id)
			local client_target = get_client_entity_from_dense(target_id)
			if client_relation ~= nil and client_target ~= nil then
				component = pair(client_relation, client_target)
				relation = client_relation
			end
		else
			component = get_client_entity_from_dense(first_id)
		end
		if component == nil then
			return next_offset
		end

		apply_chunk_lists(data, offset, component, relation, ids_count, nulled_count)
		return next_offset
	end

	-- the newest chunk frame reconciled, driving the staleness gate in reconcile_chunk; nil until
	-- the first chunk applies.
	local latest_chunk_frame: number? = nil

	-- applies one received unreliable chunk (see the chunk layout in wire.luau). chunks are self-contained --
	-- every value re-sends every frame -- so this is drop- and reorder-tolerant by construction: a chunk older
	-- than the newest reconciled is dropped whole (wrap-aware, so reordered delivery never snaps values backward --
	-- the next frame's chunks resend everything), chunks of one frame apply in any order (their cells are
	-- disjoint), and ids that don't resolve locally yet -- e.g. a chunk outrunning the reliable packet that
	-- creates its entities -- skip harmlessly until a later frame finds them mapped.
	local function reconcile_chunk(chunk: buffer)
		-- refuse a reliable packet (or a chunk from a different wire format) before reading any other field
		check_chunk_version(chunk)
		local frame = read_chunk_frame(chunk)
		local latest = latest_chunk_frame
		if latest == nil then
			latest_chunk_frame = frame
		else
			-- wrap-aware ordering: an advance in [1, 2^31) is newer, 0 is another chunk of the same frame, anything
			-- else is stale
			local advance = (frame - latest) % 2 ^ 32
			if advance >= 2 ^ 31 then
				return
			end
			if advance ~= 0 then
				latest_chunk_frame = frame
			end
		end

		local offset = chunk_header_width
		local chunk_size = buffer.len(chunk)
		while offset < chunk_size do
			offset = reconcile_chunk_section(chunk, offset)
		end
	end

	-- the packet frame every packet of one generate_packets call shares (see wire.luau); lets a caller group,
	-- dedupe, or order the packets of a single stream. validates the wire format version first (like
	-- reconcile_packet), so a caller grouping packets across channels rejects a mismatched one here rather than
	-- carrying it as far as reconcile. frames wrap (u32) and compare wrap-aware like chunk frames, and the two
	-- counters are independent -- a packet frame is never comparable to a chunk frame.
	local function get_packet_frame(packet: Packet): number
		check_version(packet.data)
		return read_packet_frame(packet.data)
	end

	-- the chunk-side counterpart to get_packet_frame: the chunk frame counter every chunk of one
	-- generate_unreliable_chunks call shares (see the chunk layout in wire.luau), read without reconciling the
	-- chunk. validates the chunk version first (like reconcile_chunk), so a reliable packet -- or a
	-- chunk from an incompatible build -- is refused here rather than misread. exists so a caller capturing
	-- values through changed overrides (an interpolation or snapshot buffer) can timestamp what it captures:
	-- reconcile is synchronous, so read the frame, park it in an upvalue, and reconcile -- a stale chunk drops
	-- whole before any override fires, so the parked frame never stamps stale values. frames wrap (u32), so
	-- compare wrap-aware: b is newer than a exactly when (b - a) % 2^32 is in [1, 2^31).
	local function get_chunk_frame(chunk: buffer): number
		check_chunk_version(chunk)
		return read_chunk_frame(chunk)
	end

	-- applies a received packet (the header through wire.read_packet_header): entity deletes before creates to
	-- support id recycling, then the shared name announcements (so freshly-announced definitions resolve for the
	-- sections that follow), then every section until the end of the buffer, and only then any name retractions --
	-- a retracting packet's sections may still reference the id (the explicit pair removals a named target's
	-- death stages), so its mapping must outlive them. the rare second walk of the names list keeps the
	-- reconcile allocation-free.
	local function reconcile_packet(packet: Packet)
		local data = packet.data
		-- refuse a packet encoded with a different wire format before reading any other field (see check_version /
		-- the layout in wire.luau)
		check_version(data)
		local _, offset, unreplicated_count, replicated_count, names_count = read_packet_header(data)
		for _ = 1, unreplicated_count do
			delete_client_entity(read_id(data, offset))
			offset += id_width
		end
		for _ = 1, replicated_count do
			create_client_entity(read_gen_id(data, offset))
			offset += gen_id_width
		end
		local names_offset = offset
		local has_retractions = false
		for _ = 1, names_count do
			local server_entity_gen, name, next_offset = read_name(data, offset)
			if #name == 0 then
				has_retractions = true
			else
				map_shared_name(server_entity_gen, name)
			end
			offset = next_offset
		end

		local packet_values = packet.values
		local values_index = 0
		local data_size = buffer.len(data)
		while offset < data_size do
			offset, values_index = reconcile_section(data, offset, packet_values, values_index)
		end

		if has_retractions then
			local retract_offset = names_offset
			for _ = 1, names_count do
				local server_entity_gen, name, next_offset = read_name(data, retract_offset)
				if #name == 0 then
					unmap_shared_name(server_entity_gen)
				end
				retract_offset = next_offset
			end
		end
	end

	-- INSTANTIATE

	return {
		-- packets & chunks
		reconcile_packet = reconcile_packet,
		reconcile_chunk = reconcile_chunk,
		get_packet_frame = get_packet_frame,
		get_chunk_frame = get_chunk_frame,

		-- entity mapping
		get_client_entity = get_client_entity,
		set_client_entity = set_client_entity_public,
		get_server_entity = get_server_entity,

		-- overrides
		set_changed_override = set_changed_override,
		set_removed_override = set_removed_override,
		get_changed_override = get_changed_override,
		get_removed_override = get_removed_override,

		-- diagnostics
		set_warn_hook = reporter.set_warn_hook,

		-- components
		Imported = Imported,
		Serdes = Serdes,
	}
end

export type ClientInstance = typeof(create_client(nil :: any, nil :: any))

-- the memoized accessor (duplecs.client), mirroring the server half's: the first call on a world constructs
-- the instance and stores it on the world's shared record (see shared.luau), every later call returns that
-- same instance, and the typeof above hands callers the full instance type past the record's unknown-typed
-- slot. a constructor error simply propagates with nothing memoized: a programming bug to stop and fix, not
-- a state to recover from.
return function(world: World): ClientInstance
	local shared_record = get_shared(world)
	local instance = shared_record.client
	if instance ~= nil then
		return instance :: ClientInstance
	end
	local created = create_client(world, shared_record)
	shared_record.client = created
	return created
end
