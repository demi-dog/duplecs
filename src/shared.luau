--!strict

-- the shared, side-agnostic leg of duplecs: the per-world component set schema modules tag against and both
-- halves return their side's subset of, plus the per-world serdes store both halves resolve hooks through.
-- get_record is the per-world record getter (init.luau wraps it into duplecs.shared(world); the halves call
-- it directly for the record, which also carries their memoized instances). preregister is the world-less
-- mode behind duplecs.shared(nil): it mints the set once per process through jecs's pre-registration methods
-- (jecs.component / jecs.tag / jecs.meta, which must all run before any jecs.world call), jecs replays it
-- into every world created afterwards, and get_record then recognizes the set instead of minting a per-world
-- one.
--
-- everything per-world lives *inside* the world: the record is the value of an internal anchor component set
-- on itself, and the module-level map holds only the anchor's numeric id under a weak world key. luau weak
-- tables have no ephemeron semantics, so a module-level cache whose values reference the world (the memoized
-- instances close over it) would pin every world for the module's lifetime; a plain number can't, so a
-- dropped world takes its record with it. the pre-registered set belongs to no world (jecs's counters and
-- meta buffer are module-global) and holds only numeric ids, so its memo pins nothing.

local jecs = require("../roblox_packages/jecs")
local pair = jecs.pair

local types = require("./types")
local create_serdes_store = require("./serdes")
local diagnostics = require("./diagnostics")

local fail = diagnostics.fail

type World = types.World
type Component<T = any> = types.Component<T>
type Id<T = any> = types.Id<T>
type Privacy = types.Privacy
type Serdes<T = any> = types.Serdes<T>

-- the full duplecs component set, minted per world on its first duplecs contact, or once per process by
-- preregister. every entry is inert until the half that owns it is constructed -- the tags carry no hooks
-- before then -- so side-agnostic code may tag freely: each half's construction catches up on whatever was
-- tagged before it, misuse guards included (which then error from the construction call).
export type Components = {
	Networked: Component<nil>,
	NetworkedOnce: Component<nil>,
	NetworkedUnreliable: Component<nil>,
	Replicated: Component<nil>,
	Private: Component<Privacy>,
	InheritsPrivacy: Component<nil>,
	Serdes: Component<Serdes?>,
	Imported: Component<nil>,
}

-- the per-world record behind the accessors: the component set, the serdes resolver, and the slots the halves
-- memoize their instances into (typed unknown; the instance types live in the half modules, which require
-- this one).
export type Record = {
	components: Components,
	resolve_serdes: (component: Id, relation: Id?) -> Serdes?,
	server: unknown?,
	client: unknown?,
}

-- first-contact warnings ride a plain module-level reporter that always resolves to the global warn: warn
-- hooks are per half-instance (set_warn_hook), and no instance can exist before the world's first contact.
local reporter = diagnostics.create_reporter()
local warn = reporter.warn

local anchors = setmetatable({} :: { [World]: Component<Record> }, { __mode = "k" })

-- the pre-registered set. module-global like the jecs state it stands for: pre-registration bumps jecs's
-- module-global id counters and meta buffer, so the set is per-process by nature.
local preregistered: Components? = nil

