--!strict
--!native
--!optimize 2

-- the client half of duplecs: server/client entity mapping, reconciliation overrides, and packet
-- reconciliation. one memoized instance per world (see the accessor at the bottom).

-- note: in warn/error strings, `$` prefixes verified-live entity ids and `?` unverifiable ones -- see
-- diagnostics.luau, which owns the convention and the [duplecs] prefix every message carries.

local jecs = require("../roblox_packages/jecs")
local pair = jecs.pair

local types = require("./types")
local wire = require("./wire")
local inspect = require("./inspect")
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
type Serdes<T = any> = types.Serdes<T>

export type ChangedOverride<T = any> = (Entity, T) -> ()
export type RemovedOverride = (Entity) -> ()

local function create_client(world: World, shared_record: get_shared.Record)
	-- DIAGNOSTICS

	-- shadows the global warn so every warning here carries the [duplecs] prefix and rides the injectable
	-- set_warn_hook (see diagnostics.luau)
	local reporter = diagnostics.create_reporter()
	local warn = reporter.warn

	-- COMPONENTS

	-- the client-relevant slice of the world's shared component set (see shared.luau)
	local Imported = shared_record.components.Imported

	-- GENERAL FUNCTIONS

	-- retyped views of two jecs id-math originals: they take branded ids and plain numbers alike and return the
	-- plain-number domain their call sites compare in. neither sits on the per-cell reconcile loops, so they
	-- call the originals rather than mirroring the id math the way server.luau's hot paths do.
	local dense = (jecs.ECS_ID :: any) :: (entity_gen: unknown) -> number
	local ECS_PAIR_SECOND = (jecs.ECS_PAIR_SECOND :: any) :: (id: unknown) -> number

	-- the component-record flag bit jecs's world:delete reads to decide whether an id's holders die with it
	-- (see delete_client_entities)
	local ECS_ID_DELETE = jecs.ECS_ID_DELETE

	-- jecs never replaces this container on a live world (unlike world.archetypes, which world:cleanup
	-- rebuilds), so the record walks share one fetch
	local component_index = world.component_index

	-- calls visit(entities, id) once per pair id aimed at target in each non-empty archetype holding one, with
	-- the archetype's entities. pairs sharing a *target* are not contiguous in types (pair ids pack
	-- relation-major, and types is sorted by id), so each archetype's types scan, with the record's count as
	-- an early exit. the walk drives off the pair(Wildcard, target) record directly, re-reading
	-- world.archetypes per call since world:cleanup rebuilds it. visit must not move entities between
	-- archetypes -- callers collect under the walk and apply afterward.
	local function each_pair_targeting(target: Entity, visit: (entities: { Entity }, id: Id) -> ())
		local idr_target = component_index[pair(jecs.Wildcard, target)]
		if idr_target == nil then
			return
		end
		local target_dense = dense(target)
		local world_archetypes = world.archetypes
		local target_counts = idr_target.counts
		for archetype_id in idr_target.records do
			local archetype = world_archetypes[archetype_id]
			local entities = archetype.entities
			if #entities == 0 then
				continue
			end
			local remaining = target_counts[archetype_id]
			for _, id in archetype.types do
				if jecs.IS_PAIR(id) and ECS_PAIR_SECOND(id) == target_dense then
					visit(entities, id)
					remaining -= 1
					if remaining == 0 then
						break
					end
				end
			end
		end
	end

	-- ENTITY MAPPING

	-- both maps key by *dense* ids -- client_entity_map by the dense half of the server id (all a section wire
	-- id carries), server_entity_map by the dense half of its own client entity -- while the values keep full
	-- gen-qualified ids: the creation and names lists are where a client learns the server generation, which
	-- get_server_entity must expose. dense keys are deliberate: churn respawns recycled dense ids under bumped
	-- generations, and a luau table churning fresh keys rehashes O(live) per insert at power-of-two live counts,
	-- while recycled dense keys revive their slot in place. server-dense keys stay unambiguous because the
	-- server never holds two live entities on one dense id and reconcile applies deletes before creates;
	-- client-dense keys because every mapping-ending path clears the entry (the unreplicated list via
	-- delete_client_entities, the Imported removed hook behind everything else). what dense keys give up is
	-- stale-reference rejection by key identity, so reads split by caller: internal reads index directly with
	-- entities known live (archetype walks, contains-guarded lookups, or the removed hook's mid-teardown entity,
	-- whose dense slot cannot have recycled yet), while the public get_server_entity guards with the
	-- generation-aware world:contains.
	local client_entity_map = {} :: { [number]: Entity }
	local server_entity_map = {} :: { [number]: number }

	-- dense server ids whose mapping a shared-name announcement established: a name retraction may only end
	-- these (a creation-established mapping ends through the unreplicated list, a manual one belongs to the
	-- caller). cleared when the mapping ends or a creation adopts it.
	local name_mapped = {} :: { [number]: true }

	-- dense server ids already reported for arriving unmapped (see warn_unmapped): one warning per id per
	-- unmapped stretch rather than one per section, cleared when the id maps so a later regression warns anew.
	local unmapped_warned = {} :: { [number]: true }

	-- wire-facing: server_entity is a dense id straight off the wire
	local function get_client_entity_from_dense(server_entity: number): Entity?
		return client_entity_map[server_entity]
	end

	local function set_client_entity(server_entity_gen: number, client_entity: Entity)
		local dense_id = dense(server_entity_gen)
		client_entity_map[dense_id] = client_entity
		server_entity_map[dense(client_entity)] = server_entity_gen
		unmapped_warned[dense_id] = nil
		world:add(client_entity, Imported)
	end

	-- world:contains is generation-aware, so a caller's dead reference resolves to nil even when its dense slot
	-- already holds a next tenant's mapping (see the maps above)
	local function get_server_entity(client_entity: Entity): number?
		if world:contains(client_entity) ~= true then
			return nil
		end
		return server_entity_map[dense(client_entity)]
	end

	-- unresolvable ids skip by design, but the server only references ids the client was given the means to
	-- map -- pair cells never ship to a client lacking the target, and definitions are the caller's mapping
	-- responsibility -- so an unmapped id here means the matching client entity wasn't named or mapped before
	-- the server first referenced it. the holes are permanent (deltas are exactly-once), so silence would hide
	-- the bug indefinitely. the unreliable path stays silent: chunks legitimately outrun the reliable packet
	-- that maps their ids (see reconcile_chunk).
	local function warn_unmapped(dense_id: number, role: string)
		if unmapped_warned[dense_id] ~= nil then
			return
		end
		unmapped_warned[dense_id] = true
		warn(
			`a received section's {role} (server {id_to_string(dense_id)}) has no client mapping! its cells were skipped -- map the id before the server first references it: give the matching client entity the shared jecs.Name, or map it with set_client_entity at startup`
		)
	end

	-- the mapping-teardown sweep, forward-declared for the mapping enders below and defined past the overrides
	-- (whose removal dispatch it shares).
	local sweep_imported_cells: (client_target: Entity) -> ()

	-- a creation for an already-mapped server id adopts the mapping silently -- pre-mapping an id the server is
	-- about to create is the prediction flow set_client_entity exists for. the creation is authoritative for the
	-- generation, and the adopted mapping now ends through the entity's deletion, never a name retraction.
	-- exception: a *name-established* mapping holding a different generation is a stale older tenant of the
	-- dense id (the named target died and its id recycled into a Replicated tenant within one interval);
	-- adopting would hand the client's own named entity to the new tenant, so the stale mapping is torn down
	-- (cells swept) and a fresh entity minted. a matching generation keeps adopting -- the
	-- named-target-turned-Replicated flow. a mapping pointing at a dead client entity is replaced like it never
	-- existed.
	local function create_client_entity(server_entity_gen: number)
		local dense_id = dense(server_entity_gen)
		local existing_entity = client_entity_map[dense_id]
		if existing_entity ~= nil and world:contains(existing_entity) then
			local existing_dense = dense(existing_entity)
			if name_mapped[dense_id] == nil or server_entity_map[existing_dense] == server_entity_gen then
				server_entity_map[existing_dense] = server_entity_gen
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

	-- resolves through the dense half, but the caller's generation must match the mapping's: a stale generation
	-- names another tenant of the dense slot, so it resolves to nil rather than a false positive.
	-- get_server_entity returns the full gen-qualified id, so a round-tripped id matches exactly.
	local function get_client_entity(server_entity: number): Entity?
		local client_entity = client_entity_map[dense(server_entity)]
		if client_entity ~= nil and server_entity_map[dense(client_entity)] == server_entity then
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
		server_entity_map[dense(client_entity)] = nil
		local dense_id = dense(server_entity)
		-- the dense slot may already belong to a newer mapping that replaced this one; only the mapping's own entry
		-- (and provenance) end with it
		if client_entity_map[dense_id] == client_entity then
			client_entity_map[dense_id] = nil
			name_mapped[dense_id] = nil
		end
	end

	-- jecs 0.11.0's world:delete walks the deleted entity's pair(Wildcard, entity) archetypes up to a count taken
	-- before its cascade starts, so a subject that the cascade's own nested deletions move into a freshly
	-- created archetype -- e.g. a deleted target's ChildOf child taking the subject's pair to the child with it
	-- -- is never visited and keeps its pair to the deleted entity. the server ships no removal for a pair whose
	-- target a client drops (the local deletion removes it), so the pair would linger, and -- pairs packing only
	-- dense halves -- read as aimed at whatever entity next reuses the id. this removes each such leftover from
	-- its holder, as the cascade should have: the deletion walk detached or queued every dependent jecs would
	-- delete beforehand, so only Remove-policy pairs can remain. leftovers are collected before any
	-- is removed, since removing moves holders between archetypes under the walk, and nothing is touched while
	-- the dense id has a live tenant (one of the batch's removed hooks may have minted one), whose pairs are
	-- genuine.
	local function remove_stale_pairs(deleted: Entity)
		local target_dense = dense(deleted)
		if jecs.entity_index_get_alive(world.entity_index :: any, target_dense) ~= nil then
			return
		end
		local holders: { Entity } = {}
		local pair_ids: { Id } = {}
		local count = 0
		each_pair_targeting(deleted, function(entities: { Entity }, id: Id)
			for _, holder in entities do
				count += 1
				holders[count] = holder
				pair_ids[count] = id
			end
		end)
		for i = 1, count do
			world:remove(holders[i], pair_ids[i])
		end
	end

	-- applies a packet's deletion list (`count` dense server ids at data[offset]) as one batch, returning the
	-- offset past it. deleting must not cascade (OnDeleteTarget, Delete) into imported entities the packet
	-- doesn't delete, which might still exist on the server with Replicated dependents: those are detached
	-- instead. pairs referencing a deleted entity that exist only locally are *not* renewed if the entity gets
	-- Replicated again.
	--
	-- the batch semantics: every listed entity's mapping ends first, before anything is classified or deleted,
	-- so the walk below reads a dependent the same packet deletes as local -- already queued, so neither walked
	-- again nor detached moments before its own deletion -- and an imported dependent is exactly one the packet
	-- leaves mapped. it also means hooks fired by any of the batch's deletions see every entity the packet
	-- deletes as unmapped, the way an entity always was inside its own deletion's hooks.
	local function delete_client_entities(data: buffer, offset: number, count: number): number
		local queue = table.create(count) :: { Entity }
		local visited = {} :: { [Entity]: true }
		local queued = 0
		for _ = 1, count do
			local server_entity = read_id(data, offset)
			offset += id_width
			local client_entity = client_entity_map[server_entity]
			if client_entity ~= nil then
				remove_references(client_entity, server_entity)
				-- visited dedupes a client entity mapped under two listed server ids; the liveness check is
				-- defensive (the Imported removed hook ends a deleted entity's mapping), keeping a dead entity's
				-- recycled dense slot out of the walk's pair lookups
				if visited[client_entity] == nil and world:contains(client_entity) then
					visited[client_entity] = true
					queued += 1
					queue[queued] = client_entity
				end
			end
		end
		if queued == 0 then
			return offset
		end

		-- imported dependents to detach, as (holder, id) rows: collected by the walk below and removed only once it
		-- finishes, since removing moves holders between archetypes under the record walks
		local detach_holders = {} :: { Entity }
		local detach_ids = {} :: { Id }
		local detached = 0

		-- claims every entity of one archetype that jecs would delete along with `id`: an imported one is
		-- collected for detaching from it, a local one queued; visited keeps cyclical dependencies from
		-- re-queueing.
		local function claim(entities: { Entity }, id: Id)
			for _, holder in entities do
				if get_server_entity(holder) then
					detached += 1
					detach_holders[detached] = holder
					detach_ids[detached] = id
				elseif visited[holder] == nil then
					visited[holder] = true
					queued += 1
					queue[queued] = holder
				end
			end
		end

		-- the target role's visitor: jecs deletes a holder when any one of its pairs targeting the entity carries
		-- the bit
		local function claim_if_deleting(entities: { Entity }, id: Id)
			if bit32.btest(component_index[id].flags, ECS_ID_DELETE) then
				claim(entities, id)
			end
		end

		-- walks the local deletion closure without deleting yet, mirroring the three ways world:delete cascades:
		-- into holders of the entity as a component, of a pair targeting it, and of a pair using it as the
		-- relation. jecs decides each by the delete bit on the id's component record -- set at the record's
		-- creation from (OnDelete, Delete) on the component or relation, and for a pair also from
		-- (OnDeleteTarget, Delete) on the relation -- never by the policy pairs as they stand now, so this reads
		-- the same bit. an entity no id references has no records at all, so its walk costs three lookups -- the
		-- common case for a group's members.
		local world_archetypes = world.archetypes
		local index = 0
		while index < queued do
			index += 1
			local entity = queue[index]

			local idr_unpaired = component_index[entity]
			if idr_unpaired ~= nil and bit32.btest(idr_unpaired.flags, ECS_ID_DELETE) then
				for archetype_id in idr_unpaired.records do
					claim(world_archetypes[archetype_id].entities, entity)
				end
			end

			each_pair_targeting(entity, claim_if_deleting)

			-- the relation role reads the bit off the (entity, Wildcard) record alone, as jecs does, and detaches an
			-- imported holder from every pair of the relation it carries: same-relation pairs sit contiguously in
			-- types, so the record's records/counts give each archetype's exact slice
			local idr_relation = component_index[pair(entity, jecs.Wildcard)]
			if idr_relation ~= nil and bit32.btest(idr_relation.flags, ECS_ID_DELETE) then
				local relation_counts = idr_relation.counts
				for archetype_id, slice_start in idr_relation.records do
					local archetype = world_archetypes[archetype_id]
					local entities = archetype.entities
					if #entities == 0 then
						continue
					end
					local archetype_types = archetype.types
					for i = slice_start, slice_start + relation_counts[archetype_id] - 1 do
						claim(entities, archetype_types[i])
					end
				end
			end
		end

		for i = 1, detached do
			world:remove(detach_holders[i], detach_ids[i])
		end

		-- with every imported dependent detached, deletion order is free; an entity an earlier deletion already
		-- cascade-deleted is skipped.
		for i = 1, queued do
			local entity = queue[i]
			if world:contains(entity) then
				world:delete(entity)
			end
		end

		-- then finish what jecs 0.11.0's cascade can leave undone (see remove_stale_pairs); a deleted entity
		-- nothing still targets has no pair(Wildcard, entity) record left, so the common case is one lookup
		for i = 1, queued do
			local entity = queue[i]
			if component_index[pair(jecs.Wildcard, entity)] ~= nil then
				remove_stale_pairs(entity)
			end
		end
		return offset
	end

	local function on_imported_added(client_entity: Entity, id: Id)
		if id ~= Imported then
			world:remove(client_entity, id)
			fail(`Imported is not meant to be paired! ({id_to_string(client_entity, world)})`)
		end
		if not get_server_entity(client_entity) then
			world:remove(client_entity, Imported)
			fail(`Imported cannot be added to entities with no server mapping! ({id_to_string(client_entity, world)})`)
		end
	end

	hooks.added(world, Imported, on_imported_added)

	hooks.removed(world, Imported, function(client_entity: Entity, id: Id)
		-- a pair using Imported as its relation never owns a mapping
		if id ~= Imported then
			return
		end
		-- covers deletions outside reconcile's deletion batch (local ones and their cascades), which ends its own
		-- mappings up front. the client should avoid adding (OnDeleteTarget, Delete) to imported entities; the
		-- resulting mismatch is *not* auto-corrected. the raw read (not get_server_entity) is deliberate: this can
		-- fire inside world:delete's teardown, where the liveness guard must not decide anything (the pinned jecs
		-- keeps the dying entity alive-indexed until its removed hooks have run, but that isn't contractual); the
		-- dense slot cannot recycle before the deletion completes, so the read is unambiguous.
		local server_entity = server_entity_map[dense(client_entity)]
		if server_entity then
			remove_references(client_entity, server_entity)
		end
	end)

	-- construction catch-up: the shared set can predate this instance, so entities may already carry Imported --
	-- always a misuse, since no mapping existed before construction. the guard replays over pre-collected
	-- holders (its remove would invalidate a live world:each walk).
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

	-- client entities by jecs.Name, kept live by the hooks below (seeded at construction) so announced names
	-- resolve without scanning; entity_names lets a rename clear its old entry. shared names must be unique in
	-- this world; on a collision the latest indexed entity wins.
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
		if id == jecs.Name then
			index_name(client_entity, name)
		end
	end)

	hooks.changed(world, jecs.Name, function(client_entity: Entity, id: Id, name: unknown)
		if id == jecs.Name then
			index_name(client_entity, name)
		end
	end)

	hooks.removed(world, jecs.Name, function(client_entity: Entity, id: Id)
		if id == jecs.Name then
			deindex_name(client_entity)
		end
	end)

	for client_entity in world:each(jecs.Name) do
		index_name(client_entity, world:get(client_entity, jecs.Name))
	end

	-- maps one announced shared name to the client entity carrying the same jecs.Name. a server id already
	-- mapped with the announced generation is left alone (a manual mapping wins), but one holding a *different*
	-- generation is an older tenant of the dense id: the announcement is authoritative, so the stale mapping
	-- ends and its cells are swept before the new tenant's sections apply -- this is also what resolves a
	-- same-frame die-and-recycle, where the server drops the old tenant's tainted removals and the sweep is the
	-- only thing removing its cells. a name with no live client entity is skipped silently: announcements ride
	-- to every client regardless of privacy, so a client legitimately lacks entities for definitions whose data
	-- never reaches it; data arriving for a still-unmapped id is what warn_unmapped reports. a client entity
	-- already mapped to a different server id warns -- a naming collision worth surfacing.
	local function map_shared_name(server_entity_gen: number, name: string)
		local dense_id = dense(server_entity_gen)
		local existing_entity = client_entity_map[dense_id]
		if existing_entity ~= nil and world:contains(existing_entity) then
			if server_entity_map[dense(existing_entity)] == server_entity_gen then
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

	-- ends the mapping a retracted announcement established, so it cannot misbind the dense id's next tenant.
	-- only name-established mappings still holding the retracted generation end here: a creation in the same
	-- packet has already adopted the mapping out of name provenance, and a newer tenant's mapping is never for
	-- the retracted announcement. ending it also sweeps the entity's cells: retractions apply after the
	-- sections, so a plain death's explicit removals have already applied and the sweep finds nothing, but when
	-- the dense id recycled into an unreplicable (or unnamed tracked) tenant within one interval the server
	-- dropped the old tenant's tainted removals, so this sweep is their only cleanup -- and it also clears
	-- whatever an unnamed tracked tenant's sections misapplied through the still-live mapping moments earlier.
	local function unmap_shared_name(server_entity_gen: number)
		local dense_id = dense(server_entity_gen)
		if name_mapped[dense_id] == nil then
			return
		end
		local client_entity = client_entity_map[dense_id]
		if client_entity ~= nil and server_entity_map[dense(client_entity)] == server_entity_gen then
			-- the Imported removed hook tears the mapping down; the client entity itself belongs to this world
			-- and stays
			world:remove(client_entity, Imported)
			sweep_imported_cells(client_entity)
		end
	end

	-- SERDES

	-- the per-world serdes store (see serdes.luau): registrations validate at their own call site or from the
	-- world's first duplecs contact, so this half needs no serdes catch-up
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
	-- halves -- pairs targeting it with an imported relation, pairs using it as the relation with an imported
	-- target, and unpaired cells using it as the component -- dispatching each removal like apply_lists' removed
	-- entries. this is the out-of-band cleanup for cells referencing a name-mapped entity the server withdrew:
	-- the entity is client-owned and never deleted by reconciliation, and the server drops the removals of a
	-- dense id that retired one tenant and re-bound another within one interval (they would misresolve to the
	-- new tenant on the wire -- see resolve_visibility_cells in server.luau), so the client owns them wherever a
	-- mapping ends without its entity dying: a retraction unmap, a superseding announcement, and a creation's
	-- stale-name teardown. client-created cells whose other halves are imported are swept too (documented in
	-- docs/spec.md). deliberately *not* hooked on the Imported removal: that fires mid-archetype-transition, and
	-- a genuine deletion's pairs are removed by jecs with the dying entity. removals are collected before any is
	-- applied, since applying moves subjects between archetypes under the walk.
	function sweep_imported_cells(client_target: Entity)
		local subjects: { Entity } = {}
		local cell_ids: { Id } = {}
		local count = 0

		-- the walks drive off the ids' component records directly (an uncached world:query():archetypes() rebuilds
		-- exactly that list, and world:each pays a closure plus a call per subject); world.archetypes is re-read
		-- per sweep since world:cleanup rebuilds it.
		local world_archetypes = world.archetypes

		-- pairs targeting the entity
		each_pair_targeting(client_target, function(entities: { Entity }, id: Id)
			local relation = jecs.pair_first(world, id)
			if server_entity_map[dense(relation)] ~= nil then
				for _, subject in entities do
					if server_entity_map[dense(subject)] ~= nil then
						count += 1
						subjects[count] = subject
						cell_ids[count] = id
					end
				end
			end
		end)

		-- pairs using the entity as the relation: same-relation pairs sit contiguously in types, so the record's
		-- records/counts give each archetype's exact slice (see the server's each_target). the entity's own mapping
		-- ended just before this sweep, so the target check must allow the entity itself -- which also collects a
		-- self-targeting pair exactly once, the walk above having skipped it for its no-longer-imported relation.
		local idr_relation = component_index[pair(client_target, jecs.Wildcard)]
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
					-- cast: jecs.pair_second's return is Component<unknown>, unrelated to Entity either way
					local pair_target: Entity = jecs.pair_second(world, id) :: any
					if pair_target == client_target or server_entity_map[dense(pair_target)] ~= nil then
						for _, subject in entities do
							if server_entity_map[dense(subject)] ~= nil then
								count += 1
								subjects[count] = subject
								cell_ids[count] = id
							end
						end
					end
				end
			end
		end

		-- unpaired cells using the entity as the component
		local idr_unpaired = component_index[client_target]
		if idr_unpaired ~= nil then
			for archetype_id in idr_unpaired.records do
				for _, subject in world_archetypes[archetype_id].entities do
					if server_entity_map[dense(subject)] ~= nil then
						count += 1
						subjects[count] = subject
						cell_ids[count] = client_target
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

	-- the fused parse-and-apply loop for one list of serdes-encoded values at data[offset] -- `count` ids with
	-- their values following the id list. each value decodes from a fresh value-sized buffer, its length read
	-- off the u16 prefix unless the registration declares a static size. unmapped entities hop the value without
	-- decoding, as do entities guarded excludes: the unreliable path's rule that a value applies only where the
	-- entity currently has the component (see apply_chunk_lists), never set alongside an override, which owns
	-- application. decode runs under pcall: the framing gives every value's length before it decodes, so a
	-- throwing hook skips exactly its own value and the stream stays aligned, where a mid-reconcile unwind would
	-- lose the rest of the packet unrecoverably (deltas are exactly-once). returns the offset past the values,
	-- the skipped count, and the first error; the caller owns the warning.
	local function apply_values(
		data: buffer,
		offset: number,
		component: Id,
		count: number,
		serdes: Serdes,
		changed_override: ChangedOverride?,
		guarded: boolean
	): (number, number, any)
		local decode = serdes.decode
		local static: number? = serdes.size
		local value_offset = offset + count * id_width
		local skipped = 0
		local first_error: any = nil
		for _ = 1, count do
			local entity = get_client_entity_from_dense(read_id(data, offset))
			offset += id_width
			local length: number
			if static ~= nil then
				length = static
			else
				length = buffer.readu16(data, value_offset)
				value_offset += 2
			end
			if entity ~= nil and (not guarded or world:has(entity, component)) then
				local encoded = buffer.create(length)
				buffer.copy(encoded, 0, data, value_offset, length)
				local ok, value = pcall(decode, encoded)
				if not ok then
					skipped += 1
					if first_error == nil then
						first_error = value
					end
				elseif changed_override then
					changed_override(entity, value)
				else
					world:set(entity, component, value)
				end
			end
			value_offset += length
		end
		return value_offset, skipped, first_error
	end

	-- the nulled-list counterpart: `count` ids whose cells are present but hold no value. with no override a tag
	-- is added and a data component set to nil (world:add is a no-op on a present component and would leave a
	-- stale value). guarded as in apply_values.
	local function apply_nulled(
		data: buffer,
		offset: number,
		component: Id,
		count: number,
		changed_override: ChangedOverride?,
		guarded: boolean
	): number
		-- resolved once per list: tag-ness is the same for every entry
		local is_tag = changed_override == nil and jecs.is_tag(world, component)
		for _ = 1, count do
			local entity = get_client_entity_from_dense(read_id(data, offset))
			offset += id_width
			if entity ~= nil and (not guarded or world:has(entity, component)) then
				if changed_override then
					changed_override(entity)
				elseif is_tag then
					world:add(entity, component)
				else
					world:set(entity, component, nil)
				end
			end
		end
		return offset
	end

	-- applies one section's -- or one grouped run's -- lists at data[offset]: ids with inline or side-array
	-- values, then nulled, then removed. side_base is the caller's cursor into the side array (0 for a plain
	-- section), and relation_changed / relation_removed the relation-level override fallbacks, resolved once per
	-- section rather than per run. returns the offset past the lists.
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
						`received serialized values for {id_to_string(component, world)} but no serdes hooks are assigned!`
					)
				end
				-- cast: fail never returns, but the solver doesn't treat user functions as diverging. one warning per
				-- list carries the first error
				local values_end, skipped, first_error =
					apply_values(data, offset, component, ids_count, serdes :: Serdes, changed_override, false)
				offset = values_end
				if skipped > 0 then
					warn(
						`a serdes decode hook threw while decoding {id_to_string(component, world)}! {skipped} value(s) were skipped and their cells will not update until they next change server-side: {first_error}`
					)
				end
			else
				local side = side_values :: { any }
				for i = 1, ids_count do
					local entity = get_client_entity_from_dense(read_id(data, offset))
					offset += id_width
					if entity then
						if changed_override then
							changed_override(entity, side[side_base + i])
						else
							world:set(entity, component, side[side_base + i])
						end
					end
				end
			end
		end

		if nulled_count > 0 then
			offset = apply_nulled(data, offset, component, nulled_count, changed_override, false)
		end

		if removed_count > 0 then
			local removed_override = removed_overrides[component]
			if removed_override == nil then
				removed_override = relation_removed
			end
			for _ = 1, removed_count do
				local entity = get_client_entity_from_dense(read_id(data, offset))
				offset += id_width
				if entity then
					if removed_override then
						removed_override(entity)
					else
						world:remove(entity, component)
					end
				end
			end
		end

		return offset
	end

	-- stream-parses one section at data[section_offset], applying cells as it reads, and returns the offset past
	-- the section plus the advanced packet-values cursor. sections whose component or pair halves don't resolve
	-- locally are skipped -- whole via the length prefix, or run by run for a grouped section's unmapped
	-- targets -- with a once-per-id warning, but skipped hookless lists still consume their side-array entries
	-- to keep the cursor aligned.
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

	-- applies one chunk section's lists at data[offset]: ids with serdes-encoded values, then nulled. the
	-- unreliable stream only *updates* cells -- membership is authoritative on the reliable path -- so with no
	-- override a value applies only where the entity currently has the component: a chunk arriving after a
	-- cell's reliable removal (inevitable under drops and reordering) must not resurrect it with a value the
	-- server would never correct, the cell no longer being streamed. an override is invoked unguarded; it owns
	-- application. a throwing decode is contained under this path's own warning: a poisoned value would
	-- otherwise error every chunk carrying it, and chunks self-heal frame to frame, so the skipped cell is only
	-- stale.
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
		local guarded = changed_override == nil

		if ids_count > 0 then
			local serdes = resolve_serdes(component, relation)
			if serdes == nil then
				fail(
					`received serialized values for {id_to_string(component, world)} but no serdes hooks are assigned!`
				)
			end
			-- cast: fail never returns, but the solver doesn't treat user functions as diverging
			local values_end, skipped, first_error =
				apply_values(data, offset, component, ids_count, serdes :: Serdes, changed_override, guarded)
			offset = values_end
			if skipped > 0 then
				warn(
					`a serdes decode hook threw while decoding {id_to_string(component, world)}! {skipped} value(s) were skipped from this chunk; they re-send next frame: {first_error}`
				)
			end
		end

		if nulled_count > 0 then
			-- unreliable cells on the wire are never tags (the server streams only value-carrying cells), so these
			-- always apply as data nulls
			offset = apply_nulled(data, offset, component, nulled_count, changed_override, guarded)
		end

		return offset
	end

	-- stream-parses one chunk section, applying cells as it reads, and returns the offset past it. unresolvable
	-- components or pair halves skip the section whole via its length prefix (chunks carry no side arrays) --
	-- silently, unlike warn_unmapped: a chunk outrunning the reliable packet that maps its ids is routine, and
	-- the reliable path reports any id that never maps.
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

	-- applies one unreliable chunk (see wire.luau). chunks are self-contained -- every value re-sends every
	-- frame -- so this is drop- and reorder-tolerant: a chunk older than the newest reconciled drops whole
	-- (wrap-aware, so reordered delivery never snaps values backward), chunks of one frame apply in any order
	-- (their cells are disjoint), and ids that don't resolve yet skip until a later frame finds them mapped.
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

	-- the packet frame every packet of one generate_packets call shares (see wire.luau), for grouping, deduping,
	-- or ordering the packets of one stream. validates the wire version first, so a mismatched packet is
	-- rejected here rather than carried as far as reconcile. frames wrap (u32) and compare wrap-aware like chunk
	-- frames; the two counters are independent, never comparable.
	local function get_packet_frame(packet: Packet): number
		check_version(packet.data)
		return read_packet_frame(packet.data)
	end

	-- the chunk counterpart, read without reconciling; validates the chunk version first, so a reliable packet
	-- is refused rather than misread. exists so a caller capturing values through changed overrides (an
	-- interpolation or snapshot buffer) can timestamp them: reconcile is synchronous, so read the frame, park
	-- it, and reconcile -- a stale chunk drops whole before any override fires, so the parked frame never stamps
	-- stale values. compare wrap-aware: b is newer than a exactly when (b - a) % 2^32 is in [1, 2^31).
	local function get_chunk_frame(chunk: buffer): number
		check_chunk_version(chunk)
		return read_chunk_frame(chunk)
	end

	-- applies a received packet: entity deletes before creates (id recycling), then name announcements (so
	-- freshly-announced definitions resolve for the sections that follow), then every section to the end of the
	-- buffer, and only then name retractions -- a retracting packet's sections may still reference the id (the
	-- explicit pair removals a named target's death stages), so its mapping must outlive them. the rare second
	-- walk of the names list keeps reconcile allocation-free.
	local function reconcile_packet(packet: Packet)
		local data = packet.data
		-- refuse a packet encoded with a different wire format before reading any other field (see check_version /
		-- the layout in wire.luau)
		check_version(data)
		local _, offset, unreplicated_count, replicated_count, names_count = read_packet_header(data)
		if unreplicated_count > 0 then
			offset = delete_client_entities(data, offset, unreplicated_count)
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

	-- INSPECTION

	-- the debug inspector's view of this world (see inspect.luau): wire ids resolve through this client's own
	-- mapping
	local describe_packet, describe_chunk =
		inspect.create_client_inspector(world, resolve_serdes, client_entity_map, get_client_entity)

	-- INSTANTIATE

	return {
		-- packets & chunks
		reconcile_packet = reconcile_packet,
		reconcile_chunk = reconcile_chunk,
		get_packet_frame = get_packet_frame,
		get_chunk_frame = get_chunk_frame,
		describe_packet = describe_packet,
		describe_chunk = describe_chunk,

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

-- the memoized accessor (duplecs.client): the first call on a world constructs the instance and stores it on
-- the world's shared record; the typeof above hands callers the full instance type past the record's
-- unknown-typed slot. a constructor error propagates with nothing memoized.
return function(world: World): ClientInstance
	local shared_record = get_shared.get_record(world)
	local instance = shared_record.client
	if instance ~= nil then
		return instance :: ClientInstance
	end
	local created = create_client(world, shared_record)
	shared_record.client = created
	return created
end
