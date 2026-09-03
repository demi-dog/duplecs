--!strict
--!native
--!optimize 2

-- note: in warn/error strings, `$` prefixes verified-live entity ids and `?` unverifiable ones -- see
-- diagnostics.luau, which owns the convention and the [duplecs] prefix every message carries.

local jecs = require("../roblox_packages/jecs")
local pair = jecs.pair

local types = require("./types")
local hooks = require("./hooks")
local diagnostics = require("./diagnostics")

local fail = diagnostics.fail
local id_to_string = diagnostics.id_to_string

type Entity = types.Entity
type Component<T = any> = types.Component<T>
type Id<T = any> = types.Id<T>
type Serdes<T = any> = types.Serdes<T>

-- one serdes store per world, constructed by shared.luau around the world's Serdes component (minted per
-- world, or the pre-registered id whose registrations jecs replayed at world creation -- the catch-up below
-- picks those up). Serdes set on a definition entity keys the store by that entity; pair(Serdes, target) set
-- on a relation keys the concrete pair(relation, target) and wins over the relation's own hooks. a tag
-- relation's pairs also fall back to the target definition's registration, since jecs types such a pair's
-- data by the target (see resolve_serdes). removal clears the entry, so the store never carries stale ids.
return function(world: types.World, Serdes: Component<Serdes?>)
	local serdes_hooks = {} :: { [Id]: Serdes? }

	-- the store key of one Serdes cell: the holder for an unpaired Serdes, pair(holder, target) for pair(Serdes,
	-- target). pairs key by their packed id (dense halves, what resolve_serdes is handed), which also lets the
	-- removed hook derive the key when the target is already dead.
	local function serdes_key(entity: Entity, id: Id): Id
		if id == Serdes then
			return entity
		end
		return pair(entity, jecs.ECS_PAIR_SECOND(id))
	end

	-- tag-ness of one key, following how jecs types a pair's data: the relation's unless it is a tag, in which
	-- case the target's. checked through the halves rather than the packed id -- jecs.is_tag only decomposes a
	-- pair id once its first instantiation records it, and a registration may precede the pair's first use.
	local function is_tag_key(entity: Entity, id: Id): boolean
		if jecs.is_tag(world, entity) ~= true then
			return false
		end
		if id == Serdes then
			return true
		end
		return jecs.is_tag(world, jecs.pair_second(world, id))
	end

	local function on_serdes_added(entity: Entity, id: Id, serdes: Serdes?)
		local key = serdes_key(entity, id)
		if serdes ~= nil and is_tag_key(entity, id) then
			world:remove(entity, id)
			fail(`serdes hooks cannot be assigned to tags! ({id_to_string(key, world)})`)
		end
		if serdes ~= nil then
			if type(serdes.encode) ~= "function" or type(serdes.decode) ~= "function" then
				world:remove(entity, id)
				fail(`serdes registrations must provide encode and decode hooks! ({id_to_string(key, world)})`)
			end
			-- sizing runs through encode's buffers; size only ever declares a static byte length
			if serdes.size ~= nil and type(serdes.size) ~= "number" then
				world:remove(entity, id)
				fail(
					`serdes size must be a static byte length (a plain number) when present! ({id_to_string(key, world)})`
				)
			end
			-- frozen like Private values: the store caches by reference, and a pre-registered value is one table
			-- replayed into every world, so a later mutation would change wire behavior silently (across worlds,
			-- even). the cast keeps the new solver from refining serdes read-only, which the store's value type would
			-- reject
			if table.isfrozen(serdes) ~= true then
				table.freeze(serdes :: any)
			end
		end
		serdes_hooks[key] = serdes
	end

	local function on_serdes_removed(entity: Entity, id: Id)
		serdes_hooks[serdes_key(entity, id)] = nil
	end

	hooks.added(world, Serdes, on_serdes_added)
	hooks.changed(world, Serdes, on_serdes_added)
	hooks.removed(world, Serdes, on_serdes_removed)

	-- construction catch-up: with a pre-registered set, registrations predate the store (jecs.meta buffers them
	-- and world creation replays them through ordinary world:set), so every pre-existing cell replays through
	-- the added handler, misuse guards included -- those then error from the first-contact call. holders are
	-- collected before any handler runs, since a guard's remove moves its holder mid-walk. a per-world set's
	-- Serdes is minted just before this, so its walks find nothing.
	local holders = {} :: { Entity }
	local held_ids = {} :: { Id }
	for entity in world:each(Serdes) do
		table.insert(holders, entity)
		table.insert(held_ids, Serdes :: Id)
	end
	for entity in world:each(pair(Serdes, jecs.Wildcard)) do
		local index = 0
		local target = world:target(entity, Serdes, 0)
		while target ~= nil do
			table.insert(holders, entity)
			table.insert(held_ids, pair(Serdes, target))
			index += 1
			target = world:target(entity, Serdes, index)
		end
	end
	for index, entity in holders do
		local id = held_ids[index]
		on_serdes_added(entity, id, world:get(entity, id))
	end

	-- the serdes a section's values encode or decode with: the concrete component's, then the relation's for a
	-- pair without its own, then -- for a tag relation's pairs -- the target definition's, since jecs types such
	-- pair data by the target (is_tag_key mirrors the rule). the fallbacks never compete: a tag relation can
	-- never hold an unpaired registration (the added guard refuses it). the live pair_second read is safe
	-- because staged values never outlive their target, and paths resolving a dead half carry no values.
	local function resolve_serdes(component: Id, relation: Id?): Serdes?
		local serdes = serdes_hooks[component]
		if serdes == nil and relation ~= nil then
			serdes = serdes_hooks[relation]
			if serdes == nil and jecs.is_tag(world, relation) then
				local target = jecs.pair_second(world, component)
				if (target :: any) ~= 0 then
					serdes = serdes_hooks[target]
				end
			end
		end
		return serdes
	end

	return {
		Serdes = Serdes,
		resolve_serdes = resolve_serdes,
	}
end