-- duplecs.shared(nil): mints the set through jecs's pre-registration methods, which must all run before every
-- jecs.world call whose world is meant to hold the set; repeated calls return the same frozen set. the ids
-- land in jecs's component and tag ranges rather than a world's entity range, which nothing downstream keys
-- off -- the set is identical on the wire, and components map by name. jecs.ECS_META_RESET discards the state
-- this set stands on: worlds created after a reset no longer hold it, and get_record's fingerprint refuses
-- them.
local function preregister(): Components
	local existing = preregistered
	if existing ~= nil then
		return existing
	end

	local Replicated = jecs.tag() :: Component<nil>

	local Networked = jecs.tag() :: Component<nil>
	local NetworkedOnce = jecs.tag() :: Component<nil>
	local NetworkedUnreliable = jecs.tag() :: Component<nil>

	-- see get_record's mint arm for each component's semantics; the two arms must stay twins. Private and
	-- Serdes are the set's two data components, so they alone draw from jecs's component range.
	local Private = jecs.component() :: Component<Privacy>

	-- InheritsPrivacy's cleanup policy rides the meta buffer, so world creation replays it before any user pair
	-- of the relation can exist -- jecs snapshots the flag when the relation's first pair record is created.
	local InheritsPrivacy = jecs.tag() :: Component<nil>
	jecs.meta(InheritsPrivacy, pair(jecs.OnDeleteTarget, jecs.Delete) :: any, nil)

	local Imported = jecs.tag() :: Component<nil>

	local Serdes = jecs.component() :: Component<Serdes?>

	jecs.meta(Networked, jecs.Name, "duplecs.Networked")
	jecs.meta(NetworkedOnce, jecs.Name, "duplecs.NetworkedOnce")
	jecs.meta(NetworkedUnreliable, jecs.Name, "duplecs.NetworkedUnreliable")
	jecs.meta(Replicated, jecs.Name, "duplecs.Replicated")
	jecs.meta(Private, jecs.Name, "duplecs.Private")
	jecs.meta(InheritsPrivacy, jecs.Name, "duplecs.InheritsPrivacy")
	jecs.meta(Serdes, jecs.Name, "duplecs.Serdes")
	jecs.meta(Imported, jecs.Name, "duplecs.Imported")

	local components = table.freeze({
		Networked = Networked,
		NetworkedOnce = NetworkedOnce,
		NetworkedUnreliable = NetworkedUnreliable,
		Replicated = Replicated,
		Private = Private,
		InheritsPrivacy = InheritsPrivacy,
		Serdes = Serdes,
		Imported = Imported,
	}) :: Components
	preregistered = components
	return components
end

