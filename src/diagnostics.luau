--!strict
--!native
--!optimize 2

-- shared warn/error helpers for both halves: the `[duplecs]` prefix every message carries (so users can grep
-- their output), the id-to-string helper messages embed ids through, and the per-instance warn reporter
-- backing each half's injectable warn hook (set_warn_hook on the instances).
--
-- the id convention: `$` prefixes an id verified alive in the world at message time, `?` one that can't be
-- verified -- no world at hand, a dead id, or an id from a namespace this world can't check (wire and server
-- ids). pair ids decompose into `pair(relation, target)` -- gen-qualified halves where the world resolves
-- them live, dense halves behind `?` otherwise -- so a packed pair id never prints as one meaningless number.
-- neither prefix is interpolation syntax (luau interpolates with `{}`).

local jecs = require("../roblox_packages/jecs")

local types = require("./types")

type World = types.World

-- the sink one instance's warnings emit through: receives exactly the string the global warn would have
-- printed, prefix included.
export type WarnHook = (message: string) -> ()

export type Reporter = {
	warn: (message: string) -> (),
	set_warn_hook: (hook: WarnHook?) -> (),
}

-- the greppable prefix every duplecs warning and error message carries
local prefix = "[duplecs] "

-- raises `message` under the shared prefix, blaming the caller's line like a plain error() there would
local function fail(message: string): never
	error(prefix .. message, 2)
end

-- renders one id under the convention above. everything here runs only while composing a warn/error message,
-- so it deliberately calls the jecs originals -- don't "deduplicate" server.luau's inlined hot-path id-math
-- mirrors into this module (see the mirrors' comment there). world is optional: pass the id's own world to
-- verify liveness and gen-qualify pair halves; omit it for ids no world can vouch for (wire and server ids).
local function id_to_string(id: number, world: World?): string
	if jecs.IS_PAIR(id :: any) then
		local relation_dense = jecs.ECS_PAIR_FIRST(id :: any)
		local target_dense = jecs.ECS_PAIR_SECOND(id :: any)
		if world ~= nil then
			-- the packed dense halves resolve to live gen-qualified ids, or 0 when dead
			local relation = jecs.pair_first(world, id :: any) :: any
			local target = jecs.pair_second(world, id :: any) :: any
			local relation_string = if relation ~= 0 then `${relation}` else `?{relation_dense}`
			local target_string = if target ~= 0 then `${target}` else `?{target_dense}`
			return `pair({relation_string}, {target_string})`
		end
		return `pair(?{relation_dense}, ?{target_dense})`
	end
	if world ~= nil and world:contains(id :: any) then
		return `${id}`
	end
	return `?{id}`
end

-- one reporter per duplecs instance: warn emits a prefixed message through the current sink -- the global
-- warn until set_warn_hook installs a hook (nil restores the global) -- so a test harness or telemetry can
-- capture exactly what would have printed. warnings only; errors always raise.
local function create_reporter(): Reporter
	local hook: WarnHook? = nil

	local function report(message: string)
		local sink: WarnHook = hook or warn
		sink(prefix .. message)
	end

	local function set_warn_hook(new_hook: WarnHook?)
		hook = new_hook
	end

	return {
		warn = report,
		set_warn_hook = set_warn_hook,
	}
end

return {
	fail = fail,
	id_to_string = id_to_string,
	create_reporter = create_reporter,
}
