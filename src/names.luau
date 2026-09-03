--!strict
--!native
--!optimize 2

-- the server's shared-name store, one per instance: the announced set, the transitions staged against it, and
-- the two refusals announcing warns on. server.luau owns *which* ids are announcement-relevant
-- (refresh_announcement derives it from its mirrors and calls in); this module owns the store and the drains
-- the packet passes read. warn is the instance's reporter's, so refusals ride the same injectable hook.
--
-- shared names: tracked definitions and named (unreplicated) pair targets announce their jecs.Name as (id,
-- name) entries in packet headers, so a client world defining the same names maps them without
-- set_client_entity. keyed by dense id, matching server.luau's tracked_pairs_by_target (whose removal paths
-- may run with the entity already dead), with ids holding the gen-qualified id the wire needs. staged holds
-- one state per dense id since the last drain: true announces the id's current name, a number is a
-- *retraction* carrying the withdrawn gen-qualified id -- clients must end the mapping before the dense id
-- recycles into a tenant they would misbind (a retraction reaching a mapping that outlived it -- adopted by a
-- creation, or superseded by a newer announcement -- is a no-op there). drains go to every allocated client
-- (names are schema, never gated by visibility), retractions riding as empty-name entries; full packets carry
-- the whole live set, never retractions. names over 255 bytes don't fit the wire's u8 length and empty names
-- would read as retractions, so both are refused with a warning, and a refused name withdraws whatever
-- announcement the id held.

local jecs = require("../roblox_packages/jecs")

local types = require("./types")
local diagnostics = require("./diagnostics")

local id_to_string = diagnostics.id_to_string

type World = types.World
type Entity = types.Entity

-- the generation-stripping jecs.ECS_ID; nothing here is hot, so it calls the jecs original rather than
-- mirroring the id math the way server.luau does. takes branded ids and plain numbers alike.
local dense = (jecs.ECS_ID :: any) :: (entity_gen: unknown) -> number

return function(world: World, warn: (message: string) -> ())
	-- the announced set, keyed by dense id: names holds each announced name, ids the gen-qualified id it was
	-- announced under, and staged the transitions since the last drain (see the module comment for the states).
	local names = {} :: { [number]: string }
	local ids = {} :: { [number]: Entity }
	local staged = {} :: { [number]: true | Entity }

	-- a re-announcement staged later this frame overwrites the retraction: the announcement alone carries enough
	-- for clients to supersede their stale mapping (see map_shared_name's generation check).
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

	-- announces the entity's current jecs.Name. an unannounceable name (empty or over the u8 length, both
	-- warned; a non-string is a type violation jecs.Name's own typing rules out) instead withdraws whatever
	-- announcement the entity holds: a renamed definition would otherwise stay bound under its old name on every
	-- client. a later valid rename announces again.
	local function announce(entity: Entity)
		local dense_id = dense(entity)
		local name = world:get(entity, jecs.Name)
		if type(name) == "string" and #name > 0 and #name <= 255 then
			if ids[dense_id] == entity and names[dense_id] == name then
				return
			end
			ids[dense_id] = entity
			names[dense_id] = name
			staged[dense_id] = true
			return
		end
		if type(name) == "string" then
			if #name == 0 then
				warn(`shared names must not be empty! ({id_to_string(entity, world)})`)
			else
				warn(`shared names must be at most 255 bytes! ({id_to_string(entity, world)})`)
			end
		end
		if ids[dense_id] == entity then
			retract(dense_id)
		end
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

	-- drains the staged states into collected: announcements under their current name, retractions as empty
	-- names under the withdrawn id. a nil collected discards them (a drain with nobody to deliver to).
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
