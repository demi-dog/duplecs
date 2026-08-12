--!strict

-- duplecs: generalized per-world replication for jecs. the source is split into a server half (change
-- tracking, per-client visibility, packet generation -- server.luau), a client half (server/client entity
-- mapping, reconciliation overrides, packet reconciliation -- client.luau), and the shared component set both
-- halves draw from (shared.luau). the module returns three per-world memoized accessors: server and client
-- construct their half on the first call and return that same instance ever after, and shared returns the
-- world's full component set, minted at the world's first duplecs contact -- so a side-agnostic schema module
-- can tag components (and register serdes hooks) without knowing which half the world will construct. types
-- and functionality both halves share live in types.luau, wire.luau, and serdes.luau.

-- `@self`: init.luau resolves `./` against the directory's parent, so the module's own children are addressed
-- through the self alias instead.
local types = require("@self/types")
local shared = require("@self/shared")

local client = require("@self/client")
local server = require("@self/server")

-- jecs's own types (World, Entity, Component, Id) are deliberately not re-exported: every consumer requires
-- jecs anyway (the world and the component definitions are theirs to create), so take them from jecs directly.
-- the docs' `Client` is likewise no export: a client is *any* value the caller registers, so the name is
-- signature notation for `any` rather than a type worth writing.
export type Packet = types.Packet
export type Serdes<T = any> = types.Serdes<T>
export type Privacy = types.Privacy

export type Components = shared.Components

-- the halves' instance types, as the server and client accessors return them -- for annotating storage the
-- inference can't reach (a typed field, a module-boundary parameter).
export type ServerInstance = server.ServerInstance
export type ClientInstance = client.ClientInstance

export type ChangedOverride<T = any> = client.ChangedOverride<T>
export type RemovedOverride = client.RemovedOverride

return {
	server = server,
	client = client,
	shared = function(world: types.World)
		return shared(world).components
	end,
}
