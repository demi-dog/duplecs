--!strict

-- duplecs: generalized per-world replication for jecs. server.luau is the server half (change tracking,
-- per-client visibility, packet generation), client.luau the client half (server/client entity mapping,
-- reconciliation overrides, packet reconciliation), and shared.luau the component set both draw from;
-- types.luau, wire.luau, and serdes.luau hold what both halves share. the module returns three per-world
-- memoized accessors: server and client construct their half on the first call, and shared returns the
-- world's component set, minted at the world's first duplecs contact -- so a side-agnostic schema module can
-- tag components (and register serdes hooks) without knowing which half the world will construct.

-- `@self`: init.luau resolves `./` against the directory's parent, so the module's own children are addressed
-- through the self alias instead.
local types = require("@self/types")
local shared = require("@self/shared")

local client = require("@self/client")
local server = require("@self/server")

-- jecs's own types (World, Entity, Component, Id) are deliberately not re-exported: every consumer requires
-- jecs anyway. the docs' `Client` is likewise no export: a client is *any* value the caller registers, so the
-- name is signature notation for `any` rather than a type worth writing.
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

-- the debug inspector's record views (both halves' describe_packet / describe_chunk) and the server's opt-in
-- byte counters (get_packet_stats / get_chunk_stats)
export type PacketDescription = types.PacketDescription
export type ChunkDescription = types.ChunkDescription
export type SectionDescription = types.SectionDescription
export type ComponentDescription = types.ComponentDescription
export type EntityDescription = types.EntityDescription
export type NameDescription = types.NameDescription
export type PacketStats = types.PacketStats
export type ComponentStats = types.ComponentStats

return {
	server = server,
	client = client,
	-- nil selects pre-registration mode: the set is minted through jecs's own top-level pre-registration
	-- methods before any world exists, and every world created afterwards holds it (see shared.luau).
	shared = function(world: types.World?)
		if world == nil then
			return shared.preregister()
		end
		return shared.get_record(world).components
	end,
}
