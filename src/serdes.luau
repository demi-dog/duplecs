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

-- one serdes store per world, constructed by shared.luau around the Serdes component both half instances
-- export -- the store (and its validation hooks) therefore exists before any registration can, so neither
-- half needs a construction catch-up for it. hooks are assigned by setting Serdes on the component (or
-- relation) definition entity, which keys the store by that entity; pair(Serdes, target) set on a relation
-- keys the concrete pair(relation, target) instead, taking precedence over the relation's own hooks when a
-- pair section resolves (resolve_serdes). removal (the holder's or a pair target's deletion included) clears
-- the entry, so the store never carries stale ids.
return function(world: types.World)
	local Serdes = world:component() :: Component<Serdes?>

	local serdes_hooks = {} :: { [Id]: Serdes? }

	-- the store key of one Serdes cell: the holder itself for an unpaired Serdes, or pair(holder, target) for
	-- pair(Serdes, target). pairs key by their packed id (dense halves -- exactly what resolve_serdes is
	-- handed), which also lets the removed hook derive the key when the target is already dead.
	local function serdes_key(entity: Entity, id: Id): Id
		if id == Serdes then
			return entity
		end
		return pair(entity, jecs.ECS_PAIR_SECOND(id) :: any)
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
			fail(`serdes hooks cannot be assigned to tags! ({id_to_string(key :: any, world)})`)
		end
		if serdes ~= nil then
			local hooks = serdes :: any
			if type(hooks.encode) ~= "function" or type(hooks.decode) ~= "function" then
				world:remove(entity, id)
				fail(`serdes registrations must provide encode and decode hooks! ({id_to_string(key :: any, world)})`)
			end
			-- sizing runs through encode's buffers; size only ever declares a static byte length
			if hooks.size ~= nil and type(hooks.size) ~= "number" then
				world:remove(entity, id)
				fail(
					`serdes size must be a static byte length (a plain number) when present! ({id_to_string(
						key :: any,
						world
					)})`
				)
			end
			-- frozen like Private values: the store caches by reference, so a registration mutated after assignment
			-- can't silently change wire behavior
			if table.isfrozen(hooks) ~= true then
				table.freeze(hooks)
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

	-- the serdes hooks a section's values encode or decode with: the concrete component's (a pair-specific
	-- registration for pair sections), falling back to the relation's for pairs without their own.
	local function resolve_serdes(component: Id, relation: Id?): Serdes?
		local serdes = serdes_hooks[component]
		if serdes == nil and relation ~= nil then
			serdes = serdes_hooks[relation]
		end
		return serdes
	end

	return {
		Serdes = Serdes,
		resolve_serdes = resolve_serdes,
	}
end
