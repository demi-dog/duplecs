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

-- one serdes store per world, constructed by shared.luau around the world's Serdes component -- minted fresh
-- for a per-world set, or the pre-registered id whose registrations jecs replayed at world creation, which
-- the catch-up below picks up. hooks are assigned by setting Serdes on the component (or relation)
-- definition entity, which keys the store by that entity; pair(Serdes, target) set on a relation keys the
-- concrete pair(relation, target) instead, taking precedence over the relation's own hooks when a pair
-- section resolves (resolve_serdes). a tag relation's pairs additionally derive hooks from the target
-- definition's own registration -- jecs types such a pair's data by the target, so the definition typing the
-- value is the one encoding it -- with a concrete pair(Serdes, target) registration still winning. removal
-- (the holder's or a pair target's deletion included) clears the entry, so the store never carries stale
-- ids.
return function(world: types.World, Serdes: Component<Serdes?>)
	local serdes_hooks = {} :: { [Id]: Serdes? }

	-- the store key of one Serdes cell: the holder itself for an unpaired Serdes, or pair(holder, target) for
	-- pair(Serdes, target). pairs key by their packed id (dense halves -- exactly what resolve_serdes is
	-- handed), which also lets the removed hook derive the key when the target is already dead.
	local function serdes_key(entity: Entity, id: Id): Id
		if id == Serdes then
			return entity
		end
		return pair(entity, jecs.ECS_PAIR_SECOND(id))
	end

	-- tag-ness of one key, matching how jecs types a pair's data: the relation carries the value unless it is a
	-- tag, in which case the target does (pair(tag, component) holds target-typed data). checked through the
	-- halves rather than the packed id -- jecs.is_tag only decomposes a pair id once its first instantiation
	-- records it, and a registration may precede the pair's first use.
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
			-- frozen like Private values: the store caches by reference, so a registration mutated after assignment
			-- can't silently change wire behavior -- and a pre-registered value is one table replayed into every
			-- world, so the freeze also keeps worlds from changing each other's wire behavior through it. the cast
			-- keeps the new solver from refining serdes read-only here, which the store's read-write value type
			-- below would reject
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

	-- construction catch-up: with a pre-registered component set, registrations predate the store --
	-- jecs.meta buffers them and world creation replays them through ordinary world:set, all before the
	-- world's first duplecs contact can construct anything -- so every pre-existing cell replays through the
	-- added handler, misuse guards included (which then error from the first-contact call, like the halves'
	-- catch-up guards). holders are collected before any handler runs: a guard removes the offending value,
	-- moving its holder mid-walk. a per-world set's Serdes is minted just before this runs, so its walks find
	-- nothing.
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

	-- the serdes hooks a section's values encode or decode with: the concrete component's (a pair-specific
	-- registration for pair sections), falling back to the relation's for pairs without their own -- and, for
	-- pairs of a tag relation, to the target definition's own registration: jecs types a tag relation's pair
	-- data by the target (the same rule is_tag_key mirrors above), so the definition that types the value is
	-- the one that encodes it. the two fallbacks never compete -- a tag relation can never hold an unpaired
	-- registration (the added-hook guard refuses it) -- and the live pair_second read is safe here: staged
	-- values never outlive their target, so every value-bearing resolve sees it alive, and paths that resolve
	-- a dead half carry no values.
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
