--!strict

-- WORKAROUND (jecs 0.11.0): thin wrappers around world:added / world:changed / world:removed that repair the
-- unpaired id's hook after registering. every hook registration in duplecs goes through here.
--
-- the bug: the broadcast closure a first registration mints is written to the component's unpaired record
-- and to its pair records in an either/or branch -- `if component_index[pair(component, Wildcard)] then
-- <patch every pair record> else <patch the unpaired record> end` -- so a component that already has a pair
-- record never gets the closure onto its unpaired record. that is harmless while the unpaired record doesn't
-- exist yet (a record made afterwards reads the EcsOnAdd / EcsOnChange / EcsOnRemove value the registration
-- writes onto the component itself), and permanent once it does: an existing record never re-reads that
-- value, and registering again can't recover it (the whole block is guarded by `if not listeners`). the
-- listener then never fires for the unpaired id while every pair using the component as its relation keeps
-- firing normally -- no error, no warning.
--
-- the shapes duplecs reaches it through are ordinary ones: Private is documented in both forms (an
-- entity-level filter and pair(Private, component)), so a schema module setting one of each before
-- duplecs.server(world) runs would leave every later entity-level filter edit silently ignored; and any
-- tracked definition already used as a relation when its Networked tag lands hits it the same way, since
-- start_tracking_component connects that definition's hooks at tag time.
--
-- the repair asserts jecs's own invariant rather than reaching around it: the value a registration leaves on
-- the component *is* the composed broadcast closure (any pre-existing raw hook merged into its listener
-- list), and it is exactly what a record created afterwards reads for itself, so writing it to the unpaired
-- record is what the unbranched write would have done. it runs only on the registration that mints that
-- closure -- the one call that can hit the bug -- so a raw hook assigned to the component afterwards is never
-- clobbered, and against a jecs that fixes the branch the write only stores the value already there. removing
-- this module once that lands is cleanup rather than a fix: every wrapper call becomes the world method it
-- names.

local jecs = require("../roblox_packages/jecs")

local types = require("./types")

type World = types.World
type Entity = types.Entity
type Component<T = any> = types.Component<T>
type Id<T = any> = types.Id<T>

-- the registration callbacks, typed as loosely as the world methods resolve them to at duplecs's call sites
-- (which annotate their own parameters and never read the archetype one jecs passes fourth)
type ValueCallback<T> = (entity: Entity, id: Id<T>, value: T, old_archetype: unknown) -> ()
type RemovedCallback<T> = (entity: Entity, id: Id<T>, delete: boolean?) -> ()

-- the unpaired id's component record, or nil while the id has never been added to an entity -- in which case
-- there is nothing to repair, since the record jecs creates later reads the hook off the component itself
local function unpaired_record<T>(world: World, component: Component<T>): jecs.ComponentRecord?
	return jecs.component_record(world, component :: any)
end

local function added<T>(world: World, component: Component<T>, callback: ValueCallback<T>): () -> ()
	local previous = world:get(component, jecs.OnAdd)
	local disconnect = world:added(component, callback :: any)

	local broadcast = world:get(component, jecs.OnAdd)
	if broadcast ~= previous then
		local record = unpaired_record(world, component)
		if record ~= nil then
			record.on_add = broadcast :: any
		end
	end

	return disconnect
end

local function changed<T>(world: World, component: Component<T>, callback: ValueCallback<T>): () -> ()
	local previous = world:get(component, jecs.OnChange)
	local disconnect = world:changed(component, callback :: any)

	local broadcast = world:get(component, jecs.OnChange)
	if broadcast ~= previous then
		local record = unpaired_record(world, component)
		if record ~= nil then
			record.on_change = broadcast :: any
		end
	end

	return disconnect
end

local function removed<T>(world: World, component: Component<T>, callback: RemovedCallback<T>): () -> ()
	local previous = world:get(component, jecs.OnRemove)
	local disconnect = world:removed(component, callback :: any)

	local broadcast = world:get(component, jecs.OnRemove)
	if broadcast ~= previous then
		local record = unpaired_record(world, component)
		if record ~= nil then
			record.on_remove = broadcast :: any
		end
	end

	return disconnect
end

return {
	added = added,
	changed = changed,
	removed = removed,
}
