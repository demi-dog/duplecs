--!strict
--!native
--!optimize 2

-- the server half of duplecs: change tracking, per-client visibility, and packet generation. constructed per
-- world by the first duplecs.server call (see init.luau); later calls return the same memoized instance.

-- note: in warn/error strings, `$` prefixes verified-live entity ids and `?` unverifiable ones (dead, or
-- printed without a world at hand) -- see diagnostics.luau, which owns the convention and the [duplecs]
-- prefix every message carries.

-- REQUIRES & CONSTANTS

local jecs = require("../roblox_packages/jecs")
local pair = jecs.pair

local types = require("./types")
local wire = require("./wire")
local get_shared = require("./shared")
local create_pools = require("./pools")
local create_names = require("./names")
local hooks = require("./hooks")
local diagnostics = require("./diagnostics")

local fail = diagnostics.fail
local id_to_string = diagnostics.id_to_string

-- sentinel for a staged cell present on the entity but holding no value (a tag, or nil), distinct from an
-- absent ChangedValues entry. compared by table identity only, and never crosses the wire (nulled cells
-- travel in their own list).
local _nulled = table.freeze({ _nulled = true }) :: _Nulled

-- stand-in for a component record's archetype map when the component has no record yet (nothing was ever
-- tagged with it), so record-driven walks can skip the record nil-check at their loop head.
local empty_records = table.freeze({}) :: { [number]: number }

-- the packet writers; the wire layouts and all byte-level encoding live in wire.luau.
local measure_section_salvaging = wire.measure_section_salvaging
local write_section = wire.write_section
local assemble_packet = wire.assemble_packet
local finalize_chunks = wire.finalize_chunks

-- mask runs pack (shard, word) as word + shard * 2^32 (exact in f64 up to ~2^21 shards); a cell's cross-shard
-- visibility is a path of runs through the per-frame mask trie, so equal visibility lands on one node.
local shard_key_span = 2 ^ 32

-- generate_packets calls between sweeps of the persistent packet-group store, and the staleness bar for
-- eviction, so a group untouched after its last packet survives at most two intervals.
local group_sweep_interval = 512

-- the default byte budget of one unreliable chunk: Roblox's unreliable remote limit is 1000 bytes for the
-- whole event payload. measured in Studio (2026-08-11), an incompressible buffer arrives up to exactly 996
-- bytes, so the envelope costs 4 and 980 keeps 16 spare. pass chunk_bytes to generate_unreliable_chunks for
-- other transports.
local default_chunk_bytes = 980

-- the bounds a caller's chunk_bytes must fall in, both derived from the wire layout rather than picked (see
-- min_chunk_bytes in wire.luau): below the floor an empty chunk cannot fit one cell of a section, and above
-- the ceiling a chunk section's u16 length field cannot address its own bytes.
local min_chunk_bytes = wire.min_chunk_bytes
local max_chunk_bytes = wire.max_chunk_bytes

-- JECS ID MATH MIRRORS (so the compiler inlines)

-- parameters are typed unknown so call sites pass branded ids and plain numbers alike without casts.

local ECS_ENTITY_MASK = 2 ^ 24
local ECS_PAIR_OFFSET = 2 ^ 48

local function IS_PAIR(id: unknown): boolean
	return (id :: number) > ECS_PAIR_OFFSET
end

local function ECS_PAIR_FIRST(id: unknown): number
	return ((id :: number) - ECS_PAIR_OFFSET) // ECS_ENTITY_MASK
end

local function ECS_PAIR_SECOND(id: unknown): number
	return ((id :: number) - ECS_PAIR_OFFSET) % ECS_ENTITY_MASK
end

-- the generation-stripping jecs.ECS_ID, under the name its server call sites use
local function dense(id: unknown): number
	return (id :: number) % ECS_ENTITY_MASK
end

-- TYPES

type _Nulled = { _nulled: boolean }

-- shared type aliases (see types.luau)
type World = types.World
type Entity = types.Entity
type Component<T = any> = types.Component<T>
type Id<T = any> = types.Id<T>
type Client = types.Client
type Packet = types.Packet

type ChangedValues = { [Entity]: _Nulled | unknown }

-- one mask-trie node: children keyed by run, appended in ascending shard order with zero words skipped, so
-- equal cross-shard visibility resolves to exactly one node. contents are per-frame; the tables recycle
-- through a free list.
type MaskTrieNode = { [number]: MaskTrieNode }

-- the set of clients a cell's sections go to: a mask-trie node with several shards occupied, the shard's raw
-- mask word with one (0 meaning nothing accumulated yet). the expansion passes decode it back into client
-- indices.
type VisibilityNode = MaskTrieNode | number