local function get_record(world: World): Record
	local anchor = anchors[world]
	if anchor ~= nil then
		local record = world:get(anchor, anchor)
		if record == nil then
			fail(`the internal entity holding this world's duplecs state was deleted!`)
		end
		return record :: Record
	end

	-- the world's first duplecs contact: probe for a foreign jecs instance before touching it. every uncached
	-- query is stamped with its creator module's Query table as its metatable, so a mismatch means the world was
	-- created by a different jecs module instance than duplecs requires. a same-version duplicate happens to
	-- work, but mismatched versions corrupt replication (built-in ids shift and the internal structures the
	-- packet paths read change layout), so warn rather than error: the fix gets named while the setup may still
	-- be benign.
	if getmetatable(world:query(jecs.Component) :: any) ~= jecs.Query then
		warn(
			`the world was created by a different jecs instance than the one duplecs requires! replication will misbehave if the two versions ever differ; resolve the game's and duplecs's jecs dependencies to a single installation.`
		)
	end

	local components: Components
	local global_set = preregistered
	if global_set ~= nil then
		-- a pre-registered set exists, so recognize it rather than minting a second -- but only where the world
		-- actually holds it: jecs replays pre-registration only into worlds created after it, so an earlier world
		-- misses everything the set stands on and its own ids collide numerically with the set's; minting on top
		-- would corrupt silently, so this errors. the fingerprint reads the meta-applied name, never aliveness:
		-- world creation makes every component-range id alive in every world regardless of pre-registration. a
		-- foreign-instance world fails the same check, the probe above having named that cause.
		if world:get(global_set.Private, jecs.Name) ~= "duplecs.Private" then
			fail(
				`this world does not hold the pre-registered duplecs component set! jecs replays pre-registration only into worlds created after it, so create every world after the first duplecs.shared(nil) call -- a world from a different jecs instance fails the same way (the warning above names that cause when it applies).`
			)
		end
		components = global_set
	else
		local Replicated = world:entity() :: Component<nil>

		local Networked = world:entity() :: Component<nil>
		local NetworkedOnce = world:entity() :: Component<nil>
		local NetworkedUnreliable = world:entity() :: Component<nil>

		-- an unpaired Private filters the entity's own visibility, pair(Private, Component) the target component's.
		-- the value is always a table -- the server half warns at nil and rewrites it to an empty filter, since
		-- absence already means unrestricted -- and its polarity follows from its contents: an empty table, or one
		-- with only `true` values, is a whitelist; one with only `false` values, or an absent Private, is a
		-- blacklist. designed so the polarity can always be determined from the current state.
		local Private = world:component() :: Component<Privacy>

		-- pair(InheritsPrivacy, group) delegates an entity's entity-level visibility to the group's ordinary
		-- entity-level filter (see PRIVACY DELEGATION in server.luau). an entity may delegate to several groups --
		-- its gate intersects them all -- so delegation forms a DAG (cycles are rejected at add time), and the
		-- Delete cleanup policy deletes an entity when any group it delegates to is deleted, so a group deletion
		-- never widens anyone. jecs snapshots the flag when the relation's first pair is created, so it is set here
		-- at minting.
		local InheritsPrivacy = world:entity() :: Component<nil>
		world:add(InheritsPrivacy, pair(jecs.OnDeleteTarget, jecs.Delete))

		local Imported = world:entity() :: Component<nil>

		-- the serdes store's component; the store itself is constructed around it below, either mode
		local Serdes = world:component() :: Component<Serdes?>

		-- every exported component carries a jecs.Name in jecs's dotted style ("jecs.ChildOf"), so debuggers
		-- labeling ids by name render them legibly. the prefix keeps the names out of the plain namespace schema
		-- modules map by -- the client binds announced names to the same-named client entity, so an unprefixed
		-- "Networked" would collide with a user component of that name. set at minting, before either half is
		-- constructed, so the server's construction walk seeds them into its named-entity mirror: both sides mint
		-- identical names, so a networked pair aimed at a duplecs component maps like any named target.
		-- duplecs.Private doubles as get_record's fingerprint of a pre-registered set.
		world:set(Networked, jecs.Name, "duplecs.Networked")
		world:set(NetworkedOnce, jecs.Name, "duplecs.NetworkedOnce")
		world:set(NetworkedUnreliable, jecs.Name, "duplecs.NetworkedUnreliable")
		world:set(Replicated, jecs.Name, "duplecs.Replicated")
		world:set(Private, jecs.Name, "duplecs.Private")
		world:set(InheritsPrivacy, jecs.Name, "duplecs.InheritsPrivacy")
		world:set(Serdes, jecs.Name, "duplecs.Serdes")
		world:set(Imported, jecs.Name, "duplecs.Imported")

		-- frozen so consumers can't mutate the shared set; the cast bridges table.freeze's read-only result back to
		-- the exported type (the old solver rejects `read` property syntax, so the type can't declare it directly)
		components = table.freeze({
			Networked = Networked,
			NetworkedOnce = NetworkedOnce,
			NetworkedUnreliable = NetworkedUnreliable,
			Replicated = Replicated,
			Private = Private,
			InheritsPrivacy = InheritsPrivacy,
			Serdes = Serdes,
			Imported = Imported,
		}) :: Components
	end

	-- the serdes store's hooks connect here and its catch-up replays whatever registrations predate it (every
	-- pre-registered one), so registration misuse errors from its own call site or from this first contact, and
	-- neither half needs a serdes catch-up of its own (see serdes.luau).
	local serdes_store = create_serdes_store(world, components.Serdes)

	-- the anchor: an internal data component holding the record as its own value, so the record -- and through
	-- it the instances -- lives in the world's own storage and dies with it
	local created_anchor = world:component() :: Component<Record>
	local record: Record = {
		components = components,
		resolve_serdes = serdes_store.resolve_serdes,
		server = nil,
		client = nil,
	}
	world:set(created_anchor, created_anchor, record)
	anchors[world] = created_anchor

	return record
end

return {
	get_record = get_record,
	preregister = preregister,
}
