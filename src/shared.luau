--!strict

-- the shared, side-agnostic leg of duplecs: the per-world component set that schema modules tag against and
-- both halves return their side's subset of, plus the per-world serdes store both halves resolve hooks
-- through. the module returns the record getter itself: init.luau wraps it into the public
-- duplecs.shared(world) -> Components, and the halves call it directly for the record, which also carries
-- their memoized instances (see server.luau / client.luau).
--
-- everything per-world lives *inside* the world: the record is the value of an internal anchor component set
-- on itself, and the module-level map holds only the anchor's numeric id under a weak world key. luau weak
-- tables have no ephemeron semantics, so a module-level cache whose values reference the world (the memoized
-- instances close over it, and user serdes hooks may) would pin every world for the module's lifetime; a
-- plain number can't, so a dropped world takes its record -- components, serdes store, and instances -- with
-- it.

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

-- the full duplecs component set, minted per world on its first duplecs contact. every entry is inert until
-- the half that owns it is constructed -- the tags carry no hooks before then -- so a side-agnostic schema
-- module (or gameplay code running on both sides) may tag freely: the tags only mean something where the
-- owning half is live, and each half's construction catches up on whatever was tagged before it (misuse
-- guards included, which then error from the construction call).
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

-- the per-world record behind the accessors: the component set, the serdes store's resolver, and the slots
-- the halves memoize their instances into (typed unknown here -- the instance types live in the half modules,
-- which require this one).
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

return function(world: World): Record
	local anchor = anchors[world]
	if anchor ~= nil then
		local record = world:get(anchor, anchor)
		if record == nil then
			fail(`the internal entity holding this world's duplecs state was deleted!`)
		end
		return record :: Record
	end

	-- the world's first duplecs contact: probe for a foreign jecs instance before touching it. every uncached
	-- query is stamped with its creator module's exported Query table as its metatable, so a mismatch here means
	-- the world was created by a different jecs module instance than the one duplecs requires -- table identity
	-- can neither false-positive nor miss a genuinely foreign world. a same-version duplicate happens to work
	-- (built-in ids are compile-time constants and world methods are self-contained closures), but duplicated
	-- dependencies let the two versions drift apart silently, and mismatched versions corrupt replication --
	-- built-in ids shift and the internal structures the packet paths read change layout -- so warn rather than
	-- error: the fix gets named while the setup may still be benign.
	if getmetatable(world:query(jecs.Component) :: any) ~= jecs.Query then
		warn(
			`the world was created by a different jecs instance than the one duplecs requires! replication will misbehave if the two versions ever differ; resolve the game's and duplecs's jecs dependencies to a single installation.`
		)
	end

	local Replicated = world:entity() :: Component<nil>

	local Networked = world:entity() :: Component<nil>
	local NetworkedOnce = world:entity() :: Component<nil>
	local NetworkedUnreliable = world:entity() :: Component<nil>

	-- when set on an entity, Private without a pair filters the entity itself's visibility, while
	-- pair(Private, Component) filters the target component's. the value is always a table -- the server half
	-- warns at a nil one and rewrites it to an empty filter, since absence already means unrestricted -- and its
	-- polarity follows from its contents: an empty table, or one with only `true` values, is a `whitelist`. a
	-- table with only `false` values, or an absent Private entirely, is a `blacklist`. designed so the polarity
	-- can always be determined from the current state.
	local Private = world:component() :: Component<Privacy>

	-- pair(InheritsPrivacy, group) delegates an entity's entity-level visibility to the group entity's ordinary
	-- entity-level filter (see PRIVACY DELEGATION in server.luau). an entity may delegate to several groups at
	-- once -- its gate intersects them all -- so delegation forms a DAG (cycles are rejected at add time), and
	-- the Delete cleanup policy deletes an entity when any group it delegates to is deleted, so a group deletion
	-- never widens anyone. the flag is snapshotted by jecs when the first pair using the relation is created, so
	-- it is set here at minting, before any user pair can exist.
	local InheritsPrivacy = world:entity() :: Component<nil>
	world:add(InheritsPrivacy, pair(jecs.OnDeleteTarget, jecs.Delete))

	local Imported = world:entity() :: Component<nil>

	-- the serdes store's Serdes component and validation hooks exist from this point, so no registration can
	-- ever predate them -- serdes needs no construction catch-up on either half
	local serdes_store = create_serdes_store(world)

	-- frozen so consumers can't mutate the shared set; the cast bridges table.freeze's read-only result back to
	-- the exported type (the old solver rejects `read` property syntax, so the type can't declare it directly)
	local components = table.freeze({
		Networked = Networked,
		NetworkedOnce = NetworkedOnce,
		NetworkedUnreliable = NetworkedUnreliable,
		Replicated = Replicated,
		Private = Private,
		InheritsPrivacy = InheritsPrivacy,
		Serdes = serdes_store.Serdes,
		Imported = Imported,
	}) :: Components

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
