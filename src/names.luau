--!strict
--!native
--!optimize 2

-- the server's shared-name store, one per instance (constructed by create_server): the announced set, the
-- transitions staged against it, and the two refusals announcing can warn on. server.luau owns *which* ids are
-- announcement-relevant -- its tracking, Replicated, and jecs.Name hooks decide that and call in -- while this
-- module owns the store itself and the drains the packet passes read out of it. the warn it takes is the
-- instance's reporter's (diagnostics.create_reporter), so its refusals ride the same injectable hook as every
-- other warning in the half.
--
-- shared names: named ids the client maps automatically. tracked component definitions and named
-- (unreplicated) pair targets announce their jecs.Name on the wire -- (id, name) entries in packet headers --
-- so a client world defining the same names resolves them without set_client_entity. keyed by dense id,
-- matching server.luau's tracked_pairs_by_target (whose removal paths may run with the entity already dead),
-- with ids carrying the gen-qualified id the wire needs. staged collects the changes since the last drain, one
-- state per dense id: true means announce the id's current name, a number is a *retraction* carrying the
-- withdrawn gen-qualified id -- clients must end the mapping the announcement established before the dense id
-- can recycle into a new tenant they would misbind (the client's provenance and generation checks make a
-- retraction reaching a client whose mapping outlived it -- adopted by a creation, or superseded by a newer
-- announcement -- a no-op). the drain sends the staged states to every allocated client (names are schema,
-- never gated by visibility), with retractions riding as empty-name entries; full packets carry the whole live
-- set, which never includes retractions. names longer than 255 bytes don't fit the wire's u8 length, and empty
-- names would read as retractions; both are refused with a warning.

local jecs = require("../roblox_packages/jecs")

local types = require("./types")
local diagnostics = require("./diagnostics")

local id_to_string = diagnostics.id_to_string

type World = types.World
type Entity = types.Entity

-- the generation-stripping jecs.ECS_ID, under the name its call sites use. every path here runs at schema-edit
-- rate or once per packet call, so it calls the jecs original rather than mirroring the id math the way
-- server.luau's hot paths do. like the mirrors, it takes branded ids and plain numbers alike.
local dense = (jecs.ECS_ID :: any) :: (entity_gen: unknown) -> number

return function(world: World, warn: (message: string) -> ())
	-- the announced set, keyed by dense id: names holds each announced name, ids the gen-qualified id it was
	-- announced under, and staged the transitions since the last drain (see the module comment for the states).
	local names = {} :: { [number]: string }
	local ids = {} :: { [number]: Entity }
	local staged = {} :: { [number]: true | Entity }

	local function announce(entity: Entity)
		local name = world:get(entity, jecs.Name)
		if type(name) ~= "string" then
			return
		end
		if #name == 0 then
			warn(`shared names must not be empty! ({id_to_string(entity, world)})`)
			return
		end
		if #name > 255 then
			warn(`shared names must be at most 255 bytes! ({id_to_string(entity, world)})`)
			return
		end
		local dense_id = dense(entity)
		if ids[dense_id] == entity and names[dense_id] == name then
			return
		end
		ids[dense_id] = entity
		names[dense_id] = name
		staged[dense_id] = true
	end

	-- a re-announcement staged later this frame overwrites the retraction: the dense id recycled (or turned
	-- relevant again) within one interval, and the announcement alone carries enough for clients to supersede
	-- their stale mapping (see map_shared_name's generation check).
	local function retract(id: number)
		-- the stores key by dense id; taking the dense half here keeps a gen-qualified caller safe
		local dense_id = dense(id)
		local entity_gen = ids[dense_id]
		if entity_gen == nil then
			return
		end
		ids[dense_id] = nil
		names[dense_id] = nil
		staged[dense_id] = entity_gen
	end

	-- the gen-qualified id currently announced under a dense id, nil when nothing is: what the callers whose
	-- retraction depends on *which* tenant holds the announcement test against.
	local function announced_id(dense_id: number): Entity?
		return ids[dense_id]
	end

	local function has_live(): boolean
		return next(names) ~= nil
	end

	-- the whole live set as (gen-qualified id -> name), for a joiner's full packet
	local function collect_live(collected: { [number]: string })
		for dense_id, name in names do
			collected[ids[dense_id] :: any] = name
		end
	end

	local function has_staged(): boolean
		return next(staged) ~= nil
	end

	-- drains the states staged since the last drain into collected, announcements under their current name and
	-- retractions as empty names under the withdrawn id. a nil collected discards them instead, for a drain
	-- with nobody to deliver to.
	local function drain_staged(collected: { [number]: string }?)
		if collected ~= nil then
			for dense_id, state in staged do
				if state == true then
					collected[ids[dense_id] :: any] = names[dense_id]
				else
					collected[state :: any] = ""
				end
			end
		end
		table.clear(staged)
	end

	return {
		announce = announce,
		retract = retract,
		announced_id = announced_id,
		has_live = has_live,
		collect_live = collect_live,
		has_staged = has_staged,
		drain_staged = drain_staged,
	}
end