-- per-group bucket of the cells dirtied this frame: parallel arrays indexed 1..count, with send / removed
-- masks accumulated across shards as VisibilityNodes. unpaired components own a group each; pair cells share
-- one group per relation, targets carrying each row's gen-qualified target. row_of correlates a cell's row
-- between shards and is only maintained with several shards occupied (pair groups nest it per pair id in
-- pair_rows, since one relation's rows span several targets); with one shard a cell may occupy a removal row
-- and a value-send row, harmless since their nodes never overlap. groups persist across frames so each
-- component reuses its own arrays (row demand is only predictable per group), and the bucket pass resets
-- count and clears values / row_of / pair_rows so stale rows never pin user data. for a pair group is_tag
-- holds the relation's tag-ness: a data relation types every pair as data, while a tag relation's pairs
-- follow their target, re-checked per pair id in the resolve passes.
type PacketGroup = {
	-- the component id, or the relation's dense half for pair groups; never a wire id
	key: number,
	frame: number,
	count: number,
	entities: { number },
	values: { any },
	send_nodes: { VisibilityNode },
	removed_nodes: { VisibilityNode },
	row_of: { [Entity]: number }?,
	is_tag: boolean,
	relation: number?,
	targets: { number }?,
	pair_rows: { [Id]: { [Entity]: number } }?,
}

-- one section's accumulated cells (see wire.luau): unpaired drafts carry their lists directly, pair drafts
-- group cells into per-target runs. drafts and lists recycle through pools.luau once encoded, except the
-- hookless value list write_section hands back as the packet's side array, which escapes and is never pooled.
type SectionDraft = wire.SectionDraft

-- bit-packed number where each bit represents the visibility to the client allocated to that bit.
type VisibilityMask = number

-- per-shard mask words, sparse: a missing shard's word is 0.
type ShardMasks = { [number]: VisibilityMask }

-- one shard's visibility tree: mask words keyed [component][entity]. the next_visibilities /
-- last_visibilities stores hold one per occupied shard.
type ShardVisibilities = { [Id]: { [Entity]: VisibilityMask } }

-- one privacy filter (see types.luau for the polarity rules)
type Privacy = types.Privacy
type PrivacyFilterCache = { [Entity]: { [Component]: Privacy } }
type AllowMaskCache = { [Entity]: { [Component]: ShardMasks } }

local function create_server(world: World, shared_record: get_shared.Record)
	-- DIAGNOSTICS

	-- shadows the global warn so every warning here carries the [duplecs] prefix and rides the injectable
	-- set_warn_hook (see diagnostics.luau)
	local reporter = diagnostics.create_reporter()
	local warn = reporter.warn

	-- COMPONENTS

	-- the server-relevant slice of the world's shared component set (see shared.luau, where the definitions
	-- are minted and their semantics documented)
	local components = shared_record.components
	local Replicated = components.Replicated
	local Networked = components.Networked
	local NetworkedOnce = components.NetworkedOnce
	local NetworkedUnreliable = components.NetworkedUnreliable
	local Private = components.Private
	local InheritsPrivacy = components.InheritsPrivacy
	local InheritsPrivacyThrough = components.InheritsPrivacyThrough
	local ExportsPrivacy = components.ExportsPrivacy

	-- the tags' short names for diagnostics (their jecs.Name carries the duplecs. prefix)
	local tracking_tag_names = {
		[Networked] = "Networked",
		[NetworkedOnce] = "NetworkedOnce",
		[NetworkedUnreliable] = "NetworkedUnreliable",
	}

	-- synthetic cell id: entity existence flows through the visibility stores under it, never added to any
	-- entity; the resolve pass routes its diff into the per-client create / delete lists instead of a component
	-- group.
	local Existence = world:entity() :: Component<nil>

	-- the second synthetic key: an entity's ExportsPrivacy filter caches under it in the privacy stores, beside
	-- the Existence-keyed entity-level filter, so sanitization, the join grant, departure pruning, the freed-slot
	-- sweep, and compaction cover both with no extra arms. never staged as a cell -- the exported words only
	-- enter delegators' derivations (see PRIVACY DELEGATION).
	local Exported = world:entity() :: Component<nil>

	-- GENERAL FUNCTIONS

	-- never replaced on a live world, unlike world.archetypes (rebuilt by world:cleanup, so always re-read per
	-- call)
	local entity_index = world.entity_index
	local component_index = world.component_index

	local function get_components(entity_gen: Entity): { Id }
		local dense_id = dense(entity_gen)
		return entity_index.sparse_array[dense_id].archetype.types
	end

	local function no_targets(): Entity?
		return nil
	end

	-- iterates an entity's targets under relation through the internals world:target resolves per call (see
	-- jecs.md): same-relation pairs are contiguous in archetype.types, and the relation's wildcard record holds
	-- each archetype's slice start (records) and length (counts). the slice is snapshotted up front, so no
	-- caller may move the entity mid-iteration; a dead target resolves to nil and ends the loop. replace with
	-- jecs's own iterator if a later version adds one.
	local function each_target(entity: Entity, relation: Id): () -> Entity?
		local record = entity_index.sparse_array[dense(entity)]
		local idr = component_index[pair(relation, jecs.Wildcard)]
		if record == nil or idr == nil then
			return no_targets
		end
		local archetype = record.archetype
		local start = idr.records[archetype.id]
		if start == nil then
			return no_targets
		end
		local last = start + idr.counts[archetype.id] - 1
		local archetype_types = archetype.types
		local index = start
		return function(): Entity?
			if index > last then
				return nil
			end
			local pair_id = archetype_types[index]
			index += 1
			return jecs.entity_index_get_alive(entity_index :: any, ECS_PAIR_SECOND(pair_id)) :: any
		end
	end

	-- each_target's dense-half sibling: the same slice walk, yielding every target's dense id without resolving
	-- it, so a dead target neither ends the loop nor goes unvisited -- for the mirror teardowns that key by
	-- dense id and must drop every edge a pair ever stood for (see on_through_removed).
	local function each_dense_target(entity: Entity, relation: Id): () -> number?
		local record = entity_index.sparse_array[dense(entity)]
		local idr = component_index[pair(relation, jecs.Wildcard)]
		if record == nil or idr == nil then
			return no_targets :: any
		end
		local archetype = record.archetype
		local start = idr.records[archetype.id]
		if start == nil then
			return no_targets :: any
		end
		local last = start + idr.counts[archetype.id] - 1
		local archetype_types = archetype.types
		local index = start
		return function(): number?
			if index > last then
				return nil
			end
			local pair_id = archetype_types[index]
			index += 1
			return ECS_PAIR_SECOND(pair_id)
		end
	end

	-- VISIBILITY STATE

	-- entities with Replicated, keyed by dense id: gen-qualified keys churn one fresh key per spawn and rehash
	-- the table on nearly every insert at power-of-two live counts (~8.5us at 256 live), while dense ids recycle
	-- in place. safe because every reader passes a live entity. cleared while the removed hook runs, so it reads
	-- false slightly earlier than world:has would.
	local replicated_entities = {} :: { [number]: true }

	-- entities with a jecs.Name, mirrored by the name hooks (seeded at construction) so pair-target
	-- replicability stays a lookup; dense-keyed and cleared mid-hook like replicated_entities -- exactly when
	-- the restage must see the target as unnamed.
	local named_entities = {} :: { [number]: true }

	-- tracked components -> the one of Networked / NetworkedOnce / NetworkedUnreliable owning the tracking (the
	-- three are exclusive); networking a component also networks pairs using it as the relation. the owner is
	-- also how a tag's removed hook tells a genuine removal from a guard's undo (see on_tracking_tag_removed).
	local tracked_by = {} :: { [Component]: Component }

	-- target-specific mode designations, keyed [definition][dense target] -> the designating tag:
	-- pair(Networked*, Target) on a definition replicates its pairs aimed at Target under that tag's mode,
	-- overriding the unpaired tag -- or standing in for one, in which case only designated targets' pairs
	-- replicate (see on_designation_added). a target's death removes its pairs before its dense id can recycle,
	-- so an entry never names a stale tenant.
	local designations = {} :: { [Component]: { [number]: Component } }

	-- designations already warned about an unreplicable target, keyed by the gameplay pair id; the designation's
	-- removal re-arms it (see warn_unreplicable_designation).
	local designation_warned = {} :: { [Id]: true }

	-- gen-qualified ids of the tracked components by dense id, so the pair resolve paths (packed pair ids carry
	-- only the relation's dense half) skip jecs.pair_first per staged change; a pair's relation is always alive,
	-- so a hit is the live relation. stopping a relation's tracking moves its entry to retired_relation_gens
	-- until the next generate_packets clears it: the removals staged at stop time resolve after the relation may
	-- be dead (world:delete on a tracked relation runs the stop mid-death), and a live resolve would name it as
	-- 0 or the dense id's next tenant, so clients would skip the section and keep the pairs.
	local tracked_relation_gens = {} :: { [number]: Component }
	local retired_relation_gens = {} :: { [number]: Component }

	-- tag-ness of the tracked relations by dense id, so get_pair_group's per-frame re-derivation is a lookup
	-- rather than a world walk (a definition's tag-ness is fixed before use); retired or untracked relations
	-- fall back to jecs.is_tag.
	local tracked_relation_tags = {} :: { [number]: boolean }

	-- reverse index of live tracked-relation pair cells, [dense target][pair id] = subject count, maintained by
	-- the per-component hooks and the tracking walks regardless of the target's replicability (restaging on a
	-- target's visibility shift is exactly when that changes). dense-keyed because removed hooks can fire with
	-- the target already dead; a dead target's cells are all removed before its dense id can recycle.
	local tracked_pairs_by_target = {} :: { [number]: { [Id]: number } }

	-- gen-qualified ids of the indexed targets, captured while alive (a pair's halves are alive when its record
	-- is created). the resolve paths read it in place of jecs.pair_second -- every pair reaching them is
	-- indexed, so a miss is a dead half or unindexed pair, ineligible either way -- and removals resolving after
	-- a target's death recover the full id the wire needs from it. during a death cascade a hit can briefly name
	-- the dying target, but its mirrors clear before the hooks restage, so eligibility still resolves false.
	-- deindexing a target's last pair moves its entry to retired_target_gens, read for gone targets and cleared
	-- by generate_packets.
	local tracked_target_gens = {} :: { [number]: Entity }
	local retired_target_gens = {} :: { [number]: Entity }

	-- latest privacy filter of every Private cell, keyed [entity][key], key being the paired component, Existence
	-- for an unpaired Private (which gates the whole entity), or Exported for the entity's ExportsPrivacy filter.
	-- a filter is always a table (cache_filter_value normalizes nil to empty_whitelist), and an empty one blocks
	-- everyone: allow words absent =
	-- open to all allocated clients, present (even with no words) = gated to exactly those bits. blacklists
	-- sanitize into allow words too (the allocated clients they don't name), so every reader keeps allow
	-- semantics; a blacklist naming only untracked clients restricts nothing and is never cached (on_private_set
	-- removes the value, like edit_privacy emptying one). filters are frozen by the hooks and edited
	-- copy-on-write, so caching by reference is safe; allow_masks mirrors them per shard and is mutated in place
	-- (grants, sweeps).
	--
	-- two invariants: the cached table and the component's value are always one table (pruning writes the pruned
	-- clone back via write_filter_value, so world:get returns the effective filter), and filters only ever name
	-- allocated and pending clients (remove_client prunes departures). empty_whitelist is shared across cells:
	-- cached filters are only read, cloned, or replaced, never mutated.
	local empty_whitelist = table.freeze({}) :: Privacy
	local privacy_filters = {} :: PrivacyFilterCache
	local allow_masks = {} :: AllowMaskCache

	-- privacy delegation state (see PRIVACY DELEGATION). delegation_parents mirrors the live delegation edges,
	-- entity -> its groups, keyed by the group's dense id with the gen-qualified group as value: the removed
	-- hooks must resolve which edge died from a packed pair id alone (the group may already be dead
	-- mid-cascade), and a group's death removes its edges before its dense id can recycle. like the other
	-- mirrors it reads correctly inside a removal hook, when world:target still sees the old pair. an edge
	-- comes from one or more *sources* -- a direct pair(InheritsPrivacy, group), plus one per relation the
	-- entity inherits through (pair(InheritsPrivacyThrough, relation)) whose pair targets the group -- and
	-- delegation_edge_sources counts them per edge, so dropping one source never removes an edge another still
	-- holds; the edge exists exactly while its count does. effective_masks holds derived words for delegating
	-- entities only -- own intersect every parent's exported, absent when nothing inherited restricts -- while
	-- own words stay untouched in allow_masks, whose 1:1 mapping to filter membership the grant loop, sweeps,
	-- and compaction rely on; entity_gate_masks takes effective over own. exported_masks holds the words an
	-- entity hands its delegators when it narrows them -- its gate intersect its ExportsPrivacy filter's words
	-- -- present exactly while the filter is cached, and exported_gate_masks takes it over the entity's gate.
	-- both derived stores are copies the sweeps and compaction edit in place like the own words.
	local delegation_parents = {} :: { [Entity]: { [number]: Entity } }
	local delegation_edge_sources = {} :: { [Entity]: { [number]: number } }
	-- the reverse (group -> its delegators), maintained in lockstep, so the fan-out never queries the world
	local delegation_children = {} :: { [Entity]: { [Entity]: true } }
	local effective_masks = {} :: { [Entity]: ShardMasks }
	local exported_masks = {} :: { [Entity]: ShardMasks }

	-- the relations each entity inherits through, mirroring its live pair(InheritsPrivacyThrough, relation)
	-- pairs and keyed like delegation_parents (the relation's dense id -> the gen-qualified relation), so the
	-- removed hook resolves the relation from the packed pair id. through_hooks holds, per relation some entity
	-- inherits through, the relation's added / removed hook disconnectors and the count of entities using it:
	-- the hooks connect at the first and disconnect at the last, so one use never taxes every pair of the
	-- relation world-wide forever.
	local through_relations = {} :: { [Entity]: { [number]: Component } }
	local through_hooks = {} :: { [Component]: { users: number, added: () -> (), removed: () -> () } }

	-- client slots: each client gets a (shard, bit) pair so every stored mask is one 32-bit word and mask math
	-- stays native bit32; shards number from 1 so shard-keyed tables stay in the array part, and shard s holds
	-- global indices (s-1)*32 .. (s-1)*32+31. tracked_clients maps client -> global index, clients_by_index is
	-- the inverse for the packet scatter, pending_clients holds joiners awaiting a slot and full packet at the
	-- tail of generate_packets, and client_count feeds the compaction deadzone.
	local tracked_clients = {} :: { [Client]: number }
	local clients_by_index = {} :: { [number]: Client }
	local pending_clients = {} :: { [Client]: true }
	local client_count = 0

	-- allocated clients marked fresh by mark_client_fresh, granted a full packet in place of their delta at the
	-- tail of generate_packets like a joiner's
	local fresh_clients = {} :: { [Client]: true }

	-- the two halves of a client's global index: the 1-based shard holding the client, and the client's bit
	-- within that shard's mask words.
	local function shard_of(client_index: number): number
		return bit32.rshift(client_index, 5) + 1
	end

	local function slot_bit_of(client_index: number): VisibilityMask
		return bit32.lshift(1, bit32.band(client_index, 31))
	end

	-- per-shard allocation words, one entry per shard ever opened and never removed (shard_count bounds the
	-- shard loops and shrinks past empty top shards). freed_masks accumulates bits freed by remove_client whose
	-- stale marks may linger in the allow words, swept only when a slot is reused; compact_shards reclaims the
	-- top shard outright when the population shrinks far enough.
	local allocated_masks = {} :: { [number]: VisibilityMask }
	local freed_masks = {} :: { [number]: VisibilityMask }
	local shard_count = 0

	-- per-cell state. the mask stores are paged per shard, keyed [shard][component][entity] with each word
	-- covering the shard's 32 clients; staged values are client-agnostic, keyed [component][entity].
	-- next_visibilities: current masks of cells whose visibility changed this frame (presence is the dirty
	-- flag); last_visibilities: masks last sent; changed_values: staged values of changed cells visible to
	-- someone. rule: next ?? last must *always* reflect the current visibility. existence is a cell keyed by
	-- Existence: a bit gained is a create, a bit cleared a delete, a present 0 a pending delete.
	local next_visibilities = {} :: { [number]: ShardVisibilities }
	local last_visibilities = {} :: { [number]: ShardVisibilities }
	local changed_values = {} :: { [Id]: ChangedValues }

	-- VISIBILITY CHECKERS

	local function is_pair_target_replicable(target: Entity)
		local dense_target = dense(target)
		return replicated_entities[dense_target] ~= nil or named_entities[dense_target] ~= nil
	end

	-- the mode governing one pair cell: the target's designated tag when the relation designates it, else the
	-- relation's plain tracking tag. nil means the pair doesn't replicate at all -- an undesignated target on
	-- a definition tracked only through designations.
	local function resolve_pair_mode(relation: Component, dense_target: number): Component?
		local designated = designations[relation]
		if designated ~= nil then
			local mode = designated[dense_target]
			if mode ~= nil then
				return mode
			end
		end
		return tracked_by[relation]
	end

	-- the eligibility half of resolve_pair_mode, ordered so plain-tracked relations (the common case on the
	-- staging paths) answer from one tracked_by hit without a designation probe.
	local function is_pair_mode_tracked(relation: Component, dense_target: number): boolean
		if tracked_by[relation] ~= nil then
			return true
		end
		local designated = designations[relation]
		if designated ~= nil then
			return designated[dense_target] ~= nil
		end
		return false
	end

	-- resolves eligibility, the privacy key gating the cell per entity, and (for pairs) the gen-qualified
	-- target. pair halves resolve through the dense-keyed gen caches: every pair reaching here is indexed, so a
	-- miss is a dead half or an untracked relation, ineligible either way.
	local function resolve_component_eligibility(component: Id): (boolean, Id, Entity?)
		if IS_PAIR(component) then
			local dense_target = ECS_PAIR_SECOND(component)
			local target = tracked_target_gens[dense_target]
			if target == nil or is_pair_target_replicable(target) ~= true then
				return false, component, nil
			end

			local relation = tracked_relation_gens[ECS_PAIR_FIRST(component)]
			if relation == nil or is_pair_mode_tracked(relation, dense_target) ~= true then
				return false, component, nil
			end

			return true, relation, target
		end

		if tracked_by[component] == nil then
			return false, component, nil
		end

		return true, component, nil
	end

	-- reads the target gen cache, so a pair must be indexed before it is checked. pair-ness is a precondition,
	-- not a check: an unpaired id's low bits would misread as a target.
	local function is_pair_replicable(pair_id: Id)
		local target = tracked_target_gens[ECS_PAIR_SECOND(pair_id)]
		if target == nil then
			return false
		end
		return is_pair_target_replicable(target)
	end

	-- the entity-level allow words gating an entity, nil when unrestricted: the derived effective words when it
	-- delegates (see PRIVACY DELEGATION), its own cached words otherwise. a delegator whose chain restricts
	-- anything always occupies the effective store, so the fallthrough never reads a delegator's own words as
	-- its gate.
	local function entity_gate_masks(entity: Entity): ShardMasks?
		local effective = effective_masks[entity]
		if effective ~= nil then
			return effective
		end
		local entity_masks = allow_masks[entity]
		return if entity_masks then entity_masks[Existence] else nil
	end

	-- the entity-level allow words an entity hands its delegators: its exported words while it holds an
	-- ExportsPrivacy filter, else its own gate unchanged (see PRIVACY DELEGATION).
	local function exported_gate_masks(entity: Entity): ShardMasks?
		local exported = exported_masks[entity]
		if exported ~= nil then
			return exported
		end
		return entity_gate_masks(entity)
	end

	-- the shard-invariant half of an entity's existence visibility, fetched once per staging rather than per
	-- shard: whether it replicates, and the entity-level gate (nil when unrestricted).
	local function entity_vis_masks(entity: Entity): (boolean, ShardMasks?)
		if replicated_entities[dense(entity)] == nil then
			return false, nil
		end
		return true, entity_gate_masks(entity)
	end

	-- one shard's word of entity_vis_masks' result: the shard's allocated clients, narrowed by the entity-level
	-- allow word.
	local function entity_vis_word(shard: number, masks: ShardMasks?): VisibilityMask
		if masks ~= nil then
			return bit32.band(allocated_masks[shard], masks[shard] or 0)
		end
		return allocated_masks[shard]
	end

	-- the shard-invariant narrowing below the entity level: the per-component allow words and, for pairs, the
	-- target's entity-level gate -- a pair never replicates to a client lacking the target locally. a named
	-- (unreplicated) target is globally visible and an ungated replicated one open to every allocated client, so
	-- target_masks stays nil for both.
	local function cell_vis_masks(entity: Entity, privacy_key: Id, target: Entity?): (ShardMasks?, ShardMasks?)
		local entity_masks = allow_masks[entity]
		local cell_masks = if entity_masks then entity_masks[privacy_key] else nil
		local target_masks: ShardMasks? = nil
		if target ~= nil and replicated_entities[dense(target)] ~= nil then
			target_masks = entity_gate_masks(target)
		end
		return cell_masks, target_masks
	end

	-- one shard's cell word: the same shard's entity word narrowed by cell_vis_masks' words. entity_vis must be
	-- the matching shard's entity_vis_word result (already a subset of the allocated word).
	local function cell_vis_word(
		shard: number,
		entity_vis: VisibilityMask,
		cell_masks: ShardMasks?,
		target_masks: ShardMasks?
	): VisibilityMask
		local result = entity_vis
		if cell_masks ~= nil then
			result = bit32.band(result, cell_masks[shard] or 0)
		end
		if target_masks ~= nil then
			result = bit32.band(result, target_masks[shard] or 0)
		end
		return result
	end

	-- CHANGE STAGING

	local function get_changed_values(component: Id): ChangedValues
		local storage = changed_values[component]
		if storage == nil then
			storage = {}
			changed_values[component] = storage
		end
		return storage
	end

	local function get_next_visibility(shard: number, component: Id): { [Entity]: VisibilityMask }
		local shard_next_visibilities = next_visibilities[shard]
		if shard_next_visibilities == nil then
			shard_next_visibilities = {}
			next_visibilities[shard] = shard_next_visibilities
		end
		local visibility = shard_next_visibilities[component]
		if visibility == nil then
			visibility = {}
			shard_next_visibilities[component] = visibility
		end
		return visibility
	end

	local function last_visibility_of(shard: number, component: Id, entity: Entity): VisibilityMask
		local shard_last_visibilities = last_visibilities[shard]
		local last = if shard_last_visibilities then shard_last_visibilities[component] else nil
		return if last then last[entity] or 0 else 0
	end

	-- writes the current mask only on a mismatch with last, clearing a stale entry when they match again (a
	-- whitelist toggled and reverted in one frame).
	local function set_visibility(shard: number, component: Id, entity: Entity, cur: VisibilityMask)
		if cur == last_visibility_of(shard, component, entity) then
			local shard_next_visibilities = next_visibilities[shard]
			local visibility = if shard_next_visibilities then shard_next_visibilities[component] else nil
			if visibility then
				visibility[entity] = nil
				if next(visibility) == nil then
					(shard_next_visibilities :: any)[component] = nil
				end
			end
		else
			get_next_visibility(shard, component)[entity] = cur
		end
	end

	-- the word-math tail of visibility staging, fanning prefetched masks out across occupied shards (unoccupied
	-- shards' trees are dropped, so there is nothing to stage against). eligible false stages 0 everywhere, a
	-- removal-shaped restage.
	local function stage_visibility_masks(
		component: Id,
		entity: Entity,
		eligible: boolean,
		entity_masks: ShardMasks?,
		cell_masks: ShardMasks?,
		target_masks: ShardMasks?
	)
		for shard = 1, shard_count do
			if allocated_masks[shard] == 0 then
				continue
			end
			local cur = 0
			if eligible then
				local entity_vis = entity_vis_word(shard, entity_masks)
				if entity_vis ~= 0 then
					cur = cell_vis_word(shard, entity_vis, cell_masks, target_masks)
				end
			end
			set_visibility(shard, component, entity, cur)
		end
	end

	-- stages one cell standalone: the client-agnostic resolve and the allow-mask fetches run once up front, then
	-- the word loop above.
	local function stage_visibility(component: Id, entity: Entity)
		local replicated, entity_masks = entity_vis_masks(entity)
		local eligible = false
		local cell_masks: ShardMasks?, target_masks: ShardMasks?
		if replicated then
			local privacy_key, target
			eligible, privacy_key, target = resolve_component_eligibility(component)
			if eligible then
				cell_masks, target_masks = cell_vis_masks(entity, privacy_key, target)
			end
		end
		stage_visibility_masks(component, entity, eligible, entity_masks, cell_masks, target_masks)
	end

	-- value changes record only when the cell was visible to someone last pass; newly-visible slots read the
	-- live value during the resolve pass instead. the scan exits on the first hit, and a present last entry is
	-- always nonzero (the resolve merges and the freed-slot sweep prune entries that zero).
	local function stage_value(component: Id, entity: Entity, value: any)
		for _, shard_last_visibilities in last_visibilities do
			local last = shard_last_visibilities[component]
			if last ~= nil then
				if last[entity] ~= nil then
					get_changed_values(component)[entity] = value
					return
				end
			end
		end
	end

	-- removals never recompute a mask (the cell-word math assumes the entity still has the component), so it is
	-- forced to 0 directly; any staged value is dropped.
	local function stage_removed(component: Id, entity: Entity)
		for shard = 1, shard_count do
			if allocated_masks[shard] == 0 then
				continue
			end
			set_visibility(shard, component, entity, 0)
		end
		local storage = changed_values[component]
		if storage then
			storage[entity] = nil
		end
	end

	-- VISIBILITY QUERIES

	local function is_component_visible(entity: Entity, component: Id, client: Client)
		local client_index = tracked_clients[client]
		if client_index == nil then
			return false
		end
		local shard = shard_of(client_index)
		-- next ?? last is the cell's current mask (see the staging rule), sparing a fresh resolve-and-word-math
		-- recompute. a present 0 means a pending hide, so distinguish it from an absent entry before falling back.
		local shard_next_visibilities = next_visibilities[shard]
		local next_visibility = if shard_next_visibilities then shard_next_visibilities[component] else nil
		local staged = if next_visibility then next_visibility[entity] else nil
		local mask = if staged ~= nil then staged else last_visibility_of(shard, component, entity)
		return bit32.band(mask, slot_bit_of(client_index)) ~= 0
	end

	-- existence visibility, the same current-mask test keyed by Existence; component visibility is a subset of
	-- it, so false here implies false for every component.
	local function is_entity_visible(entity: Entity, client: Client)
		return is_component_visible(entity, Existence, client)
	end

	-- like is_component_visible but tests only the last-sent mask, ignoring any change staged this frame -- what
	-- the client actually holds right now, before the next generate_packets flushes the staged delta to it.
	local function was_component_visible(entity: Entity, component: Id, client: Client)
		local client_index = tracked_clients[client]
		if client_index == nil then
			return false
		end
		local shard = shard_of(client_index)
		local mask = last_visibility_of(shard, component, entity)
		return bit32.band(mask, slot_bit_of(client_index)) ~= 0
	end

	-- the last-sent counterpart of is_entity_visible.
	local function was_entity_visible(entity: Entity, client: Client)
		return was_component_visible(entity, Existence, client)
	end

	-- yields each client whose bit is set in the entity's existence words, shard by shard; use_staged picks the
	-- current mask (next ?? last) over the last-sent one. words are banded with the allocated word because freed
	-- slots' stale marks linger until reuse, so a set bit always resolves through clients_by_index.
	local function clients_seeing_iterator(entity: Entity, use_staged: boolean): () -> Client?
		local shard = 0
		local base_index = 0
		local word = 0
		return function(): Client?
			while word == 0 do
				shard += 1
				if shard > shard_count then
					return nil
				end
				local allocated = allocated_masks[shard]
				if allocated == 0 then
					continue
				end
				local mask: VisibilityMask
				if use_staged then
					local shard_next_visibilities = next_visibilities[shard]
					local next_visibility = if shard_next_visibilities then shard_next_visibilities[Existence] else nil
					local staged_mask = if next_visibility then next_visibility[entity] else nil
					mask = if staged_mask ~= nil then staged_mask else last_visibility_of(shard, Existence, entity)
				else
					mask = last_visibility_of(shard, Existence, entity)
				end
				word = bit32.band(mask, allocated)
				base_index = (shard - 1) * 32
			end
			local index = bit32.countrz(word)
			word = bit32.band(word, word - 1)
			return clients_by_index[base_index + index]
		end
	end

	-- the clients the entity's existence currently replicates to, for sight-gated side channels and debugging.
	-- slot order, which callers must not lean on; pending joiners never enumerate; words are read live as the
	-- walk advances, so finish iterating before staging visibility changes.
	local function get_clients_seeing(entity: Entity): () -> Client?
		return clients_seeing_iterator(entity, true)
	end

	-- the last-sent counterpart of get_clients_seeing: the clients that actually hold the entity before the next
	-- generate_packets.
	local function get_clients_last_seeing(entity: Entity): () -> Client?
		return clients_seeing_iterator(entity, false)
	end

	-- SHARED NAMES

	-- the instance's shared-name store (see names.luau): named ids clients map automatically -- tracked
	-- definitions and named (unreplicated) pair targets -- announced as (id, name) entries in packet headers.
	-- this half decides relevance (refresh_announcement) and drains the store at packet time; it takes the
	-- reporter's warn so its refusals ride this instance's hook.
	local shared_names = create_names(world, warn)

	-- brings the store in line with the entity's current relevance: a named, unreplicated id that is a tracked
	-- definition (plain tag or designations) or the target of a tracked pair is announced, anything else has its
	-- announcement withdrawn. every hook moving one of those inputs calls this after updating its mirror; both
	-- store operations are idempotent. it reads the mirrors rather than the world because inside a removed hook
	-- the world still holds the component while the mirrors already reflect its absence. the retract is gated on
	-- the announced tenant being this entity, so a stale caller (a dead id resolved through a dense-keyed store)
	-- never withdraws a newer tenant's announcement.
	local function refresh_announcement(entity: Entity)
		local dense_id = dense(entity)
		if
			named_entities[dense_id] ~= nil
			and replicated_entities[dense_id] == nil
			and (tracked_by[entity] ~= nil or designations[entity] ~= nil or tracked_pairs_by_target[dense_id] ~= nil)
		then
			shared_names.announce(entity)
		elseif shared_names.announced_id(dense_id) == entity then
			shared_names.retract(dense_id)
		end
	end

	-- CHANGE TRACKING

	-- networked_unreliable holds the components with an unreliable mode, so generate_unreliable_chunks iterates
	-- exactly them (their reliable tracking is NetworkedOnce's: membership, initial values, removals, no changed
	-- hook). networked_cleanup holds every tracked component's hook disconnectors.
	local networked_unreliable = {} :: { [Component]: true }
	local networked_cleanup = {} :: {
		[Component]: {
			added: () -> (),
			removed: () -> (),
			changed: (() -> ())?,
			mixed: boolean?,
		},
	}

	-- a designated target that is neither Replicated nor named can never ship its pairs -- silently, since that
	-- is ordinary state elsewhere -- but a designation is a schema-level marker whose silence is almost always a
	-- missing name, so the first gameplay pair aimed at one warns, once per designation. fires from pair
	-- indexing and from a designation landing over indexed pairs; the bucket check keeps a designation with no
	-- pairs of its own relation silent.
	local function warn_unreplicable_designation(pair_id: Id)
		local relation = tracked_relation_gens[ECS_PAIR_FIRST(pair_id)]
		if relation == nil then
			return
		end
		local designated = designations[relation]
		if designated == nil then
			return
		end
		local dense_target = ECS_PAIR_SECOND(pair_id)
		if designated[dense_target] == nil or designation_warned[pair_id] ~= nil then
			return
		end
		local bucket = tracked_pairs_by_target[dense_target]
		if bucket == nil or bucket[pair_id] == nil then
			return
		end
		local target = tracked_target_gens[dense_target]
		if target == nil or is_pair_target_replicable(target) then
			return
		end
		designation_warned[pair_id] = true
		warn(
			`a designated target of {id_to_string(relation, world)} is neither Replicated nor named! pairs aimed at it cannot replicate -- give the target a jecs.Name (or Replicated) so clients can map it. ({id_to_string(
				target,
				world
			)})`
		)
	end

	local function index_tracked_pair(pair_id: Id)
		local target = ECS_PAIR_SECOND(pair_id)
		local bucket = tracked_pairs_by_target[target]
		if bucket == nil then
			bucket = {}
			tracked_pairs_by_target[target] = bucket
			local target_gen: Entity = jecs.pair_second(world, pair_id) :: any
			if (target_gen :: any) ~= 0 then
				-- capture the gen-qualified id while the target is alive, for removals that resolve after its death
				tracked_target_gens[target] = target_gen
				-- the target's first tracked pair may make it announcement-relevant: a named, unreplicated target is a
				-- shared definition clients map by name (replicated targets map through their creation entry instead)
				refresh_announcement(target_gen)
			end
		end
		bucket[pair_id] = (bucket[pair_id] or 0) + 1
		warn_unreplicable_designation(pair_id)
	end

	local function deindex_tracked_pair(pair_id: Id)
		local target = ECS_PAIR_SECOND(pair_id)
		local bucket = tracked_pairs_by_target[target]
		if bucket == nil then
			return
		end
		local count = bucket[pair_id]
		if count == nil then
			return
		end
		if count > 1 then
			bucket[pair_id] = count - 1
		else
			bucket[pair_id] = nil
			if next(bucket) == nil then
				tracked_pairs_by_target[target] = nil
				-- retire the captured gen until the next generate_packets: the bucket empties during a target's death,
				-- but staged removals resolve later and must still name the dead target on the wire
				local target_gen = tracked_target_gens[target]
				if target_gen ~= nil then
					tracked_target_gens[target] = nil
					retired_target_gens[target] = target_gen
				end
				-- the target's last tracked pair is gone: its announcement now stands only if it is also a tracked
				-- component definition. resolved through the announced tenant, since the target may already be dead
				-- here and only the store still holds its gen-qualified id
				local announced = shared_names.announced_id(target)
				if announced ~= nil then
					refresh_announcement(announced)
				end
			end
		end
	end

	-- reconciles the mode-dependent state after a definition's mode set changes: unreliable membership, and
	-- whether the changed hook is connected. the hook connects while any mode is Networked, in one of two
	-- shapes: the plain shape (a plain Networked tag, no designations) keeps its body free of mode lookups (the
	-- per-cell resolve costs ~20ns on bare sets and ~40ns on pair sets, real money on the hottest event path),
	-- while the mixed shape resolves the governing mode per cell, the documented cost of mixing modes on one
	-- definition. mixed marks the connected shape, so reconnection happens exactly when the needed shape
	-- differs.
	local function reconcile_tracking_modes(component: Component)
		local plain = tracked_by[component]
		local has_networked = plain == Networked
		local has_unreliable = plain == NetworkedUnreliable
		local designated = designations[component]
		if designated ~= nil then
			for _, mode in designated do
				if mode == Networked then
					has_networked = true
				elseif mode == NetworkedUnreliable then
					has_unreliable = true
				end
			end
		end
		if has_unreliable then
			networked_unreliable[component] = true
		else
			networked_unreliable[component] = nil
		end
		local cleanup = networked_cleanup[component]
		if not has_networked then
			local disconnect = cleanup.changed
			if disconnect ~= nil then
				disconnect()
				cleanup.changed = nil
				cleanup.mixed = nil
			end
			return
		end
		local needs_mixed = designated ~= nil or plain ~= Networked
		local connected = cleanup.changed
		if connected ~= nil then
			if (cleanup.mixed == true) == needs_mixed then
				return
			end
			connected()
		end
		if needs_mixed then
			cleanup.changed = hooks.changed(world, component, function(entity: Entity, id: Id, value: any)
				if id == component then
					if tracked_by[component] == Networked then
						stage_value(id, entity, if value == nil then _nulled else value)
					end
					return
				end
				if resolve_pair_mode(component, ECS_PAIR_SECOND(id)) == Networked and is_pair_replicable(id) then
					stage_value(id, entity, if value == nil then _nulled else value)
				end
			end)
			cleanup.mixed = true
		else
			cleanup.changed = hooks.changed(world, component, function(entity: Entity, id: Id, value: any)
				if id == component or is_pair_replicable(id) then
					stage_value(id, entity, if value == nil then _nulled else value)
				end
			end)
			cleanup.mixed = nil
		end
	end

	-- the tracking setup shared by the three tags and their designations: record the owner (plain tags only),
	-- announce, stage existing cells' initial visibility, connect the per-component hooks, and reconcile the
	-- modes. a definition already tracked through designations skips to staging its newly-eligible cells: its
	-- hooks, mirrors, and pair index are live, and re-indexing its pairs would double their counts.
	local function start_tracking_component(component: Component, tag: Component?)
		if tag ~= nil then
			-- record the owner first so the staging below resolves visibility correctly
			tracked_by[component] = tag
			if networked_cleanup[component] ~= nil then
				-- already tracked via designations: stage the newly-eligible cells -- the bare cells and the
				-- undesignated pairs (designated pairs' masks are unchanged, so their stages are no-ops)
				for entity in world:each(component) do
					stage_visibility(component, entity)
				end
				for entity in world:each(pair(component, jecs.Wildcard)) do
					for target in each_target(entity, component) do
						local pair_id = pair(component, target)
						if is_pair_replicable(pair_id) then
							stage_visibility(pair_id, entity)
						end
					end
				end
				reconcile_tracking_modes(component)
				return
			end
		end
		local dense_id = dense(component)
		tracked_relation_gens[dense_id] = component
		tracked_relation_tags[dense_id] = jecs.is_tag(world, component)

		-- a named definition announces itself so clients map it automatically
		refresh_announcement(component)

		-- stage initial visibility of existing cells; newly-visible clients read live values during the resolve
		-- pass. with no plain tag the bare cells are ineligible, so only the pair walk stages anything.
		if tag ~= nil then
			for entity in world:each(component) do
				stage_visibility(component, entity)
			end
		end

		for entity in world:each(pair(component, jecs.Wildcard)) do
			for target in each_target(entity, component) do
				local pair_id = pair(component, target)
				index_tracked_pair(pair_id)
				if is_pair_replicable(pair_id) then
					stage_visibility(pair_id, entity)
				end
			end
		end

		networked_cleanup[component] = {
			added = hooks.added(world, component, function(entity: Entity, id: Id, value: any)
				-- pairs index regardless of the target's replicability, so a target's visibility shift can find them;
				-- staging an ineligible cell is a no-op, so no mode check here
				if id ~= component then
					index_tracked_pair(id)
				end
				if id == component or is_pair_replicable(id) then
					stage_visibility(id, entity)
					stage_value(id, entity, if value == nil then _nulled else value)
				end
			end),
			removed = hooks.removed(world, component, function(entity: Entity, id: Id)
				if id ~= component then
					deindex_tracked_pair(id)
					-- the gen caches can't say whether the target is dead or replicable here (the deindex may have just
					-- retired the gen, and a dying target's entry lingers while its mirrors clear), so keep the live death
					-- check; staging a never-visible pair is a no-op
					local target: Entity = jecs.pair_second(world, id) :: any
					if (target :: any) == 0 or is_pair_target_replicable(target) then
						stage_removed(id, entity)
					end
					return
				end
				stage_removed(id, entity)
			end),
		}
		reconcile_tracking_modes(component)
	end

	local function stop_tracking_component(component: Component)
		local cleanup = networked_cleanup[component]
		if cleanup then
			cleanup.added()
			cleanup.removed()
			local changed_disconnect = cleanup.changed
			if changed_disconnect ~= nil then
				changed_disconnect()
			end
			networked_cleanup[component] = nil
		end

		for entity in world:each(component) do
			stage_removed(component, entity)
		end

		for entity in world:each(pair(component, jecs.Wildcard)) do
			for target in each_target(entity, component) do
				local pair_id = pair(component, target)
				deindex_tracked_pair(pair_id)
				stage_removed(pair_id, entity)
			end
		end

		tracked_by[component] = nil
		networked_unreliable[component] = nil
		local dense_id = dense(component)
		-- retire the gen until the next generate_packets: the removals staged above resolve later, when the
		-- relation may be dead and the live resolve could no longer name it on the wire
		retired_relation_gens[dense_id] = tracked_relation_gens[dense_id]
		tracked_relation_gens[dense_id] = nil
		tracked_relation_tags[dense_id] = nil

		-- the announcement now stands only if the definition doubles as a named pair target of another tracked
		-- relation
		refresh_announcement(component)
	end

	-- stages one designated target's existing pairs after a designation change: visibility for every subject,
	-- plus -- when the change moved the pairs *out of* unreliable mode -- their current values, so the reliable
	-- stream re-establishes a baseline instead of leaving each client at its last received chunk (under
	-- NetworkedOnce a dropped final chunk would otherwise stay stale forever). a tag relation's tag pairs never
	-- streamed, so they veto the value restage here.
	local function stage_designated_pairs(pair_id: Id, restage_values: boolean)
		if restage_values and tracked_relation_tags[ECS_PAIR_FIRST(pair_id)] then
			local target_gen = tracked_target_gens[ECS_PAIR_SECOND(pair_id)]
			restage_values = target_gen ~= nil and jecs.is_tag(world, target_gen) ~= true
		end
		local idr = component_index[pair_id]
		if idr == nil then
			return
		end
		local world_archetypes = world.archetypes
		for archetype_id in idr.records do
			local archetype = world_archetypes[archetype_id]
			local column = if restage_values then archetype.columns_map[pair_id] else nil
			for row, subject in archetype.entities do
				stage_visibility(pair_id, subject)
				if column ~= nil then
					local value = column[row]
					stage_value(pair_id, subject, if value == nil then _nulled else value)
				end
			end
		end
	end

	-- a tracking tag added as pair(tag, Target) on a definition designates a target-specific mode: the
	-- definition's pairs aimed at Target replicate under that mode, overriding the unpaired tag -- or, with none
	-- present, gating them entirely. guards: a wildcard target designates nothing concrete, one target cannot
	-- carry two modes, and a replicated entity cannot become a tracked definition; each firing guard removes the
	-- just-added pair (which the removed hook recognizes as an undo by the entry being absent or owned by
	-- another tag) and errors.
	local function on_designation_added(component: Component, id: Id, tag: Component)
		local tag_name = tracking_tag_names[tag]
		local dense_target = ECS_PAIR_SECOND(id)
		if dense_target == dense(jecs.Wildcard) then
			world:remove(component, id)
			fail(
				`{tag_name} designations must name a concrete target, not jecs.Wildcard! ({id_to_string(
					component,
					world
				)})`
			)
		end

		if world:has(component, Replicated) then
			world:remove(component, id)
			fail(`cannot add {tag_name} to replicated entities!`)
		end

		local designated = designations[component]
		if designated == nil then
			designated = {}
			designations[component] = designated
		elseif designated[dense_target] ~= nil and designated[dense_target] ~= tag then
			local target: Entity = jecs.pair_second(world, id) :: any
			world:remove(component, id)
			fail(
				`Networked, NetworkedOnce, and NetworkedUnreliable designations are exclusive per target! ({id_to_string(
					component,
					world
				)} -> {id_to_string(target, world)})`
			)
		end
		designated[dense_target] = tag

		if networked_cleanup[component] == nil then
			-- the definition's first tracking: the full setup indexes and stages its existing pairs, connects the
			-- hooks, and reconciles the modes
			start_tracking_component(component, nil)
			return
		end

		-- already tracked: stage the target's existing pairs, restaging their values when the designation moved
		-- them out of unreliable mode
		local gameplay_pair = pair(component, dense_target :: any)
		stage_designated_pairs(
			gameplay_pair,
			tracked_by[component] == NetworkedUnreliable and tag ~= NetworkedUnreliable
		)
		warn_unreplicable_designation(gameplay_pair)
		reconcile_tracking_modes(component)
	end

	-- a genuine removal narrows or stops the definition's tracking; a guard's undo (the entry absent or owned by
	-- a different tag) passes through, like on_tracking_tag_removed's owner check.
	local function on_designation_removed(component: Component, id: Id, tag: Component)
		local designated = designations[component]
		if designated == nil then
			return
		end
		local dense_target = ECS_PAIR_SECOND(id)
		if designated[dense_target] ~= tag then
			return
		end
		designated[dense_target] = nil
		if next(designated) == nil then
			designations[component] = nil
		end
		local gameplay_pair = pair(component, dense_target :: any)
		designation_warned[gameplay_pair] = nil

		local plain = tracked_by[component]
		if plain == nil and designations[component] == nil then
			-- the definition's last mode source: the full stop stages every pair's removal and retires the relation
			stop_tracking_component(component)
			return
		end

		if plain == nil then
			-- no plain tag to fall back to: the target's pairs stop replicating. the walk mirrors
			-- stage_designated_pairs' (staging never moves a subject, so it is iteration-safe).
			local idr = component_index[gameplay_pair]
			if idr ~= nil then
				local world_archetypes = world.archetypes
				for archetype_id in idr.records do
					for _, subject in world_archetypes[archetype_id].entities do
						stage_removed(gameplay_pair, subject)
					end
				end
			end
		elseif tag == NetworkedUnreliable and plain ~= NetworkedUnreliable then
			-- the pairs fall back to the plain mode, out of unreliable streaming: restage their current values so
			-- the reliable stream re-establishes a fresh baseline (masks are unchanged, so nothing else ships)
			stage_designated_pairs(gameplay_pair, true)
		end

		reconcile_tracking_modes(component)
	end

	-- the guards shared by the three tags' unpaired adds: reject a component carrying another of the exclusive
	-- tags, and reject a Replicated component. each firing guard removes the just-added tag -- undoing the add
	-- so the removed hook recognizes it (see on_tracking_tag_removed) -- and errors.
	local function guard_networked_added(component: Component, tag: Component)
		local tag_name = tracking_tag_names[tag]
		if
			(tag ~= Networked and world:has(component, Networked))
			or (tag ~= NetworkedOnce and world:has(component, NetworkedOnce))
			or (tag ~= NetworkedUnreliable and world:has(component, NetworkedUnreliable))
		then
			world:remove(component, tag)
			fail(`Networked, NetworkedOnce, and NetworkedUnreliable are exclusive! ({id_to_string(component, world)})`)
		end

		if world:has(component, Replicated) then
			world:remove(component, tag)
			fail(`cannot add {tag_name} to replicated entities!`)
		end
	end

	-- the undo counterpart of those guards: a removal arrives identically whether the tag was genuinely removed
	-- or a guard stripped a refused add, and only the former may stop the tracking. tracked_by tells them apart:
	-- an undo is never the recorded owner. letting an undo through would stop tracking the component still has
	-- or, for a never-tracked component, overwrite retired_relation_gens[dense] with nil, erasing a retirement
	-- an earlier real stop on the same dense id staged this frame.
	local function on_tracking_tag_removed(component: Component, id: Id, tag: Component)
		-- a pair using the tag as its relation is a target designation, with its own genuine-vs-undo telling
		if id ~= tag then
			on_designation_removed(component, id, tag)
			return
		end
		-- not the recorded owner: a guard's undo, not a genuine removal
		if tracked_by[component] ~= tag then
			return
		end
		if designations[component] ~= nil then
			-- designations remain: only the plain tag's cells stop -- the bare cells and the undesignated pairs --
			-- while designated pairs keep replicating under their own modes, with the hooks, mirrors, pair index,
			-- and announcement staying live
			tracked_by[component] = nil
			for entity in world:each(component) do
				stage_removed(component, entity)
			end
			local designated = designations[component] :: { [number]: Component }
			for entity in world:each(pair(component, jecs.Wildcard)) do
				for target in each_target(entity, component) do
					if designated[dense(target)] == nil then
						stage_removed(pair(component, target), entity)
					end
				end
			end
			reconcile_tracking_modes(component)
			return
		end
		stop_tracking_component(component)
	end

	-- NetworkedOnce: initial values, removals, and full snapshots replicate, later value changes don't
	-- (force_replicate pushes one), for values the client can simulate on its own. exclusive with the other
	-- tracking tags; a paired add is a target designation.
	local function on_networked_once_added(component: Component, id: Id)
		if id ~= NetworkedOnce then
			on_designation_added(component, id, NetworkedOnce)
			return
		end
		guard_networked_added(component, NetworkedOnce)

		start_tracking_component(component, NetworkedOnce)
	end

	local function on_networked_once_removed(component: Component, id: Id)
		on_tracking_tag_removed(component, id, NetworkedOnce)
	end

	local function on_networked_added(component: Component, id: Id)
		if id ~= Networked then
			on_designation_added(component, id, Networked)
			return
		end
		guard_networked_added(component, Networked)

		start_tracking_component(component, Networked)
	end

	local function on_networked_removed(component: Component, id: Id)
		on_tracking_tag_removed(component, id, Networked)
	end

	-- NetworkedUnreliable: reliable tracking exactly like NetworkedOnce's (no changed hook, so per-set cost is
	-- zero unless another mode on the definition is Networked), while current values are re-read and re-sent
	-- every generate_unreliable_chunks call, for an unreliable transport where a dropped chunk costs one frame
	-- of staleness. on a tag definition only its pairs with data-component targets stream (see
	-- generate_unreliable_chunks).
	local function on_networked_unreliable_added(component: Component, id: Id)
		if id ~= NetworkedUnreliable then
			on_designation_added(component, id, NetworkedUnreliable)
			return
		end
		guard_networked_added(component, NetworkedUnreliable)

		start_tracking_component(component, NetworkedUnreliable)
	end

	local function on_networked_unreliable_removed(component: Component, id: Id)
		on_tracking_tag_removed(component, id, NetworkedUnreliable)
	end

	local function force_replicate(entity: Entity, component: Id)
		if world:has(entity, component) then
			local value = world:get(entity, component)
			stage_value(component, entity, if value == nil then _nulled else value)
		end
	end

	-- HANDLE REPLICATED ADD/REMOVE

	-- the restaged entity's per-shard entity words, prefetched once per restage; entries past shard_count are
	-- stale and never read. restages never nest, so one scratch array serves them all.
	local restage_entity_words = {} :: { VisibilityMask }

	-- stages one of the restaged entity's cells against the prefetched words, so only the cell-level narrowing
	-- runs per cell.
	local function stage_restaged_cell(
		component: Id,
		entity: Entity,
		cell_masks: ShardMasks?,
		target_masks: ShardMasks?
	)
		for shard = 1, shard_count do
			if allocated_masks[shard] == 0 then
				continue
			end
			local cur = restage_entity_words[shard]
			if cur ~= 0 then
				cur = cell_vis_word(shard, cur, cell_masks, target_masks)
			end
			set_visibility(shard, component, entity, cur)
		end
	end

	-- restages every networked cell the entity owns (unpaired components and pairs it is the subject of),
	-- mirroring resolve_component_eligibility / cell_vis_masks with the entity-invariant fetches hoisted.
	local function restage_own_cells(entity: Entity)
		local entity_masks = allow_masks[entity]
		for _, component in get_components(entity) do
			if IS_PAIR(component) then
				local relation = tracked_relation_gens[ECS_PAIR_FIRST(component)]
				local dense_target = ECS_PAIR_SECOND(component)
				local target = tracked_target_gens[dense_target]
				if
					relation ~= nil
					and target ~= nil
					and is_pair_target_replicable(target)
					and is_pair_mode_tracked(relation, dense_target)
				then
					local cell_masks = if entity_masks then entity_masks[relation] else nil
					local target_masks: ShardMasks? = nil
					if replicated_entities[dense(target)] ~= nil then
						target_masks = entity_gate_masks(target)
					end
					stage_restaged_cell(component, entity, cell_masks, target_masks)
				end
			elseif tracked_by[component] then
				local cell_masks = if entity_masks then entity_masks[component] else nil
				stage_restaged_cell(component, entity, cell_masks, nil)
			end
		end
	end

	-- restages networked pairs targeting this entity, for when its visibility as a target shifts. the reverse
	-- index holds exactly the live tracked-relation pairs; the pair-level resolve and the target's gate hoist
	-- out of the subject loop, while the subjects (other entities) stage their own words per subject. subjects
	-- walk each pair id's component record directly; staging never moves a subject between archetypes, so the
	-- walk is iteration-safe.
	local function restage_pairs_targeting(entity: Entity)
		local bucket = tracked_pairs_by_target[dense(entity)]
		if bucket == nil then
			return
		end
		local world_archetypes = world.archetypes
		for pair_id in bucket do
			local eligible, privacy_key, target = resolve_component_eligibility(pair_id)
			local target_masks: ShardMasks? = nil
			if target ~= nil and replicated_entities[dense(target)] ~= nil then
				target_masks = entity_gate_masks(target)
			end
			local idr = component_index[pair_id]
			if idr == nil then
				continue
			end
			for archetype_id in idr.records do
				for _, subject in world_archetypes[archetype_id].entities do
					local replicated, subject_masks = entity_vis_masks(subject)
					local cell_masks: ShardMasks? = nil
					if replicated and eligible then
						local subject_allow_masks = allow_masks[subject]
						cell_masks = if subject_allow_masks then subject_allow_masks[privacy_key] else nil
					end
					stage_visibility_masks(
						pair_id,
						subject,
						replicated and eligible,
						subject_masks,
						cell_masks,
						target_masks
					)
				end
			end
		end
	end

	-- the entity's overall visibility shifted: prefetch its per-shard entity words once, then restage its
	-- existence (against exactly those words -- existence has no cell-level narrowing), every cell it owns, and
	-- every pair targeting it.
	local function restage_entity(entity: Entity)
		local replicated, masks = entity_vis_masks(entity)
		for shard = 1, shard_count do
			restage_entity_words[shard] = if replicated then entity_vis_word(shard, masks) else 0
		end
		stage_restaged_cell(Existence, entity, nil, nil)
		restage_own_cells(entity)
		restage_pairs_targeting(entity)
	end

	local function on_replicated_added(entity: Entity, id: Id)
		if id ~= Replicated then
			world:remove(entity, id)
			fail(`Replicated is not meant to be paired! ({id_to_string(entity, world)})`)
		end

		-- any tracking tag refuses Replicated (see guard_networked_added and on_designation_added for the mirror
		-- direction); the message names whichever tag owns the tracking -- a designation's tag for designation-only
		-- definitions
		local tracking_tag = tracked_by[entity]
		if tracking_tag == nil then
			local designated = designations[entity]
			if designated ~= nil then
				local _, first_designation = next(designated)
				tracking_tag = first_designation
			end
		end
		if tracking_tag then
			world:remove(entity, Replicated)
			fail(`{tracking_tag_names[tracking_tag]} components cannot be replicated!`)
		end

		replicated_entities[dense(entity)] = true

		-- a replicated entity maps through its creation entry, never by name: withdraw any announcement. the staged
		-- retraction unmaps the clients the entity is *not* visible to (its deletion never reaches them, and a
		-- lingering mapping would misbind the dense id's next tenant), while clients receiving the creation adopt
		-- the mapping from name provenance first, so it leaves them untouched.
		refresh_announcement(entity)

		-- current cell values reach newly-visible clients via the live read at snapshot time; the entity also just
		-- became a replicable pair target
		restage_entity(entity)
	end

	local function on_replicated_removed(entity: Entity, id: Id)
		if id ~= Replicated then
			return
		end

		-- replicated_entities is cleared first so the restage below recomputes each mask as 0, staging the entity
		-- delete and every cell removal
		replicated_entities[dense(entity)] = nil

		-- an unreplicated entity still targeted by tracked pairs is back to mapping by name (if it has one)
		refresh_announcement(entity)

		restage_entity(entity)
	end

	-- NAME TRACKING

	-- jecs.Name makes an entity a replicable pair target (the named_entities mirror) and announces relevant ids
	-- for automatic client mapping; these hooks keep both live after initialize seeds the mirror.

	local function on_name_added(entity: Entity, id: Id)
		if id ~= jecs.Name then
			return
		end
		named_entities[dense(entity)] = true
		-- pairs targeting the entity may just have gained a replicable target
		restage_pairs_targeting(entity)
		refresh_announcement(entity)
	end

	local function on_name_changed(entity: Entity, id: Id)
		if id ~= jecs.Name then
			return
		end
		-- a rename doesn't change replicability; announce-relevance is re-derived rather than gated on an existing
		-- announcement -- a name refused at announce time (empty or too long) leaves the id unannounced, and its fix
		-- arrives through this hook
		refresh_announcement(entity)
	end

	local function on_name_removed(entity: Entity, id: Id)
		if id ~= jecs.Name then
			return
		end
		named_entities[dense(entity)] = nil
		-- pairs targeting the entity may just have lost their replicable target
		restage_pairs_targeting(entity)
		refresh_announcement(entity)
	end

	-- PRIVACY DELEGATION

	-- pair(InheritsPrivacy, group) delegates an entity's entity-level visibility to the group's entity-level
	-- filter, so one edit on the group narrows every delegator. an entity may delegate to several groups
	-- (orthogonal gates intersect), so delegation forms a DAG. scoped to the entity-level gate only -- a
	-- (component, group) key can't be encoded in a single pair target -- and a delegator's own filter intersects
	-- every inherited gate: everything narrows, matching the entity -> cell subset invariant.
	--
	-- two gates per entity. the *self* gate is what the entity itself passes: own words intersect every parent's
	-- exported words (effective_masks, delegators only). the *exported* gate is what its delegators inherit: the
	-- self gate intersect the entity's ExportsPrivacy filter's words (exported_masks, exporters only), the self
	-- gate itself when the entity exports nothing. so an export narrows the entities below an entity without
	-- touching the entity's own visibility, and a delegator is visible to at most the clients its groups are.
	--
	-- edges come from two kinds of pair. pair(InheritsPrivacy, group) is one edge, directly. pair(
	-- InheritsPrivacyThrough, relation) makes every target of the entity's pairs of that relation a parent too --
	-- "my gate follows whatever my ChildOf targets allow" -- kept in sync by hooks on the relation itself, so a
	-- containment move (retargeting the ChildOf) moves the privacy edge with it, with no second pair to keep in
	-- step by hand. both kinds land in the same mirror and derivation; the only structural addition is the
	-- per-edge source count, since one group can now arrive through several sources. the relation must carry
	-- pair(OnDeleteTarget, Delete), like InheritsPrivacy does: under Remove a target's death would drop the pair,
	-- the edge with it, and so widen the entity -- a leak -- where Delete deletes the entity instead.

	-- whether two sparse word tables hold the same words; zero words are always omitted, so equal restrictions
	-- compare equal.
	local function masks_equal(a: ShardMasks, b: ShardMasks): boolean
		for shard, word in a do
			if b[shard] ~= word then
				return false
			end
		end
		for shard in b do
			if a[shard] == nil then
				return false
			end
		end
		return true
	end

	-- narrows derived in place by other, dropping the words that zero (clearing the current key mid-iteration
	-- is safe)
	local function intersect_masks(derived: ShardMasks, other: ShardMasks)
		for shard, word in derived do
			local narrowed = bit32.band(word, other[shard] or 0)
			if narrowed ~= 0 then
				derived[shard] = narrowed
			else
				derived[shard] = nil
			end
		end
	end

	-- re-derives a delegator's self words as own intersect every parent's exported words, storing them (absent
	-- when every input is absent, leaving the store when the last edge goes) and returning whether they changed.
	-- always a fresh top-down derivation, never an in-place AND: intersection can't restore bits a widening edit
	-- must grant back.
	local function recompute_effective(entity: Entity): boolean
		local old = effective_masks[entity]
		local parents = delegation_parents[entity]
		if parents == nil then
			-- the last edge is gone: the gate reverts to the entity's own words via entity_gate_masks' fallthrough
			effective_masks[entity] = nil
			return old ~= nil
		end

		local entity_masks = allow_masks[entity]
		local own = if entity_masks then entity_masks[Existence] else nil

		-- copied, never aliased: own words are edited in place by the grant loop and sweeps, parents' exported
		-- words by later recomputes
		local derived: ShardMasks? = nil
		if own ~= nil then
			derived = table.clone(own)
		end
		for _, parent in parents do
			local parent_masks = exported_gate_masks(parent)
			if parent_masks == nil then
				continue
			end
			if derived == nil then
				derived = table.clone(parent_masks)
			else
				intersect_masks(derived, parent_masks)
			end
		end
		if derived == nil then
			effective_masks[entity] = nil
			return old ~= nil
		end
		effective_masks[entity] = derived

		if old == nil then
			return true
		end
		return not masks_equal(old, derived)
	end

	-- re-derives an entity's exported words as its self gate intersect its ExportsPrivacy filter's words,
	-- storing them exactly while the filter is cached (absent, delegators read the self gate through
	-- exported_gate_masks' fallthrough), and returning whether what delegators inherit changed. runs after the
	-- self gate is current; self_changed is the caller's knowledge of it (recompute_effective's result, or true
	-- for an edit of the own filter): with no filter it is the answer outright, and with one it decides whether
	-- the previous self gate can still stand in for what delegators read before. a fresh or dropped filter
	-- compares the new words against that reading, so an export that doesn't narrow the gate fans out nothing.
	local function recompute_exported(entity: Entity, self_changed: boolean): boolean
		local old = exported_masks[entity]
		local entity_masks = allow_masks[entity]
		local exported_own = if entity_masks then entity_masks[Exported] else nil
		if exported_own == nil and old == nil then
			-- the common case on every fan-out: no filter now or before, so nothing to derive or compare
			return self_changed
		end
		local self = entity_gate_masks(entity)
		if exported_own == nil then
			exported_masks[entity] = nil
			return self_changed or self == nil or not masks_equal(old :: ShardMasks, self)
		end

		-- copied, never aliased: the filter's words are edited in place by the grant loop and sweeps, the self
		-- words by later recomputes
		local derived = table.clone(exported_own)
		if self ~= nil then
			intersect_masks(derived, self)
		end
		exported_masks[entity] = derived

		if old ~= nil then
			return not masks_equal(old, derived)
		end
		return self_changed or self == nil or not masks_equal(self, derived)
	end

	-- fans an exported-word change out over the delegating descendants: each child re-derives both gates against
	-- all its parents, restaging when its self gate changed, and a child whose exported gate is unchanged prunes
	-- its branch -- a descendant needs refreshing only if some parent's exported words changed, and that parent,
	-- being un-pruned, fans out to it itself. this is what keeps a group edit cheaper than editing every member.
	-- diamonds re-derive once per arrival: an early arrival may read a sibling branch stale, but the last arrival
	-- reads everything fresh, and intermediate restages are idempotent, so the walk converges at the cost of
	-- duplicate work proportional to the diamond's width.
	local function refresh_descendants(node: Entity)
		local children = delegation_children[node]
		if children == nil then
			return
		end
		for child in children do
			local self_changed = recompute_effective(child)
			local exported_changed = recompute_exported(child, self_changed)
			if self_changed then
				restage_entity(child)
			end
			if exported_changed then
				refresh_descendants(child)
			end
		end
	end

	-- re-derives one entity's gates during a store-wide refresh (a joiner's slot grant), resolving every parent
	-- first; refreshed bounds the walk, and the cycle guards keep delegation acyclic, so parents always finish
	-- before their delegators read them. a non-delegating exporter re-derives only its exported words.
	local function refresh_gates(entity: Entity, refreshed: { [Entity]: true })
		if refreshed[entity] ~= nil then
			return
		end
		refreshed[entity] = true
		local parents = delegation_parents[entity]
		if parents ~= nil then
			for _, parent in parents do
				refresh_gates(parent, refreshed)
			end
			recompute_effective(entity)
		end
		recompute_exported(entity, false)
	end

	-- delegation_children maintenance, keyed by the full group entity so the fan-out and the parents mirror
	-- agree on identity
	local function index_delegation_child(group: Entity, child: Entity)
		local bucket = delegation_children[group]
		if bucket == nil then
			bucket = {}
			delegation_children[group] = bucket
		end
		bucket[child] = true
	end

	local function deindex_delegation_child(group: Entity, child: Entity)
		local bucket = delegation_children[group]
		if bucket == nil then
			return
		end
		bucket[child] = nil
		if next(bucket) == nil then
			delegation_children[group] = nil
		end
	end

	-- whether sought is reachable from node through parent edges (the cycle guard's test), read from the mirror
	-- so the walk stays consistent with what the hooks have processed; visited keeps diamonds from re-walking
	-- shared ancestry.
	local function delegation_reaches(node: Entity, sought: Entity, visited: { [Entity]: true }): boolean
		if node == sought then
			return true
		end
		if visited[node] ~= nil then
			return false
		end
		visited[node] = true
		local parents = delegation_parents[node]
		if parents == nil then
			return false
		end
		for _, parent in parents do
			if delegation_reaches(parent, sought, visited) then
				return true
			end
		end
		return false
	end

	-- the tail every edge change shares: re-derive both gates against the current parent set, restage the entity
	-- when its self gate moved, and fan out when its exported gate did. unchanged words -- a redundant edge, or a
	-- gate that never restricted -- skip both.
	local function refresh_delegator(entity: Entity)
		local self_changed = recompute_effective(entity)
		local exported_changed = recompute_exported(entity, self_changed)
		if self_changed then
			restage_entity(entity)
		end
		if exported_changed then
			refresh_descendants(entity)
		end
	end

	-- adds one source to the entity -> group edge, returning whether the edge is new (the first source creates
	-- it; later ones only count)
	local function add_delegation_edge(entity: Entity, group: Entity): boolean
		local dense_group = dense(group)
		local sources = delegation_edge_sources[entity]
		if sources == nil then
			sources = {}
			delegation_edge_sources[entity] = sources
		end
		local count = sources[dense_group]
		if count ~= nil then
			sources[dense_group] = count + 1
			return false
		end
		sources[dense_group] = 1
		local parents = delegation_parents[entity]
		if parents == nil then
			parents = {}
			delegation_parents[entity] = parents
		end
		parents[dense_group] = group
		index_delegation_child(group, entity)
		return true
	end

	-- drops one source from the entity -> group edge, returning whether the edge died (its last source gone).
	-- the group arrives as its dense half: a pair id packs only that, and the group may already be dead
	-- mid-cascade. a missing edge is tolerated -- it is a guard undoing its own refused add, or a teardown
	-- (world:delete, world:clear) whose per-component hooks each drop what the others' walks already dropped,
	-- every edge going either way.
	local function remove_delegation_edge(entity: Entity, dense_group: number): boolean
		local sources = delegation_edge_sources[entity]
		if sources == nil then
			return false
		end
		local count = sources[dense_group]
		if count == nil then
			return false
		end
		if count > 1 then
			sources[dense_group] = count - 1
			return false
		end
		sources[dense_group] = nil
		if next(sources) == nil then
			delegation_edge_sources[entity] = nil
		end
		local parents = delegation_parents[entity] :: { [number]: Entity }
		local group = parents[dense_group]
		parents[dense_group] = nil
		if next(parents) == nil then
			delegation_parents[entity] = nil
		end
		deindex_delegation_child(group, entity)
		return true
	end

	-- the guards run before the mirror write, so the removed hook their undo fires recognizes it by the missing
	-- mirror edge. existing delegation is acyclic, so a new cycle must pass through the new edge, and the
	-- reachability walk from the group finds it.
	local function on_inherits_added(entity: Entity, id: Id)
		if id == InheritsPrivacy then
			world:remove(entity, InheritsPrivacy)
			fail(`InheritsPrivacy must be paired with a group entity! ({id_to_string(entity, world)})`)
		end

		local group = jecs.pair_second(world, id) :: Entity
		if delegation_reaches(group, entity, {}) then
			world:remove(entity, id)
			fail(
				`InheritsPrivacy delegation cannot contain cycles! ({id_to_string(entity, world)} -> {id_to_string(
					group,
					world
				)})`
			)
		end

		-- an edge the entity already holds through a relation only gains a source: nothing to re-derive
		if add_delegation_edge(entity, group) then
			refresh_delegator(entity)
		end
	end

	-- the pair id only packs the group's dense half (and the group may already be dead mid-cascade), so the edge
	-- resolves through the dense-keyed mirror. the re-derivation against the remaining edges widens (or clears)
	-- the stored words -- unless another source still holds the edge, when nothing moves.
	local function on_inherits_removed(entity: Entity, id: Id)
		if id == InheritsPrivacy then
			return
		end
		if remove_delegation_edge(entity, ECS_PAIR_SECOND(id)) then
			refresh_delegator(entity)
		end
	end

	-- the per-relation hooks behind pair(InheritsPrivacyThrough, relation), connected while any entity inherits
	-- through the relation. they fire for every pair of the relation world-wide, so an entity not inheriting
	-- through it exits on two lookups; one that does gains or loses the edge to the pair's target. a pair add
	-- closing a cycle undoes the gameplay pair itself and errors: invasive, but a containment cycle that is also
	-- a privacy cycle is a programming bug, and the alternatives are worse (erroring without the undo desyncs the
	-- world from the mirror, ignoring the edge silently widens).
	local function on_through_relation_added(entity: Entity, id: Id, relation: Component)
		if id == relation then
			return
		end
		local relations = through_relations[entity]
		if relations == nil or relations[dense(relation)] == nil then
			return
		end
		local target = jecs.pair_second(world, id) :: Entity
		if (target :: any) == 0 then
			return
		end
		if delegation_reaches(target, entity, {}) then
			world:remove(entity, id)
			fail(
				`InheritsPrivacy delegation cannot contain cycles! ({id_to_string(entity, world)} -> {id_to_string(
					target,
					world
				)}, inherited through {id_to_string(relation, world)})`
			)
		end
		if add_delegation_edge(entity, target) then
			refresh_delegator(entity)
		end
	end

	-- the removal fires before the pair leaves the archetype, so the widening restage below still walks the
	-- departing pair as one of the entity's own cells and would stage it visible again -- after the relation's
	-- own tracking hook (when the relation is networked) staged its removal. so the cell is forced back to 0
	-- afterwards, whichever order the two hooks ran in; for an untracked relation that is a no-op.
	local function on_through_relation_removed(entity: Entity, id: Id, relation: Component)
		if id == relation then
			return
		end
		local relations = through_relations[entity]
		if relations == nil or relations[dense(relation)] == nil then
			return
		end
		if remove_delegation_edge(entity, ECS_PAIR_SECOND(id)) then
			refresh_delegator(entity)
			stage_removed(id, entity)
		end
	end

	local function connect_through_hooks(relation: Component)
		local state = through_hooks[relation]
		if state ~= nil then
			state.users += 1
			return
		end
		-- through hooks.luau: a relation like ChildOf already has pair records when its first use arrives, which
		-- is exactly the unpaired-hook bug's trigger shape
		through_hooks[relation] = {
			users = 1,
			added = hooks.added(world, relation, function(entity: Entity, id: Id)
				on_through_relation_added(entity, id, relation)
			end),
			removed = hooks.removed(world, relation, function(entity: Entity, id: Id)
				on_through_relation_removed(entity, id, relation)
			end),
		}
	end

	local function disconnect_through_hooks(relation: Component)
		local state = through_hooks[relation]
		if state == nil then
			return
		end
		if state.users > 1 then
			state.users -= 1
			return
		end
		state.added()
		state.removed()
		through_hooks[relation] = nil
	end

	-- pair(InheritsPrivacyThrough, relation) on an entity: after the guards, replay the entity's existing pairs
	-- of the relation as edges (live adds arrive through the relation hooks from here on). the cycle check
	-- covers every existing target before any mirror write, so a refusal has nothing to undo but the pair:
	-- existing delegation is acyclic, so a new cycle passes through one of the new edges, and that edge's
	-- target reaches the entity over the existing mirror.
	local function on_through_added(entity: Entity, id: Id)
		if id == InheritsPrivacyThrough then
			world:remove(entity, InheritsPrivacyThrough)
			fail(`InheritsPrivacyThrough must be paired with a relation! ({id_to_string(entity, world)})`)
		end

		local dense_relation = ECS_PAIR_SECOND(id)
		if dense_relation == dense(jecs.Wildcard) then
			world:remove(entity, id)
			fail(
				`InheritsPrivacyThrough must name a concrete relation, not jecs.Wildcard! ({id_to_string(entity, world)})`
			)
		end

		local relation = jecs.pair_second(world, id) :: Component
		if not world:has(relation, pair(jecs.OnDeleteTarget, jecs.Delete)) then
			world:remove(entity, id)
			fail(
				`InheritsPrivacyThrough relations must carry pair(jecs.OnDeleteTarget, jecs.Delete)! without it a target's deletion would only remove the pair, dropping the inherited gate and widening the entity's visibility -- a leak -- where Delete deletes the entity with its target instead, as InheritsPrivacy does. ({id_to_string(
					entity,
					world
				)} -> {id_to_string(relation, world)})`
			)
		end

		for target in each_target(entity, relation) do
			if delegation_reaches(target, entity, {}) then
				world:remove(entity, id)
				fail(
					`InheritsPrivacy delegation cannot contain cycles! ({id_to_string(entity, world)} -> {id_to_string(
						target,
						world
					)}, inherited through {id_to_string(relation, world)})`
				)
			end
		end

		local relations = through_relations[entity]
		if relations == nil then
			relations = {}
			through_relations[entity] = relations
		end
		relations[dense_relation] = relation
		connect_through_hooks(relation)

		local changed = false
		for target in each_target(entity, relation) do
			if add_delegation_edge(entity, target) then
				changed = true
			end
		end
		if changed then
			refresh_delegator(entity)
		end
	end

	-- the mirror resolves the relation from the packed pair id; a missing entry is a guard undoing its own add.
	-- the edges drop by dense target so a target already dead mid-cascade still loses its edge, and the widening
	-- is correct: it was asked for.
	local function on_through_removed(entity: Entity, id: Id)
		if id == InheritsPrivacyThrough then
			return
		end
		local relations = through_relations[entity]
		if relations == nil then
			return
		end
		local dense_relation = ECS_PAIR_SECOND(id)
		local relation = relations[dense_relation]
		if relation == nil then
			return
		end
		relations[dense_relation] = nil
		if next(relations) == nil then
			through_relations[entity] = nil
		end

		local changed = false
		for dense_target in each_dense_target(entity, relation) do
			if remove_delegation_edge(entity, dense_target) then
				changed = true
			end
		end
		disconnect_through_hooks(relation)
		if changed then
			refresh_delegator(entity)
		end
	end

	-- PRIVACY CACHING

	-- writes a sanitized filter over (entity, id)'s archetype column slot directly -- never through world:set,
	-- whose hooks would restage cells and notify user listeners over a rewrite that changes no client's
	-- standing. keeping the column in lockstep with the caches is what makes world:get return the effective
	-- filter and keeps stale values from pinning departed client objects. the record is re-read per call so
	-- archetype moves between writes never leave it stale, and every caller runs after the component landed, so
	-- the slot exists. reads archetype shape like full_packet's walk: if Private ever adopts DontFragment, this
	-- write needs jecs's sparse-pair storage api instead.
	local function write_filter_value(entity: Entity, id: Id, filter: Privacy)
		local record = entity_index.sparse_array[dense(entity)]
		record.archetype.columns_map[id][record.row] = filter
	end

	-- resolves a filter into the table + per-shard words the caches store, erroring on mixed polarities.
	-- whitelist words mark the named allocated clients; blacklist words normalize into allow words (each shard's
	-- allocated word minus the named clients), with allocate_client keeping both fresh as joiners take slots.
	-- pending clients stay in the table bitless; untracked clients are pruned so later edits don't clone them
	-- back in. a blacklist that prunes to empty restricts nobody: both returns are nil so the caller removes the
	-- value instead of caching an empty table (which always means a block-everyone whitelist).
	local function sanitize_privacy(privacy: Privacy): (Privacy?, ShardMasks?)
		-- shape checks first: a non-table would fault out of next() with a bare luau message, and a truthy
		-- non-boolean would pass the polarity check and *admit* the client it names -- the one direction a filter
		-- must never fail in.
		if type(privacy) ~= "table" then
			fail(`privacy filters must be tables keyed by client! (got a {type(privacy)})`)
		end
		-- one sampled value is the polarity (the same read as privacy_is_blacklist); every other value must match
		-- it
		local _, sample = next(privacy)
		local is_blacklist = sample == false
		local masks = {} :: ShardMasks
		-- nil until the first prune; deliberately not annotated optional -- the solver can't refine the fill-if-nil
		-- pattern at the write below, so an optional type errors there
		local pruned: { [Client]: boolean }
		for client, admitted in privacy do
			if admitted ~= true and admitted ~= false then
				fail(
					`privacy filters must map each client to true (allowed) or false (disallowed)! (got a {type(
						admitted :: any
					)})`
				)
			end
			if admitted == is_blacklist then
				fail(`privacy filters cannot mix allowed (true) and disallowed (false) clients!`)
			end
			local client_index = tracked_clients[client]
			if client_index ~= nil then
				local shard = shard_of(client_index)
				local bit = slot_bit_of(client_index)
				masks[shard] = bit32.bor(masks[shard] or 0, bit)
			elseif pending_clients[client] == nil then
				if pruned == nil then
					pruned = table.clone(privacy)
				end
				pruned[client] = nil
			end
		end
		if is_blacklist then
			if pruned and next(pruned) == nil then
				return nil, nil
			end
			for shard = 1, shard_count do
				local allow = bit32.band(allocated_masks[shard], bit32.bnot(masks[shard] or 0))
				if allow ~= 0 then
					masks[shard] = allow
				else
					masks[shard] = nil
				end
			end
		end
		if pruned then
			table.freeze(pruned)
			return pruned, masks
		end
		return privacy, masks
	end

	local function clear_cached_privacy(entity: Entity, key: Component)
		local component_filters = privacy_filters[entity]
		if component_filters then
			component_filters[key] = nil
			if next(component_filters) == nil then
				privacy_filters[entity] = nil
			end
		end
		local entity_masks = allow_masks[entity]
		if entity_masks then
			entity_masks[key] = nil
			if next(entity_masks) == nil then
				allow_masks[entity] = nil
			end
		end
	end

	-- caches the filter under (entity, key) and returns the table cached: one other than the passed table means
	-- sanitization pruned, and the caller writes it back over the value. returns nil without caching when a
	-- blacklist sanitized to nothing, so the caller removes the value outright (its removed hook clears whatever
	-- this replaced).
	local function set_cached_privacy(entity: Entity, key: Component, privacy: Privacy): Privacy?
		local sanitized, masks = sanitize_privacy(privacy)
		if sanitized == nil then
			return nil
		end

		local component_filters = privacy_filters[entity]
		if component_filters == nil then
			component_filters = {}
			privacy_filters[entity] = component_filters
		end
		component_filters[key] = sanitized

		local entity_masks = allow_masks[entity]
		if entity_masks == nil then
			entity_masks = {}
			allow_masks[entity] = entity_masks
		end
		-- an empty whitelist gates with no words: blocked everywhere
		entity_masks[key] = masks :: ShardMasks
		return sanitized
	end

	-- PRIVACY HOOKS

	-- a filter on (entity, key) governs the unpaired cell and every pair using key as the relation on entity.
	-- pairs removed earlier this frame need no restage: their staged 0 already removes them.
	local function restage_privacy_cells(entity: Entity, key: Component)
		if world:has(entity, key) then
			stage_visibility(key, entity)
		end
		for target in each_target(entity, key) do
			if is_pair_target_replicable(target) then
				stage_visibility(pair(key, target), entity)
			end
		end
	end

	-- the entity-level filter changed: re-derive both gates, restage the whole entity unless it delegates and
	-- its self gate provably stayed put, and fan out over its descendants unless its exported gate did.
	local function refresh_entity_gate(entity: Entity)
		local self_changed = true
		if delegation_parents[entity] ~= nil then
			self_changed = recompute_effective(entity)
		end
		local exported_changed = recompute_exported(entity, self_changed)
		if self_changed then
			restage_entity(entity)
		end
		if exported_changed then
			refresh_descendants(entity)
		end
	end

	-- set_cached_privacy behind a revert guard: sanitize_privacy's errors fire from inside the set hook, after
	-- the offending value landed, so erroring alone would leave the world holding a filter the caches aren't
	-- honoring. revert first -- to the previous cached filter, or removing the value when a fresh add has
	-- nothing to revert to -- then rethrow. the revert re-fires on_private_set with a filter that sanitizes
	-- cleanly, so the nested run never re-enters this path.
	local function set_cached_privacy_reverting(entity: Entity, key: Component, id: Id, privacy: Privacy): Privacy?
		local ok, result = pcall(set_cached_privacy, entity, key, privacy)
		if ok then
			return result
		end
		local component_filters = privacy_filters[entity]
		local previous = if component_filters then component_filters[key] else nil
		if previous ~= nil then
			world:set(entity, id, previous)
		else
			world:remove(entity, id)
		end
		error(result, 0)
	end

	-- a sanitization that pruned warns on top of the rewrite: the failure is otherwise silent and
	-- polarity-dependent -- a pruned whitelist goes on blocking clients it meant to admit, while a blacklist
	-- pruned empty is removed outright, admitting its named clients the moment they join. both are the same
	-- ordering bug: clients must be registered through add_client before a filter names them, and before
	-- construction no client can be, so the catch-up warns for every populated pre-construction filter. only
	-- user sets warn; remove_client's departure prune never runs through sanitization. name is the filter
	-- component's, for the message.
	local function warn_pruned_clients(entity: Entity, filter: Privacy, sanitized: Privacy?, name: string)
		if sanitized == nil then
			warn(
				`the {name} blacklist named only untracked clients! it was removed outright, since it restricted nobody -- register clients through add_client before a filter names them; no client can be tracked before duplecs.server(world) constructs. ({id_to_string(
					entity,
					world
				)})`
			)
			return
		end
		local pruned = 0
		for _ in filter do
			pruned += 1
		end
		for _ in sanitized do
			pruned -= 1
		end
		warn(
			`the {name} filter named {pruned} untracked client(s)! they were pruned from it, since filters only carry tracked clients -- register clients through add_client before a filter names them; no client can be tracked before duplecs.server(world) constructs. ({id_to_string(
				entity,
				world
			)})`
		)
	end

	-- the body shared by the Private and ExportsPrivacy set hooks (added and changed alike): caches the value
	-- under key and returns whether a filter is now cached, leaving the restage to the caller. a sanitization
	-- that pruned is written back over the value (so value and cache stay one table) and warned about; a
	-- blacklist that sanitized to nothing is removed outright, its removed hook clearing whatever it replaced,
	-- and false is returned. name is the component's, for the messages. mutating here is fine: added hooks fire
	-- after the archetype move and changed hooks involve none.
	--
	-- a nil value is normalized first: absence already means unrestricted, so a present nil has no third state
	-- to name -- world:add(entity, Private) and world:set(entity, Private, nil) both land here meaning "block
	-- everyone" only by accident of an empty cache entry. rewriting to empty_whitelist keeps that meaning,
	-- failing closed. it warns rather than errors because the resulting state is what the call meant: the
	-- warning is about the spelling, and about the sibling form it can't catch -- jecs's add returns early on an
	-- entity already carrying a filter and fires no hook (see jecs.md).
	local function cache_filter_value(entity: Entity, key: Component, id: Id, privacy: Privacy?, name: string): boolean
		local filter: Privacy
		if privacy == nil then
			warn(
				`{name} filters cannot have a nil value! it now blocks every client, as an empty filter -- set one explicitly, since world:add leaves an existing filter untouched instead. ({id_to_string(
					entity,
					world
				)})`
			)
			write_filter_value(entity, id, empty_whitelist)
			-- the write fires no hooks, so cache it here: a value with no cache behind it would read as no filter,
			-- failing open
			filter = empty_whitelist
		else
			filter = privacy
		end
		-- a non-table must not reach table.isfrozen (a bare luau fault, leaving the value with nothing cached);
		-- sanitize_privacy's shape check names it through the revert guard
		if type(filter) == "table" and table.isfrozen(filter) ~= true then
			table.freeze(filter)
		end
		local sanitized = set_cached_privacy_reverting(entity, key, id, filter)
		if sanitized == nil then
			warn_pruned_clients(entity, filter, nil, name)
			world:remove(entity, id)
			return false
		end
		if sanitized ~= filter then
			warn_pruned_clients(entity, filter, sanitized, name)
			write_filter_value(entity, id, sanitized)
		end
		return true
	end

	-- handles both the added and changed hooks (identical work): cache under the paired component (or Existence
	-- for an unpaired Private), then restage the governed cells -- the packet diff turns each mask change into
	-- sends and removals, so no old-vs-new diffing here. an entity-level filter restages entity-wide and fans
	-- out over delegating descendants.
	local function on_private_set(entity: Entity, id: Id, privacy: Privacy?)
		if id == Private then
			if cache_filter_value(entity, Existence, id, privacy, "Private") then
				refresh_entity_gate(entity)
			end
			return
		end
		local key = jecs.pair_second(world, id)
		if cache_filter_value(entity, key, id, privacy, "Private") then
			restage_privacy_cells(entity, key)
		end
	end

	local function on_private_removed(entity: Entity, id: Id)
		if id == Private then
			clear_cached_privacy(entity, Existence)
			refresh_entity_gate(entity)
			return
		end
		local key = jecs.pair_second(world, id)
		clear_cached_privacy(entity, key)
		restage_privacy_cells(entity, key)
	end

	-- ExportsPrivacy's set hooks: the filter caches under Exported like any other, but it gates nothing on the
	-- entity itself, so only the exported words re-derive and only the delegating descendants restage. a paired
	-- add is rejected like an unpaired InheritsPrivacy (the export is entity-level only): the guard removes the
	-- pair -- which the removed hook ignores, nothing being cached under it -- and errors.
	local function on_exports_set(entity: Entity, id: Id, privacy: Privacy?)
		if id ~= ExportsPrivacy then
			world:remove(entity, id)
			fail(`ExportsPrivacy is not meant to be paired! ({id_to_string(entity, world)})`)
		end
		if cache_filter_value(entity, Exported, id, privacy, "ExportsPrivacy") then
			if recompute_exported(entity, false) then
				refresh_descendants(entity)
			end
		end
	end

	local function on_exports_removed(entity: Entity, id: Id)
		if id ~= ExportsPrivacy then
			return
		end
		clear_cached_privacy(entity, Exported)
		if recompute_exported(entity, false) then
			refresh_descendants(entity)
		end
	end

	-- PRIVACY EDITING

	-- cached blacklists are never empty (an emptied one drops out of the caches), so one sampled value is the
	-- polarity; an empty table samples nil and reads as the block-everyone whitelist it is.
	local function privacy_is_blacklist(privacy: Privacy): boolean
		local _, sample = next(privacy)
		return sample == false
	end

	-- copy-on-write: clone -> mutate -> freeze, so world:set fires the changed hook with a fresh immutable
	-- value. a client's admission is their membership XORed with the polarity, so a state change always flips
	-- membership: a named client un-names, an unnamed one gains the polarity's member value -- polarity can
	-- never flip through edits. returns nil when already in the requested state.
	local function toggle_privacy_member(
		privacy: Privacy,
		is_blacklist: boolean,
		client: Client,
		allowed: boolean
	): Privacy?
		local named = privacy[client] ~= nil
		if (named ~= is_blacklist) == allowed then
			return nil
		end
		local edited = table.clone(privacy)
		if named then
			edited[client] = nil
		else
			edited[client] = not is_blacklist
		end
		table.freeze(edited)
		return edited
	end

	-- edits one client's standing in the filter on (entity, key), backed by id. on a whitelist, allowed adds or
	-- drops membership (an emptied whitelist keeps blocking everyone); on a blacklist, disallowing names the
	-- client and allowing un-names them, the last name's removal dropping the value outright (a blacklist
	-- blocking nobody restricts nothing, and an empty table must keep meaning a block-everyone whitelist).
	-- disallowing with no filter starts a blacklist (no filter admits everyone, so the start is unambiguous);
	-- allowing requires an existing whitelist. these rules keep a filter's polarity stable under incremental
	-- edits.
	local function edit_privacy(entity: Entity, key: Component, id: Id, client: Client, allowed: boolean)
		local component_filters = privacy_filters[entity]
		local privacy = if component_filters then component_filters[key] else nil
		if privacy == nil then
			if allowed then
				-- a cached filter exists exactly when the entity holds a Private value (blacklists sanitizing to nothing
				-- are removed at set), so this is a truly absent filter
				warn(`cannot allow a client without a whitelist to add them to! set the whitelist first.`)
				return
			end
			world:set(entity, id, table.freeze({ [client] = false }))
			return
		end

		local is_blacklist = privacy_is_blacklist(privacy)
		local edited = toggle_privacy_member(privacy, is_blacklist, client, allowed)
		if edited == nil then
			return
		end
		if is_blacklist and next(edited) == nil then
			world:remove(entity, id)
			return
		end
		world:set(entity, id, edited)
	end

	-- edits one client's standing in the entity-level filter (unpaired Private), the outer gate deciding
	-- whether the whole entity replicates to that client.
	local function edit_entity_privacy(entity: Entity, client: Client, allowed: boolean)
		edit_privacy(entity, Existence, Private, client, allowed)
	end

	-- edits one client's standing in the per-component filter on (entity, component), pair(Private, component),
	-- which also gates every pair using component as a relation on the entity.
	local function edit_component_privacy(entity: Entity, component: Component, client: Client, allowed: boolean)
		edit_privacy(entity, component, pair(Private, component), client, allowed)
	end

	-- edits one client's standing in the entity's ExportsPrivacy filter, the gate narrowing what its
	-- InheritsPrivacy delegators inherit below the entity's own. the same rules as the other two: a fresh
	-- disallow starts a blacklist, which can only narrow here since the own gate still applies.
	local function edit_exported_privacy(entity: Entity, client: Client, allowed: boolean)
		edit_privacy(entity, Exported, ExportsPrivacy, client, allowed)
	end

	-- SERDES

	-- the per-world serdes store (see shared.luau / serdes.luau) validates registrations itself, pre-registered
	-- ones included, so this half needs no serdes catch-up
	local Serdes = components.Serdes

	-- CLIENT SLOTS

	-- join/leave is caller-driven. a joiner's slot is allocated and its full packet built at the tail of
	-- generate_packets, after the frame's delta has resolved, so a joiner never receives a delta diffed against
	-- a mask it lacked.
	local function add_client(client: Client)
		if tracked_clients[client] ~= nil or pending_clients[client] then
			return
		end
		pending_clients[client] = true
	end

	-- prunes the departing client from every filter, cache and component value alike: otherwise whether a stale
	-- name survived would depend on whether an edit happened in between (edits clone from the pruned cache), so
	-- a rejoin under the same value would be re-admitted or not by accident -- pruning at departure makes
	-- rejoins deterministic (a rejoiner always starts unlisted) -- and an unedited value would pin the departed
	-- client object indefinitely. copy-on-write, since cached values are frozen and callers may hold them by
	-- reference; a blacklist pruned empty is removed outright, mirroring edit_privacy, while a whitelist pruned
	-- empty stays and keeps blocking everyone. no restage: the departing bit is out of every allocated word, and
	-- no other client's admission changes.
	local function prune_privacy_filters(client: Client)
		for entity, component_filters in privacy_filters do
			for key, filter in component_filters do
				if filter[client] == nil then
					continue
				end
				local pruned = table.clone(filter)
				pruned[client] = nil
				local id: Id
				if key == Existence then
					id = Private
				elseif key == Exported then
					id = ExportsPrivacy
				else
					id = pair(Private, key)
				end
				if next(pruned) == nil and privacy_is_blacklist(filter) then
					-- removing the value clears exactly (entity, key) from the caches via the removed hook: the current keys
					-- of both loops, which stay safe to remove mid-iteration
					world:remove(entity, id)
				else
					table.freeze(pruned)
					component_filters[key] = pruned
					write_filter_value(entity, id, pruned)
				end
			end
		end
	end

	local function remove_client(client: Client)
		if pending_clients[client] then
			pending_clients[client] = nil
			prune_privacy_filters(client)
			return
		end
		local client_index = tracked_clients[client]
		if client_index == nil then
			return
		end
		tracked_clients[client] = nil
		clients_by_index[client_index] = nil
		fresh_clients[client] = nil
		client_count -= 1
		local shard = shard_of(client_index)
		local bit = slot_bit_of(client_index)
		-- leave the slot's bits in the persistent masks; packet generation ignores unallocated slots and the next
		-- joiner to reuse this bit clears them.
		local allocated = bit32.band(allocated_masks[shard], bit32.bnot(bit))
		allocated_masks[shard] = allocated
		freed_masks[shard] = bit32.bor(freed_masks[shard], bit)
		if allocated == 0 then
			-- the shard emptied: drop its mask trees (nothing reads them without occupants; a rejoiner rebuilds via
			-- its full packet). the allow words keep their stale bits for the freed-slot sweep.
			next_visibilities[shard] = nil
			last_visibilities[shard] = nil
			while shard_count > 0 and allocated_masks[shard_count] == 0 do
				shard_count -= 1
			end
		end
		-- after the slot bookkeeping, so any restage triggered by a pruned-empty blacklist's removal runs against
		-- the post-departure allocated words
		prune_privacy_filters(client)
	end

	-- true from add_client until remove_client, pending joiners included: a pending client is registered
	-- (filters may already name them) even though their slot only arrives at the next generate_packets.
	local function is_client_tracked(client: Client): boolean
		return tracked_clients[client] ~= nil or pending_clients[client] == true
	end

	-- declares the client world behind an allocated slot fresh -- it has never reconciled a packet from this
	-- server -- so the next generate_packets returns a full packet in place of the delta. the slot itself
	-- (filters, masks, delta baseline) is untouched: this hands an already-allocated slot to a new connection.
	-- freshness is the precondition, not a resync knob: a full carries no removals, so a world that has
	-- reconciled state would keep whatever the full doesn't name. a pending joiner is a no-op, an untracked
	-- client warns.
	local function mark_client_fresh(client: Client)
		if pending_clients[client] then
			return
		end
		if tracked_clients[client] == nil then
			warn(`cannot mark an untracked client fresh!`)
			return
		end
		fresh_clients[client] = true
	end

	-- debug introspection: the 1-based shard of an allocated client (nil while pending or untracked), for tests
	-- verifying the compaction schedule.
	local function client_shard(client: Client): number?
		local client_index = tracked_clients[client]
		if client_index == nil then
			return nil
		end
		return shard_of(client_index)
	end

	-- ALLOCATION & PACKET GENERATION

	-- both packet passes live in this nested scope for create_server's local budget: luau caps a function at 200
	-- locals, create_server sat near the cap, and nested functions have their own budget. runs once at
	-- construction, so every closure and store here is minted once and upvalue access costs what it did as
	-- create_server locals; only the two entry points escape.
	local function create_packet_generation()
		-- the per-world serdes resolver (see shared.luau / serdes.luau)
		local resolve_serdes = shared_record.resolve_serdes

		-- the packet passes' measure behind the salvage guard (see wire.measure_section_salvaging): a user encode
		-- hook that throws mid-measure no longer unwinds out of generate_packets after the resolve passes marked
		-- the frame's deltas sent -- the offending values are pruned and everything else ships. warn-and-continue;
		-- the pruned cells replicate again on their next staged change.
		local function measure_section_guarded(draft: SectionDraft): number
			local size, pruned, salvage_error = measure_section_salvaging(draft, resolve_serdes)
			if salvage_error ~= nil then
				local section_id = draft.relation or draft.component
				warn(
					`a serdes encode hook threw while encoding {id_to_string(section_id, world)}! {pruned} value(s) were dropped from this frame's packets and will not replicate until their cells next change: {salvage_error}`
				)
			end
			return size
		end

		-- the packet frame counter, cycling 0..2^32-1: every packet of one call carries it so a caller splitting
		-- packets across channels can group or order them (wrap-aware). independent of the chunk frame counter.
		local packet_frame = -1

		local function next_packet_frame(): number
			packet_frame = (packet_frame + 1) % 2 ^ 32
			return packet_frame
		end

		-- the recycling pools (see pools.luau) behind the packet passes' per-frame lists; the flat packet buffer
		-- copies or encodes all of their contents, so none escape a call.
		local pools = create_pools()
		local fetch_scratch = pools.fetch_scratch
		local release_scratch = pools.release_scratch
		local fetch_draft = pools.fetch_draft
		local release_draft = pools.release_draft
		local get_run = pools.get_run

		-- clears one masks table's swept bits for the shard, dropping the word when it zeroes (zero words are always
		-- omitted, so equal restrictions compare equal).
		local function sweep_masks_word(masks: ShardMasks, shard: number, clear: VisibilityMask)
			local word = masks[shard]
			if word == nil then
				return
			end
			local cleared = bit32.band(word, clear)
			if cleared == 0 then
				masks[shard] = nil
			else
				masks[shard] = cleared
			end
		end

		-- clears freed slots' stale marks from one shard's persistent stores: its last tree, the allow words, and
		-- the effective words (bit clears distribute over intersection). bits may carry several set bits
		-- (compaction batches per shard). entries that zero are pruned, so a present last word is always nonzero.
		local function sweep_freed_slots(shard: number, bits: VisibilityMask)
			local clear = bit32.bnot(bits)
			local shard_last_visibilities = last_visibilities[shard]
			if shard_last_visibilities then
				for _, last_component in shard_last_visibilities do
					for entity, last in last_component do
						local cleared = bit32.band(last, clear)
						if cleared == 0 then
							last_component[entity] = nil
						else
							last_component[entity] = cleared
						end
					end
				end
			end
			for _, entity_masks in allow_masks do
				for _, masks in entity_masks do
					sweep_masks_word(masks, shard, clear)
				end
			end
			for _, masks in effective_masks do
				sweep_masks_word(masks, shard, clear)
			end
			for _, masks in exported_masks do
				sweep_masks_word(masks, shard, clear)
			end
		end

		-- allocates the lowest free (shard, bit) for a pending client -- opening a new shard when every existing one
		-- is full, so allocation never fails -- sweeps a reused slot's stale bits from the persistent masks (so the
		-- joiner starts blank and full_packet rebuilds from scratch), and grants the client's bit to cached filters
		-- that admit them.
		local function allocate_client(client: Client)
			local shard = 1
			while shard <= shard_count and allocated_masks[shard] == 0xffffffff do
				shard += 1
			end
			if shard > shard_count then
				-- reopened shards keep their freed word: their allow words may still carry stale bits the per-slot sweep
				-- must clear
				shard_count = shard
				allocated_masks[shard] = 0
				if freed_masks[shard] == nil then
					freed_masks[shard] = 0
				end
			end

			local index = bit32.countrz(bit32.bnot(allocated_masks[shard]))
			local bit = bit32.lshift(1, index)
			local client_index = (shard - 1) * 32 + index
			tracked_clients[client] = client_index
			clients_by_index[client_index] = client
			client_count += 1
			allocated_masks[shard] = bit32.bor(allocated_masks[shard], bit)

			-- fresh slots never carry stale bits, so only freed slots are swept
			if bit32.band(freed_masks[shard], bit) ~= 0 then
				freed_masks[shard] = bit32.band(freed_masks[shard], bit32.bnot(bit))
				sweep_freed_slots(shard, bit)
			end

			-- grant the bit to filters admitting this client: whitelists that named them while pending (their bit
			-- didn't exist yet), and blacklists that don't name them -- this keeps blacklists' snapshot-derived allow
			-- words fresh as the population grows. allow_masks mirrors privacy_filters' keys, so the masks table
			-- always exists.
			for entity, component_filters in privacy_filters do
				local entity_masks = allow_masks[entity]
				for privacy_key, filter in component_filters do
					local admitted = filter[client]
					if admitted == nil then
						-- unnamed clients are admitted by blacklists only
						admitted = privacy_is_blacklist(filter)
					end
					if admitted then
						local masks = entity_masks[privacy_key]
						masks[shard] = bit32.bor(masks[shard] or 0, bit)
					end
				end
			end

			-- the derived words (every delegator's self gate, every exporter's exported gate) derive from the own
			-- words just refreshed, so re-derive them all, parents first. no restage: the joiner's visibility ships
			-- via their full packet, and no other client's bits moved. the exporter walk only rewrites existing keys
			-- (a store entry exists exactly while its filter is cached), so iterating the store is safe.
			if next(delegation_parents) ~= nil or next(exported_masks) ~= nil then
				local refreshed = {} :: { [Entity]: true }
				for entity in delegation_parents do
					refresh_gates(entity, refreshed)
				end
				for entity in exported_masks do
					refresh_gates(entity, refreshed)
				end
			end
		end

		-- builds a full packet for a freshly-allocated client (allocate_client must have run) and marks their bit
		-- in their shard's last masks so subsequent deltas diff correctly. walks the Replicated record's archetypes
		-- rather than per tracked component: cells only replicate on replicated subjects, so those archetypes cover
		-- every cell, and everything shape-derived (eligibility, privacy keys, pair halves read off
		-- archetype.types, value columns) resolves once per archetype, leaving per-entity work of the entity's
		-- gate, one filter word per cell, and a column read per value. only this client's bit matters, so every
		-- mask check is one band against the bit.
		local function full_packet(client: Client, this_packet_frame: number): Packet
			local client_index = tracked_clients[client] :: number
			local shard = shard_of(client_index)
			local bit = slot_bit_of(client_index)
			local sections: { SectionDraft } = fetch_scratch()
			local section_of: { [Id]: SectionDraft } = fetch_scratch()
			-- pair drafts collect per relation in their own map: one definition serving as both an unpaired component
			-- and a relation shares a key between the roles, and the two must draft separate sections
			local pair_section_of: { [Entity]: SectionDraft } = fetch_scratch()

			local shard_last_visibilities = last_visibilities[shard]
			if shard_last_visibilities == nil then
				shard_last_visibilities = {}
				last_visibilities[shard] = shard_last_visibilities
			end
			local last_existence = shard_last_visibilities[Existence]

			local replicated: { number } = fetch_scratch()
			local replicated_count = 0

			-- appends one visible cell to its section draft; relation and target ride in gen-qualified from the
			-- archetype resolve, so pair cells never pay pair_first/pair_second here.
			local function emit(component: Id, entity: Entity, relation: Entity?, target: Entity?, value: any)
				local last_component = shard_last_visibilities[component]
				if last_component == nil then
					last_component = {}
					shard_last_visibilities[component] = last_component
				end
				last_component[entity] = bit32.bor(last_component[entity] or 0, bit)

				local lists: any
				if relation ~= nil then
					local data = pair_section_of[relation]
					if data == nil then
						data = fetch_draft(nil, relation :: any)
						pair_section_of[relation] = data
						table.insert(sections, data)
					end
					lists = get_run(data, target :: any)
				else
					local data = section_of[component]
					if data == nil then
						data = fetch_draft(component :: any)
						section_of[component] = data
						table.insert(sections, data)
					end
					lists = data
				end

				if value == nil then
					local nulled = lists.nulled
					if nulled == nil then
						nulled = fetch_scratch()
						lists.nulled = nulled
					end
					table.insert(nulled, entity)
				else
					local ids = lists.ids
					local values = lists.values
					if ids == nil then
						ids = fetch_scratch()
						values = fetch_scratch()
						lists.ids = ids
						lists.values = values
					end
					table.insert(ids, entity)
					table.insert(values, value)
				end
			end

			-- the walked archetype's networked cells, parallel over 1..cell_count: the cell id as keyed in the last
			-- tree, the privacy key gating it per entity (the component, or the gen-qualified relation, doubling as
			-- emit's relation argument), the value column (tags read plain nils off jecs's shared empty column), and
			-- for pairs the gen-qualified target.
			local cell_ids: { number } = fetch_scratch()
			local cell_keys: { number } = fetch_scratch()
			local cell_columns: { { any } } = fetch_scratch()
			local cell_targets: { [number]: Entity } = fetch_scratch()

			local idr_replicated = component_index[Replicated]
			local replicated_records = (if idr_replicated ~= nil then idr_replicated.records else empty_records) :: {
				[number]: number,
			}
			local world_archetypes = world.archetypes
			for archetype_id in replicated_records do
				local archetype = world_archetypes[archetype_id]
				local entities = archetype.entities
				if #entities == 0 then
					continue
				end
				local columns_map = archetype.columns_map

				-- resolve the archetype's networked cells once: tracking and pair-half checks are per component, and a
				-- pair target's gate blocking this client blocks the cell for every subject. mirrors restage_own_cells.
				local cell_count = 0
				for _, component in archetype.types do
					local privacy_key: number
					local target: Entity? = nil
					if IS_PAIR(component) then
						local relation = tracked_relation_gens[ECS_PAIR_FIRST(component)]
						if relation == nil then
							continue
						end
						local dense_target = ECS_PAIR_SECOND(component)
						local target_gen = tracked_target_gens[dense_target]
						if target_gen == nil or is_pair_target_replicable(target_gen) ~= true then
							continue
						end
						if is_pair_mode_tracked(relation, dense_target) ~= true then
							continue
						end
						if replicated_entities[dense_target] ~= nil then
							local gate = entity_gate_masks(target_gen)
							if gate ~= nil and bit32.band(gate[shard] or 0, bit) == 0 then
								continue
							end
						end
						privacy_key = relation :: any
						target = target_gen
					elseif tracked_by[component] ~= nil then
						privacy_key = component :: any
					else
						continue
					end
					cell_count += 1
					cell_ids[cell_count] = component :: any
					cell_keys[cell_count] = privacy_key
					cell_columns[cell_count] = columns_map[component]
					-- assigned even when nil, clearing whatever the previous archetype left at this row
					cell_targets[cell_count] = target :: any
				end

				for row, entity in entities do
					-- the entity's own gate: entity_gate_masks inlined so the allow-mask fetch is shared with the cell loop
					-- below
					local entity_masks = allow_masks[entity]
					local gate = effective_masks[entity]
					if gate == nil and entity_masks ~= nil then
						gate = entity_masks[Existence]
					end
					if gate ~= nil and bit32.band(gate[shard] or 0, bit) == 0 then
						continue
					end

					replicated_count += 1
					replicated[replicated_count] = entity :: any
					if last_existence == nil then
						last_existence = {}
						shard_last_visibilities[Existence] = last_existence
					end
					last_existence[entity] = bit32.bor(last_existence[entity] or 0, bit)

					for i = 1, cell_count do
						local privacy_key = cell_keys[i]
						if entity_masks ~= nil then
							local filter = entity_masks[privacy_key :: any]
							if filter ~= nil and bit32.band(filter[shard] or 0, bit) == 0 then
								continue
							end
						end
						local target = cell_targets[i]
						emit(
							cell_ids[i] :: any,
							entity,
							if target ~= nil then privacy_key :: any else nil,
							target,
							cell_columns[i][row]
						)
					end
				end
			end

			release_scratch(cell_ids)
			release_scratch(cell_keys)
			release_scratch(cell_columns)
			release_scratch(cell_targets)

			-- measure first, then write back-to-back into one exactly-sized buffer, like finalize_node_sections: the
			-- whole snapshot encodes into a single section buffer assemble_packet stamps with one copy
			local sections_size = 0
			for _, draft in sections do
				sections_size += measure_section_guarded(draft)
			end
			local section_data = buffer.create(sections_size)
			local section_offset = 0
			local values: { { any } }? = nil
			for _, draft in sections do
				local hookless
				section_offset, hookless = write_section(section_data, section_offset, draft)
				if hookless then
					if values == nil then
						-- escapes as the packet's side array, so never pooled
						values = {}
					end
					table.insert(values :: { { any } }, hookless)
				end
				release_draft(draft, hookless)
			end
			local section_buffers: { buffer } = fetch_scratch()
			section_buffers[1] = section_data
			release_scratch(sections)
			release_scratch(section_of)
			release_scratch(pair_section_of)

			-- a joiner receives the whole live shared-name set, so every announced definition maps before the sections
			-- above resolve
			local names: { [number]: string }? = nil
			if shared_names.has_live() then
				local collected: { [number]: string } = fetch_scratch()
				shared_names.collect_live(collected)
				names = collected
			end

			local packet =
				assemble_packet(this_packet_frame, nil, replicated, names, section_buffers, sections_size, values)
			if names ~= nil then
				release_scratch(names)
			end
			release_scratch(section_buffers)
			release_scratch(replicated)
			return packet
		end

		-- reclaims the highest occupied shard once the live client count falls more than 8 below the slot capacity
		-- beneath it, so per-frame cost tracks the current population rather than the historical peak. lowest-first
		-- allocation packs joiners low, so only the stragglers of a shrink pin a high shard; the deadzone
		-- guarantees room below, and re-opening takes ~9 net joins, so a population hovering at a boundary never
		-- churns. at most one shard per call. a move is a pure server-side bit transfer, invisible to clients
		-- (packets are keyed by client object). must run at the tail of generate_packets, when next_visibilities
		-- and changed_values are empty and the last trees, allow words, and slot bookkeeping are the only stores
		-- carrying slot bits.
		local function compact_shards()
			local reclaimed = shard_count
			if client_count >= (reclaimed - 1) * 32 - 8 then
				return
			end

			-- assign each straggler the lowest free bit below the reclaimed shard, collecting reused slots' stale bits
			-- to sweep, batched per target shard
			local straggler_mask = allocated_masks[reclaimed]
			local moved_shards = {} :: { [number]: number }
			local moved_bits = {} :: { [number]: VisibilityMask }
			local swept_masks = {} :: { [number]: VisibilityMask }
			local target_shard = 1
			local stragglers = straggler_mask
			while stragglers ~= 0 do
				local old_index = bit32.countrz(stragglers)
				stragglers = bit32.band(stragglers, stragglers - 1)

				while allocated_masks[target_shard] == 0xffffffff do
					target_shard += 1
				end
				local index = bit32.countrz(bit32.bnot(allocated_masks[target_shard]))
				local bit = bit32.lshift(1, index)
				allocated_masks[target_shard] = bit32.bor(allocated_masks[target_shard], bit)
				if bit32.band(freed_masks[target_shard], bit) ~= 0 then
					freed_masks[target_shard] = bit32.band(freed_masks[target_shard], bit32.bnot(bit))
					swept_masks[target_shard] = bit32.bor(swept_masks[target_shard] or 0, bit)
				end
				moved_shards[old_index] = target_shard
				moved_bits[old_index] = bit

				local old_client_index = (reclaimed - 1) * 32 + old_index
				local client = clients_by_index[old_client_index]
				local client_index = (target_shard - 1) * 32 + index
				tracked_clients[client] = client_index
				clients_by_index[client_index] = client
				clients_by_index[old_client_index] = nil
			end

			for shard, bits in swept_masks do
				sweep_freed_slots(shard, bits)
			end

			-- transfer the last words: one walk of the reclaimed shard's tree (Existence included) moves every
			-- straggler bit to its new slot; stale bits of the shard's previously-freed slots drop with the tree.
			local reclaimed_last = last_visibilities[reclaimed]
			if reclaimed_last then
				for component, last_component in reclaimed_last do
					for entity, last in last_component do
						local moved = bit32.band(last, straggler_mask)
						while moved ~= 0 do
							local old_index = bit32.countrz(moved)
							moved = bit32.band(moved, moved - 1)
							local shard_last_visibilities = last_visibilities[moved_shards[old_index]]
							if shard_last_visibilities == nil then
								shard_last_visibilities = {}
								last_visibilities[moved_shards[old_index]] = shard_last_visibilities
							end
							local target_component = shard_last_visibilities[component]
							if target_component == nil then
								target_component = {}
								shard_last_visibilities[component] = target_component
							end
							target_component[entity] = bit32.bor(target_component[entity] or 0, moved_bits[old_index])
						end
					end
				end
				last_visibilities[reclaimed] = nil
			end

			-- moves one masks table's straggler bits to their new slots, dropping the reclaimed-shard word outright
			local function transfer_masks_word(masks: ShardMasks)
				local word = masks[reclaimed]
				if word == nil then
					return
				end
				local moved = bit32.band(word, straggler_mask)
				while moved ~= 0 do
					local old_index = bit32.countrz(moved)
					moved = bit32.band(moved, moved - 1)
					local shard = moved_shards[old_index]
					masks[shard] = bit32.bor(masks[shard] or 0, moved_bits[old_index])
				end
				masks[reclaimed] = nil
			end

			-- transfer the allow words with one walk; with the last tree gone that scrubs the shard's every slot bit,
			-- so its freed word resets too and a future reopen starts pristine.
			for _, entity_masks in allow_masks do
				for _, masks in entity_masks do
					transfer_masks_word(masks)
				end
			end

			-- the derived words transfer the same way (bit moves distribute over intersection), their stores being
			-- one level flat
			for _, masks in effective_masks do
				transfer_masks_word(masks)
			end
			for _, masks in exported_masks do
				transfer_masks_word(masks)
			end

			allocated_masks[reclaimed] = 0
			freed_masks[reclaimed] = 0
			while shard_count > 0 and allocated_masks[shard_count] == 0 do
				shard_count -= 1
			end
		end

		-- the mask trie: a cell's accumulated visibility is the node its run path reaches, so equal cross-shard
		-- visibility converges on one node. contents are per-frame: the expansion pass clears each node it leaves
		-- into a free list, and the root persists empty between calls.
		local mask_trie = {} :: MaskTrieNode
		local trie_node_pool = {} :: { MaskTrieNode }
		local trie_node_pool_count = 0

		-- advances a cell's node by one run, starting from the root at 0
		local function append_mask_run(node: VisibilityNode, run: number): MaskTrieNode
			local parent: MaskTrieNode = if node == 0 then mask_trie else node :: MaskTrieNode
			local child = parent[run]
			if child == nil then
				if trie_node_pool_count > 0 then
					child = trie_node_pool[trie_node_pool_count]
					trie_node_pool[trie_node_pool_count] = nil
					trie_node_pool_count -= 1
				else
					child = {}
				end
				parent[run] = child
			end
			return child
		end

		-- cross-shard packet groups, persistent across calls (see PacketGroup). unpaired components key by id; pair
		-- cells share one group per relation, keyed by the relation's dense half in its own store -- a generation-0
		-- component id can collide with a relation's dense id, and the two must stay distinct groups. dirty_groups
		-- lists the groups touched this frame so the bucket pass never walks the historical set; group_frame stamps
		-- touches and last_group_sweep schedules the eviction sweep that keeps both stores bounded.
		local groups = {} :: { [Id]: PacketGroup }
		local pair_groups = {} :: { [number]: PacketGroup }
		local dirty_groups = {} :: { PacketGroup }
		local dirty_group_count = 0
		local group_frame = 0
		local last_group_sweep = 0

		-- per-frame accumulators of the packet passes, grouped into one record (from when they counted against
		-- create_server's local ceiling) and aliased into locals at each pass's head. the maps persist:
		-- release_frame_state hands their inner tables back to the pool once the packets are assembled, and
		-- reset_frame_state clears whatever an errored frame stranded (the salvage guard contains user encode
		-- throws, but an internal error can still unwind mid-frame). both stay directly below so an accumulator
		-- can't be added without its reset and release in view.
		local frame_state = {
			-- entity create/delete lists keyed by global client index
			replicated_by = {} :: { [number]: { number } },
			unreplicated_by = {} :: { [number]: { number } },

			-- sections attach per accumulated-visibility node, keyed [node][group] -- the group object, so an unpaired
			-- component and a relation can never collide. with a single occupied shard the trie is skipped and the raw
			-- mask word keys instead. masks are intersected with each shard's allocated word at resolve time, so a
			-- departed client's stale bit never creates or widens a section.
			node_section_drafts = {} :: { [VisibilityNode]: { [PacketGroup]: SectionDraft } },

			-- finalize_node_sections' outputs per node: the sections encoded back-to-back into one shared buffer, its
			-- size, and the hookless sections' value arrays in write order (one array per hookless section).
			node_buffers = {} :: { [VisibilityNode]: buffer },
			node_sizes = {} :: { [VisibilityNode]: number },
			node_section_values = {} :: { [VisibilityNode]: { { any } } },

			-- per-client accumulators for the expansion pass, keyed by global client index: the buffers to stamp,
			-- their running size, and the hookless value arrays in section order (the packet's side array).
			client_buffers = {} :: { [number]: { buffer } },
			client_sizes = {} :: { [number]: number },
			client_section_values = {} :: { [number]: { { any } } },
		}

		-- the frame's freshly-announced shared names (gen-qualified id -> name), drained from the shared-name store
		-- and stamped into every allocated client's packet; nil on frames announcing nothing.
		local frame_names: { [number]: string }? = nil

		-- whether several shards are occupied this frame: with one occupied shard the trie is skipped and raw mask
		-- words key node_section_drafts directly.
		local multi_shard = false

		local function reset_frame_state()
			table.clear(frame_state.replicated_by)
			table.clear(frame_state.unreplicated_by)
			table.clear(frame_state.node_section_drafts)
			table.clear(frame_state.node_buffers)
			table.clear(frame_state.node_sizes)
			table.clear(frame_state.node_section_values)
			table.clear(frame_state.client_buffers)
			table.clear(frame_state.client_sizes)
			table.clear(frame_state.client_section_values)
			-- an errored frame's stranded table is abandoned to the GC rather than pooled; release_frame_state is what
			-- recycles it on clean frames
			frame_names = nil
			multi_shard = shard_count > 1
		end

		-- runs after assemble_client_packets: every buffer has been stamped and the lists written inline, so only
		-- the hookless value arrays in client_section_values (the packets' side arrays) outlive the frame. runs
		-- before the joiner full packets so those draw on the freed tables; node_section_drafts is already empty,
		-- finalize consumed it.
		local function release_frame_state()
			-- node_buffers holds plain buffers whose bytes were already stamped into the clients' packets, so they just
			-- drop to the GC
			table.clear(frame_state.node_buffers)
			table.clear(frame_state.node_sizes)
			local node_section_values = frame_state.node_section_values
			for _, section_values in node_section_values do
				release_scratch(section_values)
			end
			table.clear(node_section_values)
			local client_buffers = frame_state.client_buffers
			for _, buffers in client_buffers do
				release_scratch(buffers)
			end
			table.clear(client_buffers)
			table.clear(frame_state.client_sizes)
			table.clear(frame_state.client_section_values)
			local replicated_by = frame_state.replicated_by
			for _, list in replicated_by do
				release_scratch(list)
			end
			table.clear(replicated_by)
			local unreplicated_by = frame_state.unreplicated_by
			for _, list in unreplicated_by do
				release_scratch(list)
			end
			table.clear(unreplicated_by)
			if frame_names ~= nil then
				release_scratch(frame_names)
				frame_names = nil
			end
		end

		local function get_group(component: Id): PacketGroup
			local group = groups[component]
			if group == nil then
				group = {
					key = component :: any,
					frame = group_frame,
					count = 0,
					entities = {},
					values = {},
					send_nodes = {},
					removed_nodes = {},
					row_of = if multi_shard then {} else nil,
					is_tag = jecs.is_tag(world, component),
				} :: PacketGroup
				groups[component] = group
				dirty_group_count += 1
				dirty_groups[dirty_group_count] = group
			elseif group.frame ~= group_frame then
				group.frame = group_frame
				dirty_group_count += 1
				dirty_groups[dirty_group_count] = group
				if multi_shard and group.row_of == nil then
					group.row_of = {}
				end
			end
			return group
		end

		-- the shared group of every pair cell using component's relation. dense halves recycle across generations,
		-- so the gen-qualified relation and its tag-ness re-resolve on the group's first touch each frame --
		-- through the gen cache, with an untracked relation (a stop, or a relation death resolving its staged
		-- removals) recovered from the retired store and the live resolve as a last resort; targets resolve per
		-- pair id in the resolve passes.
		local function get_pair_group(component: Id): PacketGroup
			local relation_dense = ECS_PAIR_FIRST(component)
			local group = pair_groups[relation_dense]
			if group == nil then
				local relation = (
					tracked_relation_gens[relation_dense]
					or retired_relation_gens[relation_dense]
					or jecs.pair_first(world, component)
				) :: any
				local is_tag = tracked_relation_tags[relation_dense]
				if is_tag == nil then
					is_tag = if relation == 0 then false else jecs.is_tag(world, relation)
				end
				group = {
					key = relation_dense,
					frame = group_frame,
					count = 0,
					entities = {},
					values = {},
					send_nodes = {},
					removed_nodes = {},
					is_tag = is_tag,
					relation = relation,
					targets = {},
					pair_rows = if multi_shard then {} else nil,
				} :: PacketGroup
				pair_groups[relation_dense] = group
				dirty_group_count += 1
				dirty_groups[dirty_group_count] = group
			elseif group.frame ~= group_frame then
				group.frame = group_frame
				dirty_group_count += 1
				dirty_groups[dirty_group_count] = group
				local relation = (
					tracked_relation_gens[relation_dense]
					or retired_relation_gens[relation_dense]
					or jecs.pair_first(world, component)
				) :: any
				group.relation = relation
				local is_tag = tracked_relation_tags[relation_dense]
				if is_tag == nil then
					is_tag = if relation == 0 then false else jecs.is_tag(world, relation)
				end
				group.is_tag = is_tag
				if multi_shard and group.pair_rows == nil then
					group.pair_rows = {}
				end
			end
			return group
		end

		local function get_section(node: VisibilityNode, group: PacketGroup): SectionDraft
			local node_section_drafts = frame_state.node_section_drafts
			local section_drafts = node_section_drafts[node]
			if section_drafts == nil then
				section_drafts = fetch_scratch()
				node_section_drafts[node] = section_drafts
			end
			local data = section_drafts[group]
			if data == nil then
				-- a pair group's key is its dense relation half, which must never reach a wire header; the draft names
				-- only the relation
				data = fetch_draft(if group.targets then nil else group.key, group.relation)
				section_drafts[group] = data
			end
			return data
		end

		-- the one special-cased cell: the existence diff resolves into per-client create / delete lists rather than
		-- a group, and runs *before* the component cells because the returned record holds the bits deleted this
		-- frame, which drop per-component removals the client applies wholesale when deleting the entity locally.
		-- masks are shard-relative, so both are per shard.
		local function resolve_existence_diff(
			shard_next_visibilities: ShardVisibilities,
			shard_last_visibilities: ShardVisibilities,
			allocated: VisibilityMask,
			base_index: number
		): { [Entity]: VisibilityMask }
			local replicated_by = frame_state.replicated_by
			local unreplicated_by = frame_state.unreplicated_by

			-- pooled; the caller releases it once the component cells resolve
			local entity_unreplicate_masks: { [Entity]: VisibilityMask } = fetch_scratch()

			local existence_visibility = shard_next_visibilities[Existence]
			if existence_visibility then
				shard_next_visibilities[Existence] = nil
				local last_existence = shard_last_visibilities[Existence]

				for entity, new in existence_visibility do
					local old = if last_existence then last_existence[entity] or 0 else 0
					local send = bit32.band(bit32.band(new, bit32.bnot(old)), allocated)
					local removed = bit32.band(bit32.band(old, bit32.bnot(new)), allocated)

					local m = send
					while m ~= 0 do
						local index = bit32.countrz(m)
						m = bit32.band(m, m - 1)
						local list = replicated_by[base_index + index]
						if list == nil then
							list = fetch_scratch()
							replicated_by[base_index + index] = list
						end
						table.insert(list, entity :: any)
					end

					if removed ~= 0 then
						entity_unreplicate_masks[entity] = removed
						local r = removed
						while r ~= 0 do
							local index = bit32.countrz(r)
							r = bit32.band(r, r - 1)
							local list = unreplicated_by[base_index + index]
							if list == nil then
								list = fetch_scratch()
								unreplicated_by[base_index + index] = list
							end
							table.insert(list, entity :: any)
						end
					end

					-- merge existence next -> last in place, pruning hides
					if new == 0 then
						if last_existence then
							last_existence[entity] = nil
						end
					else
						if last_existence == nil then
							last_existence = {}
							shard_last_visibilities[Existence] = last_existence
						end
						last_existence[entity] = new
					end
				end

				if last_existence and next(last_existence) == nil then
					shard_last_visibilities[Existence] = nil
				end
			end

			return entity_unreplicate_masks
		end

		-- visibility cells of one shard: fold every dirty cell into its group, send / removed words accumulated
		-- into nodes. send and removed are disjoint, so a client falls into at most one per cell. a cell whose
		-- value also changed emits only its removals here; its sends defer to resolve_value_cells, run against the
		-- post-merge mask so every viewer gets the new value exactly once.
		local function resolve_visibility_cells(
			shard_next_visibilities: ShardVisibilities,
			shard_last_visibilities: ShardVisibilities,
			allocated: VisibilityMask,
			shard_key_base: number,
			entity_unreplicate_masks: { [Entity]: VisibilityMask }
		)
			for component, new_visibility in shard_next_visibilities do
				local changed = changed_values[component]
				local old_visibility = shard_last_visibilities[component]

				local is_pair = IS_PAIR(component)
				local group = if is_pair then get_pair_group(component) else get_group(component)
				local is_tag = group.is_tag
				local count = group.count
				local entities = group.entities
				local values = group.values
				local send_nodes = group.send_nodes
				local removed_nodes = group.removed_nodes
				local targets = group.targets
				local rows = group.row_of

				-- a pair whose target the client drops this frame needs no explicit removals: dropping the target locally
				-- removes the pair. a live gen-cache entry is the dense id's current tenant; a miss means the pair id
				-- carries only removals, belonging to the retired tenant, whose gen keeps the skip generation-precise
				-- across a same-frame recycle. the target-side drops are loop-invariant, so they narrow removed_allowed
				-- once here; the subject's own drop stays per entity.
				local target: Entity? = nil
				local removed_allowed = allocated
				if is_pair then
					-- the relation-level recycle signature: the relation's dense id retired one definition and re-tracked
					-- another since the last call, so the staged removals belong to the retired one. section relation ids
					-- are dense on the wire and the new definition's announcement rebinds the client's mapping before
					-- sections apply, so a shipped removal would misresolve; drop them, the client's mapping-teardown sweep
					-- (sweep_imported_cells) owns the cleanup.
					local relation_dense = ECS_PAIR_FIRST(component)
					local retired_relation = retired_relation_gens[relation_dense]
					if retired_relation ~= nil then
						local live_relation = tracked_relation_gens[relation_dense]
						if live_relation ~= nil and live_relation ~= retired_relation then
							removed_allowed = 0
						end
					end

					local dense_target = ECS_PAIR_SECOND(component)
					local retired = retired_target_gens[dense_target]
					target = tracked_target_gens[dense_target]
					if target == nil then
						-- the target died (or shed its last pair) since staging: the retired gen lets removals still name it on
						-- the wire. viewers who imported a dead target drop the pair with it, but a name-mapped target is never
						-- deleted client-side, so its viewers need the explicit removals.
						target = retired
					else
						if is_tag then
							-- a tag relation's pairs follow their target's tag-ness; the relation half is already known to be a
							-- tag
							is_tag = jecs.is_tag(world, target)
						end
						if retired ~= nil and retired ~= target then
							-- the target-level recycle signature, the relation-level one a level down: the dense id retired one
							-- tenant and re-indexed as another since the last call, so the staged removals would misresolve to the
							-- new tenant (pair-run targets are dense on the wire, rebound before sections apply) -- and in the
							-- same-subject case remove the just-added pair. drop them; the sweep owns the cleanup.
							removed_allowed = 0
						end
					end
					if target == nil then
						-- gone entirely: every viewer imported the (now dead) target and drops the pair with it locally, so no
						-- removal ships
						removed_allowed = 0
					elseif removed_allowed ~= 0 then
						local target_unrep = entity_unreplicate_masks[target]
						if target_unrep ~= nil then
							removed_allowed = bit32.band(allocated, bit32.bnot(target_unrep))
						end
					end
					-- rows correlate between shards per cell, and a pair group's rows span several pair ids, so its row maps
					-- nest per pair id
					local pair_rows = group.pair_rows
					if pair_rows then
						local pair_id_rows = pair_rows[component]
						if pair_id_rows == nil then
							pair_id_rows = fetch_scratch()
							pair_rows[component] = pair_id_rows
						end
						rows = pair_id_rows
					end
				else
					-- the unpaired-cell recycle signature: this component's tracking stopped and a different definition
					-- re-tracked the same dense id since the last call. store keys are gen-qualified so nothing aliases
					-- here, but section component ids are dense on the wire and the new definition's announcement rebinds
					-- the mapping before sections apply, so the removals would misresolve; drop them. a live entry equal to
					-- the component is a same-frame re-track of the same definition, whose genuine removals must ship.
					local component_dense = dense(component)
					if retired_relation_gens[component_dense] == component then
						local live_relation = tracked_relation_gens[component_dense]
						if live_relation ~= nil and live_relation ~= component then
							removed_allowed = 0
						end
					end
				end

				for entity, new in new_visibility do
					local old = if old_visibility then old_visibility[entity] or 0 else 0
					local deferred = changed ~= nil and changed[entity] ~= nil
					local send = if deferred then 0 else bit32.band(new, bit32.bnot(old), allocated)
					local removed = bit32.band(old, bit32.bnot(new), removed_allowed)

					-- drop removals the client applies wholesale this frame: the subject's own unreplication (the target's
					-- already narrowed removed_allowed above). per-client, so only the coinciding bits clear.
					if removed ~= 0 then
						local subj_unrep = entity_unreplicate_masks[entity]
						if subj_unrep then
							removed = bit32.band(removed, bit32.bnot(subj_unrep))
						end
					end

					if send ~= 0 or removed ~= 0 then
						local row = (if rows then rows[entity] else nil) or 0
						if row == 0 then
							count += 1
							row = count
							entities[row] = entity :: any
							send_nodes[row] = 0
							removed_nodes[row] = 0
							if targets then
								targets[row] = target :: any
							end
							if rows then
								rows[entity] = row
							end
						end
						if send ~= 0 then
							-- only the first shard to send resolves the value, so the live read runs once per cell
							if send_nodes[row] == 0 then
								local value: any = _nulled
								if not is_tag then
									local live = world:get(entity, component)
									if live ~= nil then
										value = live
									end
								end
								values[row] = value
							end
							if multi_shard then
								send_nodes[row] = append_mask_run(send_nodes[row], send + shard_key_base)
							else
								send_nodes[row] = send
							end
						end
						if removed ~= 0 then
							if multi_shard then
								removed_nodes[row] = append_mask_run(removed_nodes[row], removed + shard_key_base)
							else
								removed_nodes[row] = removed
							end
						end
					end

					-- merge next -> last in place (the value resolve below reads the post-merge mask), pruning hides. safe
					-- here because old was read above and cells are independent.
					if new == 0 then
						if old_visibility then
							old_visibility[entity] = nil
						end
					else
						if old_visibility == nil then
							old_visibility = {}
							shard_last_visibilities[component] = old_visibility
						end
						old_visibility[entity] = new
					end
				end

				group.count = count

				if old_visibility and next(old_visibility) == nil then
					shard_last_visibilities[component] = nil
				end
			end
		end

		-- value cells of one shard: every slot that currently sees the cell (post-merge mask) receives the new
		-- value. pure removals never reach here. values stay staged for the remaining shards; generate_packets
		-- clears the shared store after the shard loop.
		local function resolve_value_cells(
			shard_last_visibilities: ShardVisibilities,
			allocated: VisibilityMask,
			shard_key_base: number
		)
			for component, changed in changed_values do
				local visibility = shard_last_visibilities[component]
				if visibility == nil then
					continue
				end

				local is_pair = IS_PAIR(component)
				local group = if is_pair then get_pair_group(component) else get_group(component)
				local count = group.count
				local entities = group.entities
				local values = group.values
				local send_nodes = group.send_nodes
				local removed_nodes = group.removed_nodes
				local targets = group.targets
				local rows = group.row_of

				-- the gen-qualified target this pair id's rows carry (staged values never outlive their target: its death
				-- stages removals that drop them, so a live entry always exists), plus the per-pair-id row map
				local target: Entity? = nil
				if is_pair then
					target = tracked_target_gens[ECS_PAIR_SECOND(component)]
					local pair_rows = group.pair_rows
					if pair_rows then
						local pair_id_rows = pair_rows[component]
						if pair_id_rows == nil then
							pair_id_rows = fetch_scratch()
							pair_rows[component] = pair_id_rows
						end
						rows = pair_id_rows
					end
				end

				for entity, value in changed do
					local mask = visibility[entity]
					if mask == nil then
						continue
					end
					local send = bit32.band(mask, allocated)
					if send == 0 then
						continue
					end
					local row = (if rows then rows[entity] else nil) or 0
					if row == 0 then
						count += 1
						row = count
						entities[row] = entity :: any
						send_nodes[row] = 0
						removed_nodes[row] = 0
						if targets then
							targets[row] = target :: any
						end
						if rows then
							rows[entity] = row
						end
					end
					if send_nodes[row] == 0 then
						values[row] = value
					end
					if multi_shard then
						send_nodes[row] = append_mask_run(send_nodes[row], send + shard_key_base)
					else
						send_nodes[row] = send
					end
				end

				group.count = count
			end
		end

		-- bucket pass: each cell lands in the section keyed by its node, one insert per cell no matter how many
		-- clients see it; a pair group's cells land in their target's run within the section. consuming a group
		-- resets it for the next frame.
		local function bucket_dirty_groups()
			for n = 1, dirty_group_count do
				local group = dirty_groups[n]
				local g_count = group.count
				if g_count == 0 then
					continue
				end
				local g_entities = group.entities
				local g_values = group.values
				local g_send_nodes = group.send_nodes
				local g_removed_nodes = group.removed_nodes
				local g_targets = group.targets

				-- one-entry caches over the row loop: consecutive rows usually share their node (and pair rows their
				-- target, since one pair id's cells resolve consecutively), so a matching row reuses the previous row's
				-- lists instead of re-walking node_section_drafts. a real node is never 0, so the sentinel can't
				-- false-hit.
				local cached_send_node: VisibilityNode = 0
				local cached_send_target: number? = nil
				local cached_send_lists: any = nil
				local cached_removed_node: VisibilityNode = 0
				local cached_removed_target: number? = nil
				local cached_removed_lists: any = nil

				for i = 1, g_count do
					local entity = g_entities[i]
					local target = if g_targets then g_targets[i] else nil

					local send_node = g_send_nodes[i]
					if send_node ~= 0 then
						local value = g_values[i]
						local lists: any
						if send_node == cached_send_node and target == cached_send_target then
							lists = cached_send_lists
						else
							local data = get_section(send_node, group)
							lists = if g_targets then get_run(data, target :: number) else data
							cached_send_node = send_node
							cached_send_target = target
							cached_send_lists = lists
						end
						if value == _nulled then
							local nulled = lists.nulled
							if nulled == nil then
								nulled = fetch_scratch()
								lists.nulled = nulled
							end
							table.insert(nulled, entity)
						else
							local ids = lists.ids
							local values
							if ids == nil then
								ids = fetch_scratch()
								values = fetch_scratch()
								lists.ids = ids
								lists.values = values
							else
								values = lists.values :: { any }
							end
							table.insert(ids, entity)
							table.insert(values, value)
						end
					end

					local removed_node = g_removed_nodes[i]
					if removed_node ~= 0 then
						local lists: any
						if removed_node == cached_removed_node and target == cached_removed_target then
							lists = cached_removed_lists
						else
							local data = get_section(removed_node, group)
							lists = if g_targets then get_run(data, target :: number) else data
							cached_removed_node = removed_node
							cached_removed_target = target
							cached_removed_lists = lists
						end
						local removed_entities = lists.removed
						if removed_entities == nil then
							removed_entities = fetch_scratch()
							lists.removed = removed_entities
						end
						table.insert(removed_entities, entity)
					end
				end

				group.count = 0
				table.clear(g_values)
				local row_of = group.row_of
				if row_of then
					table.clear(row_of)
				end
				local pair_rows = group.pair_rows
				if pair_rows then
					for _, pair_id_rows in pair_rows do
						release_scratch(pair_id_rows)
					end
					table.clear(pair_rows)
				end
			end
			dirty_group_count = 0
		end

		-- finalize pass: measure every draft of a node, then encode them back-to-back into one exactly-sized buffer
		-- the whole node shares, so assembly stamps it into each sharing client with one copy however many sections
		-- it carries.
		local function finalize_node_sections()
			local node_section_drafts = frame_state.node_section_drafts
			local node_section_values = frame_state.node_section_values
			local node_buffers = frame_state.node_buffers
			local node_sizes = frame_state.node_sizes
			for node, section_drafts in node_section_drafts do
				-- drop the entry before releasing anything: the fetches below may hand a released table right back, and a
				-- lingering node_section_drafts reference to it would alias
				node_section_drafts[node] = nil
				-- the drafts are collected during the measure loop so the write loop lays them out in the exact order they
				-- were measured
				local drafts: { SectionDraft } = fetch_scratch()
				local count = 0
				local size = 0
				for _, draft in section_drafts do
					count += 1
					drafts[count] = draft
					size += measure_section_guarded(draft)
				end
				local data = buffer.create(size)
				local offset = 0
				for i = 1, count do
					local draft = drafts[i]
					local hookless
					offset, hookless = write_section(data, offset, draft)
					if hookless then
						local section_values = node_section_values[node]
						if section_values == nil then
							section_values = fetch_scratch()
							node_section_values[node] = section_values
						end
						table.insert(section_values, hookless)
					end
					release_draft(draft, hookless)
				end
				release_scratch(drafts)
				release_scratch(section_drafts)
				node_buffers[node] = data
				node_sizes[node] = size
			end
		end

		-- appends one node's shared buffer to one client's accumulators; the node's buffer, size, and value arrays
		-- ride in as arguments since they are invariant across the node's clients. the value arrays append in
		-- section write order, keeping the side array aligned with the buffer. the element-wise append is
		-- deliberate: section_values holds one array per hookless section (rarely more than a handful) and the call
		-- runs once per node the client sees, so this is many appends of a short list, which table.insert wins --
		-- table.move measured 9.5% slower at high fan-out against 14-20% faster on the broadcast one-node shape
		-- (2026-08-06), with the realistic mixed benches at parity.
		local function scatter(
			client_index: number,
			node_buffer: buffer,
			node_size: number,
			section_values: { { any } }?
		)
			local client_buffers = frame_state.client_buffers
			local client_sizes = frame_state.client_sizes
			local target_buffers = client_buffers[client_index]
			if target_buffers == nil then
				target_buffers = fetch_scratch()
				client_buffers[client_index] = target_buffers
				client_sizes[client_index] = 0
			end
			client_sizes[client_index] += node_size
			table.insert(target_buffers, node_buffer)
			if section_values then
				local client_section_values = frame_state.client_section_values
				local target_section_values = client_section_values[client_index]
				if target_section_values == nil then
					-- escapes as the packet's side array, so never pooled
					target_section_values = {}
					client_section_values[client_index] = target_section_values
				end
				for i = 1, #section_values do
					table.insert(target_section_values, section_values[i])
				end
			end
		end

		-- the current trie path's decoded runs, persistent scratch for expand_node; entries past the current depth
		-- are never read.
		local path_bases = {} :: { number }
		local path_words = {} :: { number }

		local function expand_node(node: MaskTrieNode, depth: number)
			local node_buffer = frame_state.node_buffers[node]
			if node_buffer then
				local node_size = frame_state.node_sizes[node]
				local section_values = frame_state.node_section_values[node]
				for i = 1, depth do
					local base_index = path_bases[i]
					local m = path_words[i]
					while m ~= 0 do
						local index = bit32.countrz(m)
						m = bit32.band(m, m - 1)
						scatter(base_index + index, node_buffer, node_size, section_values)
					end
				end
			end
			for run, child in node do
				local child_depth = depth + 1
				path_bases[child_depth] = (run // shard_key_span - 1) * 32
				path_words[child_depth] = run % shard_key_span
				expand_node(child, child_depth)
				table.clear(child)
				trie_node_pool_count += 1
				trie_node_pool[trie_node_pool_count] = child
			end
		end

		-- expansion pass: walk the trie depth-first, decoding each run once however many nodes descend from it, and
		-- scatter a node's sections to every client of every run on its path. each node the walk leaves is cleared
		-- into the free list, leaving the root empty. single-shard keys are raw mask words, expanded flat.
		local function expand_to_clients()
			if multi_shard then
				expand_node(mask_trie, 0)
				table.clear(mask_trie)
			else
				local node_sizes = frame_state.node_sizes
				local node_section_values = frame_state.node_section_values
				for mask, node_buffer in frame_state.node_buffers do
					local m = mask :: number
					local node_size = node_sizes[mask]
					local section_values = node_section_values[mask]
					while m ~= 0 do
						local index = bit32.countrz(m)
						m = bit32.band(m, m - 1)
						scatter(index, node_buffer, node_size, section_values)
					end
				end
			end
		end

		-- assembly pass: stamp each client's accumulated sections into their flat packet buffer with their create /
		-- delete lists. clients with only creates / deletes still need a packet.
		local function assemble_for(packets: { [Client]: Packet }, this_packet_frame: number, index: number)
			local client = clients_by_index[index]
			if packets[client] == nil then
				packets[client] = assemble_packet(
					this_packet_frame,
					frame_state.unreplicated_by[index],
					frame_state.replicated_by[index],
					frame_names,
					frame_state.client_buffers[index],
					frame_state.client_sizes[index] or 0,
					frame_state.client_section_values[index]
				)
			end
		end

		local function assemble_client_packets(packets: { [Client]: Packet }, this_packet_frame: number)
			for index in frame_state.client_buffers do
				assemble_for(packets, this_packet_frame, index)
			end
			for index in frame_state.replicated_by do
				assemble_for(packets, this_packet_frame, index)
			end
			for index in frame_state.unreplicated_by do
				assemble_for(packets, this_packet_frame, index)
			end
			-- shared names go to every allocated client, otherwise-empty packets included (pending joiners get them
			-- through their full packet instead)
			if frame_names ~= nil then
				for index in clients_by_index do
					assemble_for(packets, this_packet_frame, index)
				end
			end
		end

		-- builds a packet for every client in a single pass: a delta per allocated client and a full per pending
		-- client. the shard loop runs outside, each occupied shard resolving its existence diff, dirty cells, and
		-- staged values against its own words and folding each cell's per-shard send / removed words into a path
		-- through the mask trie (skipped with one occupied shard, where the raw word keys the sections directly).
		-- cell work is paid once per cell per occupied shard, and clients sharing a node have its sections, encoded
		-- once into one shared buffer, stamped into their packets with a single copy.
		local function generate_packets(): { [Client]: Packet }
			local packets = {} :: { [Client]: Packet }
			local this_packet_frame = next_packet_frame()
			group_frame += 1
			reset_frame_state()

			-- drain the name states staged since the last call; with nobody allocated there is no delta to ride, so
			-- the drain discards them (joiners get the full set)
			if shared_names.has_staged() then
				local collected: { [number]: string }? = if client_count > 0 then fetch_scratch() else nil
				shared_names.drain_staged(collected)
				frame_names = collected
			end

			local has_changed_values = next(changed_values) ~= nil

			-- resolve passes, per occupied shard: the existence diff first (the component cells drop removals against
			-- its record), then the dirty visibility cells, then the staged values.
			for shard = 1, shard_count do
				local shard_next_visibilities = next_visibilities[shard]
				local allocated = allocated_masks[shard]
				local existing_last = last_visibilities[shard]
				-- a shard resolves if it has staged visibility, or if a staged value could land in it -- which takes
				-- allocated clients, a last tree for the value's mask to match, and staged values at all
				if
					shard_next_visibilities == nil
					and (allocated == 0 or existing_last == nil or not has_changed_values)
				then
					continue
				end

				-- the shard's last tree is ensured up front so the resolve passes merge through it directly; it's pruned
				-- again at the end of the iteration if nothing landed.
				local shard_last_visibilities = existing_last
				if shard_last_visibilities == nil then
					shard_last_visibilities = {}
					last_visibilities[shard] = shard_last_visibilities
				end

				local base_index = (shard - 1) * 32
				local shard_key_base = shard * shard_key_span

				if shard_next_visibilities then
					local entity_unreplicate_masks =
						resolve_existence_diff(shard_next_visibilities, shard_last_visibilities, allocated, base_index)

					resolve_visibility_cells(
						shard_next_visibilities,
						shard_last_visibilities,
						allocated,
						shard_key_base,
						entity_unreplicate_masks
					)

					release_scratch(entity_unreplicate_masks)
					next_visibilities[shard] = nil
				end

				if allocated ~= 0 then
					resolve_value_cells(shard_last_visibilities, allocated, shard_key_base)
				end

				if next(shard_last_visibilities) == nil then
					last_visibilities[shard] = nil
				end
			end
			changed_values = {}
			-- the resolve passes above were the last readers of the gens retired since the previous call
			table.clear(retired_target_gens)
			table.clear(retired_relation_gens)

			bucket_dirty_groups()
			finalize_node_sections()
			expand_to_clients()
			assemble_client_packets(packets, this_packet_frame)
			release_frame_state()

			-- allocate pending joiners only now, after the delta has been resolved against the existing slots
			for client in pending_clients do
				pending_clients[client] = nil
				allocate_client(client)
				packets[client] = full_packet(client, this_packet_frame)
			end

			-- fresh clients' fulls build here too, where the slot's last masks exactly equal current visibility, so
			-- full_packet re-marks the same bits and the next delta diffs correctly. the full replaces whatever delta
			-- the frame assembled for the client, since it already contains everything the delta carried.
			for client in fresh_clients do
				fresh_clients[client] = nil
				packets[client] = full_packet(client, this_packet_frame)
			end

			compact_shards()

			-- eviction sweep: drop groups untouched for a full interval, so dead ids don't pin their arrays forever.
			-- safe at any frame boundary -- a group with rows was touched this frame by definition.
			if group_frame - last_group_sweep >= group_sweep_interval then
				last_group_sweep = group_frame
				for component, group in groups do
					if group_frame - group.frame >= group_sweep_interval then
						groups[component] = nil
					end
				end
				for relation_dense, group in pair_groups do
					if group_frame - group.frame >= group_sweep_interval then
						pair_groups[relation_dense] = nil
					end
				end
			end

			return packets
		end

		-- UNRELIABLE (ALWAYS-REPLICATE) PACKET GENERATION

		-- the chunk frame counter, cycling like the packet frame: clients drop chunks older than the newest
		-- reconciled (wrap-aware), so reordered delivery never snaps values backward.
		local chunk_frame = -1

		-- per-call accumulators of the unreliable pass: drafts per node keyed [node][cell id], and each node's
		-- finalized chunk list. cleared at entry so an errored call's stranded tables are abandoned to the GC, like
		-- reset_frame_state.
		local unreliable_node_drafts = {} :: { [VisibilityNode]: { [Id]: SectionDraft } }
		local unreliable_node_chunks = {} :: { [VisibilityNode]: { buffer } }

		-- the running call's escaping result map, held as an upvalue only while the expansion pass scatters into it
		-- (the pass functions are shared top-level closures, like the reliable passes')
		local unreliable_packets: { [Client]: { buffer } }? = nil

		-- the walked cell's per-shard last trees, prefetched once per cell id (false for shards holding none), plus
		-- the walk's one-entry cache: consecutive entities usually share their visibility, so the previous entity's
		-- node and draft are reused whenever the resolve matches -- single-shard by comparing the word against the
		-- cached node, multi-shard by comparing per-shard words (unreliable_cell_words, valid while
		-- unreliable_words_valid), skipping the trie walk. a cached node of 0 marks an invisible entity. entries
		-- past shard_count are stale and never read.
		local unreliable_cell_visibility = {} :: { { [Entity]: VisibilityMask } | false }
		local unreliable_cell_words = {} :: { VisibilityMask }
		local unreliable_words_valid = false
		local unreliable_cached_node: VisibilityNode = 0
		local unreliable_cached_draft: SectionDraft? = nil

		local function prefetch_unreliable_visibility(cell: Id): boolean
			local any_visible = false
			for shard = 1, shard_count do
				local shard_last_visibilities = last_visibilities[shard]
				local visibility = if shard_last_visibilities then shard_last_visibilities[cell] else nil
				if visibility ~= nil then
					unreliable_cell_visibility[shard] = visibility
					any_visible = true
				else
					unreliable_cell_visibility[shard] = false
				end
			end
			unreliable_words_valid = false
			unreliable_cached_node = 0
			unreliable_cached_draft = nil
			return any_visible
		end

		-- appends one archetype's cells of one unreliable cell id to the per-node drafts: per entity the prefetched
		-- last masks resolve to a node (the reliable pass's keying), and the live column read lands in the node's
		-- draft -- values under ids, nils under nulled. masks intersect the allocated words so a departed client's
		-- stale bit never creates or widens a chunk; a cell with no last mask is invisible (or its membership add
		-- still in flight) and skips. cell is the mask-store row and draft key; component / relation / target are
		-- the draft's wire naming.
		local function accumulate_unreliable_archetype(
			entities: { any },
			column: { any },
			cell: Id,
			component: number?,
			relation: number?,
			target: number?
		)
			for row, entity in entities do
				local node: VisibilityNode
				if multi_shard then
					-- probe the shards' words against the previous entity's: a full match reuses the cached node with no
					-- trie walk (0 included, an invisible run); the first divergence replays the equal prefix into the trie
					-- and the loop appends inline from there
					local same = unreliable_words_valid
					local accumulated: VisibilityNode = 0
					for shard = 1, shard_count do
						local word = 0
						local visibility = unreliable_cell_visibility[shard]
						if visibility ~= false then
							local mask = (visibility :: { [Entity]: VisibilityMask })[entity]
							if mask ~= nil then
								word = bit32.band(mask, allocated_masks[shard])
							end
						end
						if same then
							if unreliable_cell_words[shard] ~= word then
								same = false
								unreliable_cell_words[shard] = word
								for s = 1, shard - 1 do
									local prefix = unreliable_cell_words[s]
									if prefix ~= 0 then
										accumulated = append_mask_run(accumulated, prefix + s * shard_key_span)
									end
								end
								if word ~= 0 then
									accumulated = append_mask_run(accumulated, word + shard * shard_key_span)
								end
							end
						else
							unreliable_cell_words[shard] = word
							if word ~= 0 then
								accumulated = append_mask_run(accumulated, word + shard * shard_key_span)
							end
						end
					end
					if same then
						if unreliable_cached_node == 0 then
							continue
						end
						node = unreliable_cached_node
					else
						unreliable_words_valid = true
						if accumulated == 0 then
							unreliable_cached_node = 0
							unreliable_cached_draft = nil
							continue
						end
						node = accumulated
					end
				else
					local visibility = unreliable_cell_visibility[1]
					local mask = (visibility :: { [Entity]: VisibilityMask })[entity]
					if mask == nil then
						continue
					end
					mask = bit32.band(mask, allocated_masks[1])
					if mask == 0 then
						continue
					end
					node = mask
				end

				local draft: SectionDraft
				if node == unreliable_cached_node and unreliable_cached_draft ~= nil then
					draft = unreliable_cached_draft :: SectionDraft
				else
					local drafts = unreliable_node_drafts[node]
					if drafts == nil then
						drafts = fetch_scratch()
						unreliable_node_drafts[node] = drafts
					end
					local existing = drafts[cell]
					if existing == nil then
						existing = fetch_draft(component, relation)
						existing.target = target
						drafts[cell] = existing
					end
					draft = existing
					unreliable_cached_node = node
					unreliable_cached_draft = draft
				end

				local value = column[row]
				if value == nil then
					local nulled = draft.nulled
					if nulled == nil then
						nulled = fetch_scratch()
						draft.nulled = nulled
					end
					table.insert(nulled :: { number }, entity)
				else
					local ids = draft.ids
					local values
					if ids == nil then
						ids = fetch_scratch()
						values = fetch_scratch()
						draft.ids = ids
						draft.values = values
					else
						values = draft.values :: { any }
					end
					table.insert(ids :: { number }, entity)
					table.insert(values, value)
				end
			end
		end

		-- appends one node's chunk list to one client's list; the lists escape to the caller, but the chunk buffers
		-- inside are shared by reference across the node's clients. element-wise for the same reason as scatter.
		local function unreliable_scatter(client_index: number, node_chunks: { buffer }, chunk_count: number)
			local packets = unreliable_packets :: { [Client]: { buffer } }
			local client = clients_by_index[client_index]
			local target_chunks = packets[client]
			if target_chunks == nil then
				target_chunks = {}
				packets[client] = target_chunks
			end
			for i = 1, chunk_count do
				table.insert(target_chunks, node_chunks[i])
			end
		end

		-- the unreliable expansion mirrors expand_node -- the same depth-first walk, run decoding through path_bases
		-- / path_words, and node recycling -- but scatters chunk lists instead of section buffers; kept separate so
		-- neither hot path pays for threading the other's accumulators.
		local function unreliable_expand_node(node: MaskTrieNode, depth: number)
			local node_chunks = unreliable_node_chunks[node]
			if node_chunks then
				local chunk_count = #node_chunks
				for i = 1, depth do
					local base_index = path_bases[i]
					local m = path_words[i]
					while m ~= 0 do
						local index = bit32.countrz(m)
						m = bit32.band(m, m - 1)
						unreliable_scatter(base_index + index, node_chunks, chunk_count)
					end
				end
			end
			for run, child in node do
				local child_depth = depth + 1
				path_bases[child_depth] = (run // shard_key_span - 1) * 32
				path_words[child_depth] = run % shard_key_span
				unreliable_expand_node(child, child_depth)
				table.clear(child)
				trie_node_pool_count += 1
				trie_node_pool[trie_node_pool_count] = child
			end
		end

		-- builds the always-replicate chunks for every client: every visible NetworkedUnreliable cell's current
		-- value is re-read and re-sent, so the caller sends the returned chunks through an unreliable transport
		-- every frame -- a dropped or reordered chunk costs one frame of staleness, never state. visibility is read
		-- from the last-sent masks (what each client's reliable stream holds), so membership and privacy shifts
		-- take effect here at the next generate_packets, keeping the two channels in agreement at independent
		-- cadences. cells walk per component through jecs's component records, so archetypes without unreliable
		-- cells cost nothing, and cells of equal cross-shard visibility share one serialization. chunk buffers are
		-- shared by reference across a node's clients -- never mutate them -- and clients with nothing visible are
		-- omitted.
		local function generate_unreliable_chunks(chunk_bytes: number?): { [Client]: { buffer } }
			local budget = default_chunk_bytes
			if chunk_bytes ~= nil then
				if
					chunk_bytes ~= chunk_bytes // 1
					or chunk_bytes < min_chunk_bytes
					or chunk_bytes > max_chunk_bytes
				then
					fail(
						`chunk_bytes must be an integer between {min_chunk_bytes} and {max_chunk_bytes}! (got {chunk_bytes})`
					)
				end
				budget = chunk_bytes
			end

			chunk_frame = (chunk_frame + 1) % 2 ^ 32
			local packets = {} :: { [Client]: { buffer } }
			if next(networked_unreliable) == nil then
				return packets
			end

			-- clear whatever an errored call stranded; stale trie nodes are harmless (both expansion passes clear and
			-- pool whatever they walk, and node payloads always live in the per-call maps)
			table.clear(unreliable_node_drafts)
			table.clear(unreliable_node_chunks)
			multi_shard = shard_count > 1

			local archetypes = world.archetypes

			for component in networked_unreliable do
				-- a tag definition streams only its data pairs: its bare cells and tag-target pairs are valueless, their
				-- membership already rides the reliable path, and streaming them would apply a data null via world:set,
				-- which errors on tags
				local relation_is_tag = tracked_relation_tags[dense(component)]

				-- a definition lands in this set with *any* unreliable mode, so the bare cells stream only under a plain
				-- NetworkedUnreliable tag, and each pair only when its governing mode (its target's designation, else the
				-- plain tag) is NetworkedUnreliable
				local plain_unreliable = tracked_by[component] == NetworkedUnreliable
				local designated = designations[component]

				-- unpaired cells: the component's own archetype records
				if relation_is_tag ~= true and plain_unreliable then
					local idr = component_index[component]
					if idr ~= nil and prefetch_unreliable_visibility(component) then
						for archetype_id in idr.records do
							local archetype = archetypes[archetype_id]
							local entities = archetype.entities
							if #entities > 0 then
								accumulate_unreliable_archetype(
									entities,
									archetype.columns_map[component],
									component,
									component :: any,
									nil,
									nil
								)
							end
						end
					end
				end

				-- pair cells: the relation's wildcard record covers exactly the archetypes holding its pairs, contiguous
				-- in archetype.types (see each_target), so records / counts hand each archetype its exact slice. a tag
				-- relation's tag-target pairs carry no value and skip like its bare cells.
				local idr_pair = component_index[pair(component, jecs.Wildcard)]
				if idr_pair ~= nil then
					local pair_counts = idr_pair.counts
					for archetype_id, slice_start in idr_pair.records do
						local archetype = archetypes[archetype_id]
						local entities = archetype.entities
						if #entities == 0 then
							continue
						end
						local archetype_types = archetype.types
						for i = slice_start, slice_start + pair_counts[archetype_id] - 1 do
							local cell = archetype_types[i]
							local dense_target = ECS_PAIR_SECOND(cell)
							local target = tracked_target_gens[dense_target]
							if target == nil then
								continue
							end
							-- a designated target's mode overrides the plain tag; an undesignated one falls back to it
							-- (with no designations at all the set membership already implies a plain unreliable tag)
							if designated ~= nil then
								local mode = designated[dense_target]
								if mode == nil then
									if not plain_unreliable then
										continue
									end
								elseif mode ~= NetworkedUnreliable then
									continue
								end
							end
							if relation_is_tag and jecs.is_tag(world, target) then
								continue
							end
							if prefetch_unreliable_visibility(cell) then
								accumulate_unreliable_archetype(
									entities,
									archetype.columns_map[cell],
									cell,
									nil,
									component :: any,
									target :: any
								)
							end
						end
					end
				end
			end

			if next(unreliable_node_drafts) == nil then
				return packets
			end

			-- finalize: each node's drafts encode once into its shared chunk list, behind the salvage guard (see
			-- wire.finalize_chunks): a user encode failure drops exactly the offending values instead of erroring the
			-- call, and the always-replicate cadence retries them next call, warning again until fixed.
			local chunk_scratch = buffer.create(budget)
			for node, drafts in unreliable_node_drafts do
				unreliable_node_drafts[node] = nil
				local chunks: { buffer } = fetch_scratch()
				local pruned, salvage_error, salvage_id =
					finalize_chunks(chunk_frame, drafts, budget, resolve_serdes, chunk_scratch, chunks)
				if salvage_error ~= nil then
					warn(
						`a serdes encode failed while chunking {id_to_string(salvage_id, world)}! {pruned} value(s) were dropped from this call's chunks and will not replicate until the hook or value is fixed: {salvage_error}`
					)
				end
				for _, draft in drafts do
					release_draft(draft)
				end
				release_scratch(drafts)
				unreliable_node_chunks[node] = chunks
			end

			-- expansion: append each node's chunks to its clients' lists
			unreliable_packets = packets
			if multi_shard then
				unreliable_expand_node(mask_trie, 0)
				table.clear(mask_trie)
			else
				for mask, node_chunks in unreliable_node_chunks do
					local m = mask :: number
					local chunk_count = #node_chunks
					while m ~= 0 do
						local index = bit32.countrz(m)
						m = bit32.band(m, m - 1)
						unreliable_scatter(index, node_chunks, chunk_count)
					end
				end
			end
			unreliable_packets = nil

			for node, chunks in unreliable_node_chunks do
				release_scratch(chunks)
				unreliable_node_chunks[node] = nil
			end

			return packets
		end

		return generate_packets, generate_unreliable_chunks
	end

	local generate_packets, generate_unreliable_chunks = create_packet_generation()

	-- CONSTRUCTION CATCH-UP

	-- replays schema state added through the shared component set before this instance existed, routing every
	-- pre-existing cell through the same handlers the hooks run, so construction order is invisible. no delta
	-- can be missed -- clients only exist on an instance, so only schema predates construction -- which reduces
	-- the replay to establishing the mirrors, caches, announcements, and per-definition hooks (staging against
	-- zero occupied shards writes nothing), and to firing the same guards a live add would, surfacing from the
	-- construction call. one seam: no client can be tracked before construction, so every client a
	-- pre-construction filter names is pruned from the value and the caches, each such filter warning
	-- (warn_pruned_clients).

	-- holders are collected before any handler runs: the handlers connect hooks (which structurally move the
	-- component) and the guards remove offending tags, either of which would invalidate a live world:each walk.
	local function collect_holders(id: Id): { Entity }
		local holders = {} :: { Entity }
		for entity in world:each(id) do
			table.insert(holders, entity)
		end
		return holders
	end

	-- pre-existing pairs using relation, as parallel subject / pair-id arrays. misuse pairs of the
	-- guard-bearing tags land here too; the handlers reject them exactly like a live add.
	local function collect_pair_holders(relation: Id): ({ Entity }, { Id })
		local subjects = {} :: { Entity }
		local pair_ids = {} :: { Id }
		for entity in world:each(pair(relation, jecs.Wildcard)) do
			for target in each_target(entity, relation) do
				table.insert(subjects, entity)
				table.insert(pair_ids, pair(relation, target))
			end
		end
		return subjects, pair_ids
	end

	-- designations replay before the tag's plain definitions, but either order converges: a designation replayed
	-- first tracks the definition and stages its designated pairs, and the plain tag's replay stages the rest
	-- through the already-tracked branch. misuse pairs error from here like a live add.
	local function catch_up_tracking_tag(tag: Component, on_added: (Entity, Id) -> ())
		local definitions = collect_holders(tag)
		local subjects, pair_ids = collect_pair_holders(tag)
		for index, entity in subjects do
			on_added(entity, pair_ids[index])
		end
		for _, definition in definitions do
			on_added(definition, tag)
		end
	end

	local function catch_up()
		-- filters and delegation first, since everything below reads the gates they establish; Private and
		-- ExportsPrivacy precede InheritsPrivacy so each replayed edge derives against words already cached (the
		-- reverse order converges but pays a wasted derivation per edge)
		local private_holders = collect_holders(Private)
		local private_subjects, private_pair_ids = collect_pair_holders(Private)
		for _, entity in private_holders do
			on_private_set(entity, Private, world:get(entity, Private))
		end
		for index, entity in private_subjects do
			local id = private_pair_ids[index]
			on_private_set(entity, id, world:get(entity, id))
		end

		local exports_holders = collect_holders(ExportsPrivacy)
		local exports_subjects, exports_pair_ids = collect_pair_holders(ExportsPrivacy)
		for _, entity in exports_holders do
			on_exports_set(entity, ExportsPrivacy, world:get(entity, ExportsPrivacy))
		end
		for index, entity in exports_subjects do
			-- always the paired misuse; the handler removes the pair and errors
			on_exports_set(entity, exports_pair_ids[index], nil)
		end

		local inherits_holders = collect_holders(InheritsPrivacy)
		local inherits_subjects, inherits_pair_ids = collect_pair_holders(InheritsPrivacy)
		for _, entity in inherits_holders do
			-- always the unpaired-add misuse; the handler removes the tag and errors
			on_inherits_added(entity, InheritsPrivacy)
		end
		for index, entity in inherits_subjects do
			on_inherits_added(entity, inherits_pair_ids[index])
		end

		-- through-edges replay after the direct ones, by the same rationale: each replayed relation pair derives
		-- against edges already in the mirror
		local through_holders = collect_holders(InheritsPrivacyThrough)
		local through_subjects, through_pair_ids = collect_pair_holders(InheritsPrivacyThrough)
		for _, entity in through_holders do
			-- always the unpaired-add misuse; the handler removes the tag and errors
			on_through_added(entity, InheritsPrivacyThrough)
		end
		for index, entity in through_subjects do
			on_through_added(entity, through_pair_ids[index])
		end

		-- the replicated mirror precedes the tracking walks: index_tracked_pair announces a named target only
		-- while it is unreplicated, which must see pre-existing Replicated tags
		local replicated_holders = collect_holders(Replicated)
		local replicated_subjects, replicated_pair_ids = collect_pair_holders(Replicated)
		for index, entity in replicated_subjects do
			-- always the paired misuse; the handler removes the pair and errors
			on_replicated_added(entity, replicated_pair_ids[index])
		end
		for _, entity in replicated_holders do
			on_replicated_added(entity, Replicated)
		end

		catch_up_tracking_tag(Networked, on_networked_added)
		catch_up_tracking_tag(NetworkedOnce, on_networked_once_added)
		catch_up_tracking_tag(NetworkedUnreliable, on_networked_unreliable_added)
	end

	-- SERVER INIT

	-- connects the replication hooks, then replays whatever schema state predates this instance (a schema module
	-- may have tagged definitions or added filters before duplecs.server first ran). called once before the
	-- constructor returns, so a misuse errors at the offending call site when caught live, and from the
	-- construction call when the catch-up finds it pre-existing.
	local function initialize()
		hooks.added(world, NetworkedOnce, on_networked_once_added)
		hooks.removed(world, NetworkedOnce, on_networked_once_removed)

		hooks.added(world, NetworkedUnreliable, on_networked_unreliable_added)
		hooks.removed(world, NetworkedUnreliable, on_networked_unreliable_removed)

		hooks.added(world, Networked, on_networked_added)
		hooks.removed(world, Networked, on_networked_removed)

		hooks.added(world, Replicated, on_replicated_added)
		hooks.removed(world, Replicated, on_replicated_removed)

		hooks.added(world, jecs.Name, on_name_added)
		hooks.changed(world, jecs.Name, on_name_changed)
		hooks.removed(world, jecs.Name, on_name_removed)

		hooks.added(world, Private, on_private_set)
		hooks.changed(world, Private, on_private_set)
		hooks.removed(world, Private, on_private_removed)

		hooks.added(world, ExportsPrivacy, on_exports_set)
		hooks.changed(world, ExportsPrivacy, on_exports_set)
		hooks.removed(world, ExportsPrivacy, on_exports_removed)

		hooks.added(world, InheritsPrivacy, on_inherits_added)
		hooks.removed(world, InheritsPrivacy, on_inherits_removed)

		hooks.added(world, InheritsPrivacyThrough, on_through_added)
		hooks.removed(world, InheritsPrivacyThrough, on_through_removed)

		-- seed the named mirror before the catch-up walks, whose announce decisions read it. a plain mirror write:
		-- nothing is tracked yet, so no announcement or restage is due, and the loop mutates nothing, so the live
		-- walk is safe. the order against the hook connections above is free -- their structural moves run strictly
		-- before or after this walk.
		for entity in world:each(jecs.Name) do
			named_entities[dense(entity)] = true
		end

		catch_up()
	end

	-- INSTANTIATE

	initialize()

	return {
		-- client lifecycle (must be driven by the caller)
		add_client = add_client,
		remove_client = remove_client,
		mark_client_fresh = mark_client_fresh,
		is_client_tracked = is_client_tracked,

		-- packets & chunks
		generate_packets = generate_packets,
		generate_unreliable_chunks = generate_unreliable_chunks,

		-- visibility
		is_entity_visible = is_entity_visible,
		is_component_visible = is_component_visible,
		was_entity_visible = was_entity_visible,
		was_component_visible = was_component_visible,
		get_clients_seeing = get_clients_seeing,
		get_clients_last_seeing = get_clients_last_seeing,
		edit_entity_privacy = edit_entity_privacy,
		edit_component_privacy = edit_component_privacy,
		edit_exported_privacy = edit_exported_privacy,

		-- misc
		force_replicate = force_replicate,

		-- diagnostics
		set_warn_hook = reporter.set_warn_hook,

		-- components
		Replicated = Replicated,
		Networked = Networked,
		NetworkedOnce = NetworkedOnce,
		NetworkedUnreliable = NetworkedUnreliable,
		Private = Private,
		InheritsPrivacy = InheritsPrivacy,
		InheritsPrivacyThrough = InheritsPrivacyThrough,
		ExportsPrivacy = ExportsPrivacy,
		Serdes = Serdes,

		-- debug introspection (unstable, for tests and diagnostics)
		_client_shard = client_shard,
	}
end

export type ServerInstance = typeof(create_server(nil :: any, nil :: any))

-- the memoized accessor (duplecs.server): the first call on a world constructs the instance and stores it on
-- the world's shared record (inside the world itself, see shared.luau); later calls return it. split from
-- create_server for the memo's types: the record's slot is typed unknown, so the early return needs the
-- typeof above. a constructor error propagates with nothing memoized -- a programming bug to fix, not a state
-- to recover from.
return function(world: World): ServerInstance
	local shared_record = get_shared.get_record(world)
	local instance = shared_record.server
	if instance ~= nil then
		return instance :: ServerInstance
	end
	local created = create_server(world, shared_record)
	shared_record.server = created
	return created
end
