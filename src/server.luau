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

-- private frozen-table sentinel marking a cell that is present on the entity but holds no value (a tag, or a
-- value of nil), distinct from an absent entry in a StagedValues table. compared only by table identity,
-- never against the string "_nulled", so a component whose legitimate value happens to be that string can't
-- be misrouted into a packet's nulled list. the sentinel itself never crosses the wire (nulled cells travel
-- in their own list), so only these internal comparisons ever observe it.
local _nulled = table.freeze({ _nulled = true }) :: _Nulled

-- stand-in for a component record's archetype map when the component has no record yet (nothing was ever
-- tagged with it), so record-driven walks can skip the record nil-check at their loop head.
local empty_records = table.freeze({}) :: { [number]: number }

-- the packet writers; the wire layouts and all byte-level encoding live in wire.luau.
local measure_section_salvaging = wire.measure_section_salvaging
local write_section = wire.write_section
local assemble_packet = wire.assemble_packet
local finalize_chunks = wire.finalize_chunks

-- mask runs pack (shard, word) as word + shard * 2^32 -- exact in f64 up to ~2^21 shards. a cell's
-- cross-shard visibility keys as a path of runs through a per-frame trie (see generate_packets), so equal
-- visibility always lands on the same node and one numeric run stays a plain number-keyed lookup.
local shard_key_span = 2 ^ 32

-- generate_packets calls between sweeps of the persistent packet-group store, and the staleness bar for
-- eviction, so a group untouched after its last packet survives at most two intervals.
local group_sweep_interval = 512

-- the default byte budget of one unreliable chunk: Roblox's unreliable remote limit is 1000 bytes for the
-- whole event payload, so the default leaves headroom for the buffer argument's own envelope. verified
-- empirically in Studio (2026-08-11): an incompressible buffer arrives up to exactly 996 bytes, so the
-- envelope costs 4 and 980 keeps 16 spare. pass chunk_bytes to generate_unreliable_chunks to tune it for
-- other transports.
local default_chunk_bytes = 980

-- the bounds a caller's chunk_bytes must fall in, both derived from the wire layout rather than picked (see
-- min_chunk_bytes in wire.luau): below the floor an empty chunk cannot fit one cell of a section, and above
-- the ceiling a chunk section's u16 length field cannot address its own bytes.
local min_chunk_bytes = wire.min_chunk_bytes
local max_chunk_bytes = wire.max_chunk_bytes

-- JECS ID MATH MIRRORS (so the compiler inlines)

local ECS_ENTITY_MASK = 2 ^ 24
local ECS_PAIR_OFFSET = 2 ^ 48

local function IS_PAIR(id: number): boolean
	return id > ECS_PAIR_OFFSET
end

local function ECS_PAIR_FIRST(id: number): number
	return (id - ECS_PAIR_OFFSET) // ECS_ENTITY_MASK
end

local function ECS_PAIR_SECOND(id: number): number
	return (id - ECS_PAIR_OFFSET) % ECS_ENTITY_MASK
end

-- the generation-stripping jecs.ECS_ID, under the name its server call sites use
local function dense(id: number): number
	return id % ECS_ENTITY_MASK
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

type StagedValues = { [Entity]: _Nulled | unknown }

-- one node of the mask trie: children keyed by run (word + shard * 2^32), appended in ascending shard order
-- with zero words skipped, so a cell's cross-shard visibility resolves to exactly one node. contents are
-- per-frame; the node tables themselves recycle through a free list (see generate_packets).
type MaskTrieNode = { [number]: MaskTrieNode }

-- one accumulated-visibility node: the set of clients a cell's sections go to, in the two forms the packet
-- passes key by. with several shards occupied it is a mask-trie node; with one -- the common case -- the trie
-- is skipped and the shard's raw mask word stands in for it (0 meaning "nothing accumulated yet"). every
-- per-node store below is keyed by it, and the expansion passes decode it back into client indices.
type VisibilityNode = MaskTrieNode | number

-- per-group bucket of cells dirtied this frame; parallel arrays indexed 1..count, with each cell's send /
-- removed masks accumulated across shards as mask-trie nodes (0 until the first nonzero word; with a single
-- occupied shard the trie is skipped and the raw mask word itself is the key -- see generate_packets).
-- unpaired components each own a group; pair cells share one group per relation, with targets carrying each
-- row's gen-qualified target half, so many distinct pair(relation, target) ids cost one persistent group
-- between them. row_of correlates a cell's row between shards and is only maintained when several shards are
-- occupied -- pair groups nest it per pair id in pair_rows instead, since one relation's rows span several
-- targets (even on one entity); with one shard a cell may instead occupy two rows (a removal row and a
-- value-send row), which is harmless since their nodes never overlap. groups persist across frames, so a
-- component or relation always reuses its own arrays: row demand is only predictable per group, and a shared
-- pool would stretch every array the busiest group lands on to its length. the bucket pass consumes the rows,
-- then resets count and clears values / row_of / pair_rows so stale rows never pin user component data (rows
-- past a future count hold only numbers or pooled trie nodes, so they stay). frame marks the group's last
-- touch, driving the per-frame relation re-resolve in get_pair_group and the eviction sweep in
-- generate_packets. is_tag gates the live value read: for a pair group it holds the relation's tag-ness -- a
-- data relation types every pair as data, while a tag relation's pairs follow their target, re-checked per
-- pair id in the resolve passes.
type PacketGroup = {
	-- the group store's key: the component id for unpaired groups, the relation's dense half for pair groups --
	-- never a wire id (the drafts name only the component or relation)
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
	pair_rows: { [number]: { [Entity]: number } }?,
}

-- accumulation shape shared by full_packet and the bucket pass, encoded into one section of the packet buffer
-- by wire.measure_section / write_section (which own the types): unpaired drafts carry their lists directly,
-- pair drafts group cells into per-target runs. drafts, runs, and their lists recycle through the pools
-- (pools.luau) once encoded, with one escape: whatever list write_section returns as the packet's side array
-- left by reference and is never pooled.
type SectionDraft = wire.SectionDraft

type VisibilityMask = number

-- per-shard mask words, sparse: a missing shard's word is 0.
type ShardMasks = { [number]: VisibilityMask }

-- one shard's visibility tree: mask words keyed [component][entity]. the next_visibilities /
-- last_visibilities stores hold one per occupied shard.
type ShardVisibility = { [Id]: { [Entity]: VisibilityMask } }

-- one privacy filter (see types.luau for the polarity rules)
type Privacy = types.Privacy
type PrivacyFilterCache = { [Entity]: { [Component]: Privacy } }
type AllowMaskCache = { [Entity]: { [Component]: ShardMasks } }

local function create_server(world: World, shared_record: get_shared.Record)
	-- DIAGNOSTICS

	-- the instance's warn reporter (see diagnostics.luau): the local below shadows the global warn so every
	-- warning in this half rides the shared prefix and the injectable hook (set_warn_hook in the instance
	-- table).
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

	-- synthetic cell id: entity existence flows through the per-cell visibility stores keyed by this id, never
	-- added to any entity as a real component. only the packet resolve pass treats it specially, routing its
	-- diff into the per-client replicated / unreplicated lists instead of a component group.
	local Existence = world:entity() :: Component<nil>

	-- GENERAL FUNCTIONS

	-- jecs never replaces these two containers on a live world (world:cleanup rebuilds world.archetypes, so
	-- that one is always re-read per call), so the packet and restage paths share one fetch of each
	local entity_index = world.entity_index
	local component_index = world.component_index

	local function get_components(entity_gen: Entity): { Id }
		local dense_id = dense(entity_gen :: any)
		return entity_index.sparse_array[dense_id].archetype.types :: any
	end

	local function no_targets(): Entity?
		return nil
	end

	-- note: jecs 0.11.0 still has no builtin target iterator; replace this if a later version adds one. this
	-- reads the same internals world:target resolves per call -- same-relation pairs sit contiguously in
	-- archetype.types (pair ids pack as 2^48 + relation * 2^24 + target and types is sorted, so one relation's
	-- pairs form one numeric range), with the relation's wildcard record holding each archetype's slice start
	-- (records) and length (counts) -- so the shared lookups run once per entity rather than once per target.
	-- the slice is snapshotted up front where world:target reads live state per index; no caller moves the
	-- entity mid-iteration. like world:target, a dead target resolves to nil and ends the caller's loop.
	local function each_target(entity: Entity, relation: Id): () -> Entity?
		local record = entity_index.sparse_array[dense(entity :: any)]
		local idr = component_index[pair(relation, jecs.Wildcard) :: any]
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
			return jecs.entity_index_get_alive(entity_index :: any, ECS_PAIR_SECOND(pair_id :: any) :: any) :: any
		end
	end

	-- VISIBILITY STATE

	-- entities with Replicated. note: cleared while the removed hook runs, so it reads false slightly earlier
	-- than world:has would.
	local replicated_entities = {} :: { [Entity]: true }

	-- entities with a jecs.Name, mirrored by the name hooks initialize connects (seeded at construction) so
	-- pair-target replicability stays a table lookup. note: cleared while the removed hook runs, so it reads
	-- false slightly earlier than world:has would -- exactly when the restage must see the target as unnamed.
	local named_entities = {} :: { [Entity]: true }

	-- tracked components, mapped to whichever of Networked, NetworkedOnce, and NetworkedUnreliable owns the
	-- tracking (the three are exclusive). networking a component also networks pairs using it as the relation.
	-- the owner is also how a tracking tag's removed hook recognizes a removal as its own: every guard in
	-- guard_networked_added removes the tag it refused, so any removal may be that undo instead, and only the
	-- owner's genuine removal may stop the tracking (see on_tracking_tag_removed).
	local tracked_by = {} :: { [Component]: Component }

	-- gen-qualified ids of the tracked components, keyed by dense id and maintained alongside tracked_by by
	-- start_tracking_component / stop_tracking_component: packed pair ids only carry their relation's dense
	-- half, so the pair resolve paths would otherwise pay jecs.pair_first per staged change. dense ids are
	-- unique among live entities and a pair's relation is always alive (jecs removes the pairs when it dies), so
	-- a hit is always the pair's live relation. stopping a relation's tracking moves its entry to
	-- retired_relation_gens until the next generate_packets (which clears it alongside retired_target_gens): the
	-- removals staged at stop time resolve after the relation may already be dead -- world:delete on a tracked
	-- relation runs the whole stop mid-death -- and the live resolve would name a dead relation as 0 (or as the
	-- dense id's next tenant), so clients would skip the section and keep the pairs.
	local tracked_relation_gens = {} :: { [number]: Component }
	local retired_relation_gens = {} :: { [number]: Component }

	-- tag-ness of the tracked relations, keyed by dense id and maintained alongside tracked_relation_gens:
	-- get_pair_group re-derives its relation's tag-ness every frame the relation's pairs dirty, and a
	-- definition's tag-ness is fixed before use (jecs itself snapshots it per pair record at first
	-- instantiation), so the cached read spares a world walk per relation per frame. relations without an entry
	-- (retired or never tracked) fall back to the live jecs.is_tag read.
	local tracked_relation_tags = {} :: { [number]: boolean }

	-- reverse index of live tracked-relation pair cells by dense target id: [dense target][pair id] = subject
	-- count. maintained by the per-component hooks (and the on_networked_added/removed catch-up walks), so it
	-- covers every pair whose relation is tracked regardless of the target's current replicability -- restaging
	-- on a target's visibility shift is exactly the moment that replicability changes. keyed dense because the
	-- removed hooks can fire with the target already dead (pair ids only pack dense halves); a dead target's
	-- cells are all removed by jecs before its dense id can recycle, so a bucket never carries stale entries
	-- into a new generation.
	local tracked_pairs_by_target = {} :: { [number]: { [Id]: number } }

	-- gen-qualified ids of the targets indexed above, keyed by the same dense id and captured while the target
	-- is alive (jecs guarantees a pair's halves are alive when its id record is created). double duty: the
	-- resolve paths read it in place of jecs.pair_second for every staged pair -- every pair that reaches them
	-- is indexed, so a missing entry means the target was dead or the pair unindexed, ineligible either way --
	-- and removals resolving after the target's death recover the full id the wire (and the client's mapping)
	-- needs, which packed pair ids alone have no live way back to. during a target's death cascade a hit can
	-- briefly name the dying target, but its replicated / named mirrors clear before their hooks restage, so
	-- eligibility still resolves false. deindexing a target's last pair moves its entry to retired_target_gens,
	-- which the resolve passes read for gone targets and generate_packets clears once those passes finish.
	local tracked_target_gens = {} :: { [number]: number }
	local retired_target_gens = {} :: { [number]: number }

	-- latest privacy filter of every Private cell, keyed [entity][key]: key is the paired component, or
	-- Existence for an un-paired Private, which gates the entire entity above the per-component filters. a
	-- filter is always a table -- on_private_set normalizes a nil value into empty_whitelist below -- and an
	-- empty one blocks everyone (masks absent = open to all allocated clients, present (even with no words) =
	-- gated to exactly those bits). blacklists normalize into the same shape at sanitization -- their words are
	-- allow words too (the allocated clients they don't name) -- so every downstream reader keeps allow
	-- semantics. values are frozen by the hooks, so caching by reference is safe; edit membership via
	-- edit_privacy or replace wholesale with world:set. privacy_filters keeps the client-set tables for editing;
	-- allow_masks mirrors them as per-shard allow words (never frozen: allocate_client writes grants and sweeps
	-- into them in place). a blacklist naming only untracked clients restricts nothing, so it is never cached:
	-- on_private_set removes the value outright, exactly like edit_privacy emptying a blacklist does.
	-- remove_client prunes the departing client's key from every filter (see prune_privacy_filters), so the
	-- filters only ever name allocated and pending clients.
	--
	-- empty_whitelist is the normalized value a valueless Private is rewritten to, shared across every cell that
	-- needs one: a cached filter is only ever read, cloned (the copy-on-write edits), or replaced wholesale, so
	-- aliasing one frozen empty table between entities is safe -- the per-cell allow words beside it are the
	-- mutated half, and sanitize_privacy mints those fresh per call.
	--
	-- the cached table and the component's own value are always one table: sanitization pruning and departure
	-- pruning both write their pruned clone back over the value (see write_filter_value), so world:get always
	-- returns the effective filter.
	local empty_whitelist = table.freeze({}) :: Privacy
	local privacy_filters = {} :: PrivacyFilterCache
	local allow_masks = {} :: AllowMaskCache

	-- privacy delegation state (see PRIVACY DELEGATION for the derivations). delegation_parents mirrors the live
	-- pair(InheritsPrivacy, group) pairs (entity -> its groups), maintained by the InheritsPrivacy hooks -- like
	-- the replicated/named mirrors it reads correctly while a removal hook runs, when world:target would still
	-- see the old pair. the inner map keys each group by its dense id, carrying the gen-qualified group as the
	-- value: the removed hook must resolve which edge died from the packed pair id alone (its target half is
	-- dense, and the group may already be dead mid-cascade), and dense ids can't alias among one entity's edges --
	-- pair halves are alive when added, and a group's death removes its edges (the Delete policy deletes the
	-- delegators outright) before its dense id can recycle. effective_masks is the derived word store only
	-- delegating entities occupy: effective(entity) = own(entity) intersect effective(every parent), with an
	-- entry absent when nothing the entity inherits restricts (absent = open to every allocated client, exactly
	-- like allow_masks). own words stay in allow_masks untouched -- the grant loop, the freed-slot sweeps, and
	-- compaction rely on each cached word mapping 1:1 to one filter's membership table -- and the hot readers
	-- take effective over own via entity_gate_masks.
	local delegation_parents = {} :: { [Entity]: { [number]: Entity } }
	-- reverse of delegation_parents (group -> its delegating entities), keyed by the full group entity: the
	-- descendant fan-out iterates this live child set directly instead of a world:each(pair(InheritsPrivacy,
	-- group)) query per edited group, maintained in lockstep at every delegation_parents write.
	local delegation_children = {} :: { [Entity]: { [Entity]: true } }
	local effective_masks = {} :: { [Entity]: ShardMasks }

	-- client slots: each client gets a (shard, bit) pair so every stored mask stays a single 32-bit word and all
	-- mask math stays native bit32; shards are numbered from 1 so shard-keyed tables keep their entries in the
	-- array part (a [0] key always lands in the hash part), and shard s holds the clients with global indices
	-- (s-1)*32 .. (s-1)*32+31. tracked_clients maps client -> global index ((shard - 1) * 32 + bit index);
	-- clients_by_index is the inverse for the packet scatter. pending_clients holds joiners awaiting a slot and
	-- full packet, both granted at the tail of generate_packets. client_count counts allocated slots and feeds
	-- the compaction deadzone.
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

	-- per-shard allocation words: allocated_masks[shard] is the union of the shard's live slot bits. an entry
	-- exists for every shard ever opened and is never removed; shard_count bounds the shard loops and shrinks
	-- past empty top shards. freed_masks accumulates bits freed by remove_client whose stale marks may still
	-- linger in the allow words; allocate_client sweeps a slot clean only when reusing one. compact_shards
	-- reclaims the top shard outright when the population shrinks far enough, scrubbing its every slot bit
	-- (freed word included).
	local allocated_masks = {} :: { [number]: VisibilityMask }
	local freed_masks = {} :: { [number]: VisibilityMask }
	local shard_count = 0

	-- per-cell state: the mask stores are paged per shard -- keyed [shard][component][entity], each word
	-- covering that shard's 32 clients -- while staged values stay client-agnostic, keyed [component][entity]
	-- (values are staged once per change no matter how many shards can see the cell). next_visibilities: current
	-- masks of cells whose visibility changed this frame (presence is the dirty flag); last_visibilities: masks
	-- last sent, diffed against at packet generation; component_changes: staged values of changed cells visible
	-- to someone. rule: next ?? last must *always* reflect the current visibility. entity existence is itself a
	-- cell keyed by Existence (a present 0 is a pending delete): a bit gained is a create, a bit cleared is a
	-- delete.
	local next_visibilities = {} :: { [number]: ShardVisibility }
	local last_visibilities = {} :: { [number]: ShardVisibility }
	local component_changes = {} :: { [Id]: StagedValues }

	-- VISIBILITY CHECKERS

	local function is_pair_target_replicable(target: Entity)
		return replicated_entities[target] ~= nil or named_entities[target] ~= nil
	end

	-- resolves whether the component is replication-eligible, the privacy key gating it per entity, and (for
	-- pair ids) the gen-qualified target half. pair halves resolve through the dense-keyed gen caches instead of
	-- jecs.pair_first/pair_second: every pair that reaches here is indexed, so a missing entry is a dead half or
	-- an untracked relation -- ineligible either way.
	local function resolve_component_eligibility(component: Id): (boolean, Id, Entity?)
		if IS_PAIR(component :: any) then
			local target = tracked_target_gens[ECS_PAIR_SECOND(component :: any)]
			if target == nil or is_pair_target_replicable(target :: any) ~= true then
				return false, component, nil
			end

			local relation = tracked_relation_gens[ECS_PAIR_FIRST(component :: any)]
			if relation == nil then
				return false, component, nil
			end

			return true, relation, target :: any
		end

		if tracked_by[component] == nil then
			return false, component, nil
		end

		return true, component, nil
	end

	-- reads the target gen cache, so a pair must be indexed before it is checked (the added hooks and the
	-- tracking catch-up walks index first). pair-ness is a precondition, not a check: every caller passes a pair
	-- id (the hooks branch on id == component first, and the catch-up walks construct theirs), and an unpaired
	-- id's low bits would misread as a target.
	local function is_pair_replicable(pair_id: Id)
		local target = tracked_target_gens[ECS_PAIR_SECOND(pair_id :: any)]
		if target == nil then
			return false
		end
		return is_pair_target_replicable(target :: any)
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

	-- the shard-invariant half of an entity's existence visibility: whether it replicates at all, and the
	-- entity-level allow words gating it (nil when unrestricted). entity_vis_word fans the result out across
	-- shards, so staging fetches these tables once rather than per shard.
	local function entity_vis_masks(entity: Entity): (boolean, ShardMasks?)
		if replicated_entities[entity] == nil then
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

	-- the shard-invariant half of a cell's narrowing below the entity level: the per-component allow words and,
	-- for pair cells, the target's entity-level gate (delegation-aware, like the subject's own gate) -- a pair
	-- never replicates to a client who lacks the target locally. a Named (unreplicated) target is globally
	-- visible, and a replicated target with no entity-level gate is open to every allocated client; neither
	-- narrows below the entity word, so target_masks stays nil for both. the client-agnostic resolve
	-- (resolve_component_eligibility) has already run.
	local function cell_vis_masks(entity: Entity, privacy_key: Id, target: Entity?): (ShardMasks?, ShardMasks?)
		local entity_masks = allow_masks[entity]
		local cell_masks = if entity_masks then entity_masks[privacy_key] else nil
		local target_masks: ShardMasks? = nil
		if target ~= nil and replicated_entities[target] ~= nil then
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

	local function get_component_changes(component: Id): StagedValues
		local storage = component_changes[component]
		if storage == nil then
			storage = {}
			component_changes[component] = storage
		end
		return storage
	end

	local function get_next_visibility(shard: number, component: Id): { [Entity]: VisibilityMask }
		local shard_next = next_visibilities[shard]
		if shard_next == nil then
			shard_next = {}
			next_visibilities[shard] = shard_next
		end
		local visibility = shard_next[component]
		if visibility == nil then
			visibility = {}
			shard_next[component] = visibility
		end
		return visibility
	end

	local function last_visibility_of(shard: number, component: Id, entity: Entity): VisibilityMask
		local shard_last = last_visibilities[shard]
		local last = if shard_last then shard_last[component] else nil
		return if last then last[entity] or 0 else 0
	end

	-- visibility changes write the current mask only on a mismatch with last, clearing a stale entry when they
	-- match again (e.g. a whitelist toggled and reverted in one frame). value changes record only when the cell
	-- was visible to someone last pass -- newly-visible slots read the live value during the resolve pass
	-- instead.
	local function set_visibility(shard: number, component: Id, entity: Entity, cur: VisibilityMask)
		if cur == last_visibility_of(shard, component, entity) then
			local shard_next = next_visibilities[shard]
			local visibility = if shard_next then shard_next[component] else nil
			if visibility then
				visibility[entity] = nil
				if next(visibility) == nil then
					(shard_next :: any)[component] = nil
				end
			end
		else
			get_next_visibility(shard, component)[entity] = cur
		end
	end

	-- the word-math tail of visibility staging, fanning prefetched masks out across occupied shards: the loop
	-- body is only masks[shard] indexing and word math. shards with no occupants are skipped -- their mask trees
	-- are dropped when they empty, so there is nothing to stage against. callers resolve however much of the
	-- entity/cell state their loop shape lets them hoist; eligible false stages 0 everywhere (a removal-shaped
	-- restage).
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

	-- the "visible to someone" gate scans shards' last words with an early exit; a cell invisible everywhere
	-- pays the full scan, but the store only holds occupied shards' trees, so the common case exits on the first
	-- hit. a present entry is always a nonzero word: the resolve merges and the freed-slot sweep all prune
	-- entries that zero.
	local function stage_value(component: Id, entity: Entity, value: any)
		for _, shard_last in last_visibilities do
			local last = shard_last[component]
			if last ~= nil then
				if last[entity] ~= nil then
					get_component_changes(component)[entity] = value
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
		local storage = component_changes[component]
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
		local shard_next = next_visibilities[shard]
		local next_visibility = if shard_next then shard_next[component] else nil
		local staged = if next_visibility then next_visibility[entity] else nil
		local mask = if staged ~= nil then staged else last_visibility_of(shard, component, entity)
		return bit32.band(mask, slot_bit_of(client_index)) ~= 0
	end

	-- whether the entity's existence currently replicates to the client: the same current-mask test as
	-- is_component_visible, keyed by Existence. component visibility is always a subset of existence visibility,
	-- so a false here implies is_component_visible is false for every component.
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

	-- the last-sent counterpart to is_entity_visible, keyed by Existence. as with the current-mask pair,
	-- component visibility is a subset of existence visibility, so a false here implies was_component_visible is
	-- false for every component on the entity.
	local function was_entity_visible(entity: Entity, client: Client)
		return was_component_visible(entity, Existence, client)
	end

	-- enumerator core of the two client walks below: yields each client whose bit is set in the entity's
	-- existence words, shard by shard -- the slot -> client reverse walk of the point queries above. staged
	-- picks the current mask (next ?? last, is_entity_visible's read) over the last-sent one
	-- (was_entity_visible's). each shard's word resolves as the walk reaches it, banded with the allocated word --
	-- freed slots' stale marks linger in the persistent masks until reuse, and a swept bit must not enumerate a
	-- departed client -- so a set bit always resolves through clients_by_index.
	local function clients_seeing_iterator(entity: Entity, staged: boolean): () -> Client?
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
				if staged then
					local shard_next = next_visibilities[shard]
					local next_visibility = if shard_next then shard_next[Existence] else nil
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

	-- iterator over the clients the entity's existence currently replicates to -- exactly the clients
	-- is_entity_visible answers true for, without probing every tracked client -- for sight-gated side channels
	-- (an event for exactly the clients who can see the source) and for debugging privacy setups. order is slot
	-- order, an internal detail callers must not lean on. pending joiners never enumerate (no slot until their
	-- join resolves at the next generate_packets), and the words are read live as the walk advances, so finish
	-- iterating before staging visibility changes.
	local function get_clients_seeing(entity: Entity): () -> Client?
		return clients_seeing_iterator(entity, true)
	end

	-- the last-sent counterpart to get_clients_seeing, reading only the last-sent words like was_entity_visible:
	-- the clients that actually hold the entity right now, before the next generate_packets flushes the staged
	-- delta.
	local function get_clients_last_seeing(entity: Entity): () -> Client?
		return clients_seeing_iterator(entity, false)
	end

	-- SHARED NAMES

	-- the instance's shared-name store (see names.luau, which owns the announced set, the staging behind it,
	-- and the wire-shape refusals announcing warns on): named ids the client maps automatically -- tracked
	-- component definitions and named (unreplicated) pair targets -- announced as (id, name) entries in packet
	-- headers, so a client world defining the same names resolves them without set_client_entity. this half
	-- decides which ids are relevant (the tracking, Replicated, and jecs.Name hooks below call in) and drains
	-- the store at packet time. it takes the reporter's warn, so its refusals ride this instance's warn hook
	-- like every other warning here.
	local shared_names = create_names(world, warn)

	-- CHANGE TRACKING

	-- networked_unreliable is the set of components tracked via NetworkedUnreliable, whose reliable tracking is
	-- exactly NetworkedOnce's (membership, initial values, and removals ride the reliable path; no changed hook)
	-- and whose values additionally stream through generate_unreliable_chunks -- which is what the set exists
	-- for: iterating exactly them once per frame, rather than filtering tracked_by by owner. networked_cleanup
	-- holds every tracked component's hook disconnectors, whichever tag owns the tracking.
	local networked_unreliable = {} :: { [Component]: true }
	local networked_cleanup = {} :: { [Component]: { () -> () } }

	local function index_tracked_pair(pair_id: Id)
		local target = ECS_PAIR_SECOND(pair_id :: any)
		local bucket = tracked_pairs_by_target[target]
		if bucket == nil then
			bucket = {}
			tracked_pairs_by_target[target] = bucket
			local target_gen = jecs.pair_second(world, pair_id)
			if (target_gen :: any) ~= 0 then
				-- capture the gen-qualified id while the target is alive, for removals that resolve after its death
				tracked_target_gens[target] = target_gen :: any
				-- the target's first tracked pair: a named, unreplicated target is a shared definition clients should map
				-- by name (replicated targets map through their creation entry instead)
				if replicated_entities[target_gen :: any] == nil then
					shared_names.announce(target_gen :: any)
				end
			end
		end
		bucket[pair_id] = (bucket[pair_id] or 0) + 1
	end

	local function deindex_tracked_pair(pair_id: Id)
		local target = ECS_PAIR_SECOND(pair_id :: any)
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
				-- the target's last tracked pair is gone: withdraw its announced name unless it is also a tracked
				-- component definition
				local announced = shared_names.announced_id(target)
				if announced ~= nil and tracked_by[announced :: any] == nil then
					shared_names.retract(target)
				end
			end
		end
	end

	-- the tracking setup the three tracking tags share: record the owning tag, announce the component's name,
	-- stage the initial visibility of existing cells, and connect the per-component hooks. only Networked
	-- connects the changed hook -- under NetworkedOnce and NetworkedUnreliable, value changes after the add
	-- never replicate through the reliable stream, so no callback (or its lookups) runs per set.
	local function start_tracking_component(component: Component, tag: Component)
		-- record the owner first so the staging below resolves visibility correctly
		tracked_by[component] = tag
		if tag == NetworkedUnreliable then
			networked_unreliable[component] = true
		end
		local dense_id = dense(component :: any)
		tracked_relation_gens[dense_id] = component
		tracked_relation_tags[dense_id] = jecs.is_tag(world, component)

		-- a named definition announces itself so clients map it automatically
		shared_names.announce(component)

		-- stage initial visibility of existing cells; newly-visible clients read live values during the resolve
		-- pass
		for entity in world:each(component) do
			stage_visibility(component, entity)
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

		local cleanup = {
			hooks.added(world, component, function(entity: Entity, id: Id, value: any)
				-- pairs index regardless of the target's current replicability; restaging on a target's visibility shift
				-- must find them
				if id ~= component then
					index_tracked_pair(id)
				end
				if id == component or is_pair_replicable(id) then
					stage_visibility(id, entity)
					stage_value(id, entity, if value == nil then _nulled else value)
				end
			end),
			hooks.removed(world, component, function(entity: Entity, id: Id)
				if id ~= component then
					deindex_tracked_pair(id)
					-- the removal must stage whenever the target is dead or replicable; the gen caches can't answer that
					-- here (the deindex above may have just retired the gen, and a dying target's entry lingers while its
					-- mirrors clear), so this keeps the live pair_second death check. a client that never imported the
					-- target (a name-mapped one) has nothing else removing the cells locally, and the target's prior
					-- replicability is unknowable here -- staging a pair that was never visible is a no-op
					local target = jecs.pair_second(world, id)
					if (target :: any) == 0 or is_pair_target_replicable(target :: any) then
						stage_removed(id, entity)
					end
					return
				end
				stage_removed(id, entity)
			end),
		}

		if tag == Networked then
			table.insert(
				cleanup,
				hooks.changed(world, component, function(entity: Entity, id: Id, value: any)
					if id == component or is_pair_replicable(id) then
						stage_value(id, entity, if value == nil then _nulled else value)
					end
				end)
			)
		end

		networked_cleanup[component] = cleanup
	end

	local function stop_tracking_component(component: Component)
		local cleanup = networked_cleanup[component]
		if cleanup then
			for _, remove in cleanup do
				remove()
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
		local dense_id = dense(component :: any)
		-- retire the gen until the next generate_packets: the removals staged above resolve later, when the
		-- relation may be dead and the live resolve could no longer name it on the wire
		retired_relation_gens[dense_id] = tracked_relation_gens[dense_id]
		tracked_relation_gens[dense_id] = nil
		tracked_relation_tags[dense_id] = nil

		-- withdraw the announced name unless the definition doubles as a named pair target of another tracked
		-- relation
		if shared_names.announced_id(dense_id) == (component :: any) and tracked_pairs_by_target[dense_id] == nil then
			shared_names.retract(dense_id)
		end
	end

	-- the guards the Networked, NetworkedOnce, and NetworkedUnreliable add hooks share: reject a paired add
	-- (none of the three is a valid relation), reject a component already carrying one of the other two
	-- exclusive tags, and reject a Replicated component. each firing guard removes the just-added tag -- undoing
	-- the add so the matching removed hook recognizes it (see on_tracking_tag_removed) -- and errors. tag names
	-- the added tag for the exclusivity check to skip, and tag_name spells it for the messages (the caller has
	-- both at hand; on_replicated_added, which resolves its tag from tracked_by, spells it out itself). returns
	-- normally only when the add is clean; the caller then applies any tag-specific guards of its own before
	-- tracking.
	local function guard_networked_added(component: Component, id: Id, tag: Component, tag_name: string)
		if id ~= tag then
			world:remove(component, id)
			fail(`{tag_name} is not meant to be paired! ({id_to_string(component :: any, world)})`)
		end

		if
			(tag ~= Networked and world:has(component, Networked))
			or (tag ~= NetworkedOnce and world:has(component, NetworkedOnce))
			or (tag ~= NetworkedUnreliable and world:has(component, NetworkedUnreliable))
		then
			world:remove(component, tag)
			fail(
				`Networked, NetworkedOnce, and NetworkedUnreliable are exclusive! ({id_to_string(
					component :: any,
					world
				)})`
			)
		end

		if world:has(component, Replicated) then
			world:remove(component, tag)
			fail(`cannot add {tag_name} to replicated entities!`)
		end
	end

	-- the undo counterpart of those guards, shared by all three tags' removed hooks: a removal arrives
	-- identically whether the tag was genuinely removed or whether a guard above stripped an add it refused, and
	-- only the former may stop the tracking. tracked_by tells them apart -- a guard's undo is never the recorded
	-- owner, whether because another tag owns the tracking (the exclusivity guard) or because nothing does (the
	-- paired, Replicated, and tag guards all fire before tracking starts). letting an undo through would stop
	-- tracking the component still has, or, for a never-tracked component, run stop_tracking_component for an id
	-- it never tracked: the removal walks only stage no-ops there (cells the id keys were never visible, so
	-- their masks are already 0), but the gen retirement writes tracked_relation_gens[dense] (nil here) over
	-- retired_relation_gens[dense], erasing a retirement an earlier real stop on the same dense id staged this
	-- frame.
	local function on_tracking_tag_removed(component: Component, id: Id, tag: Component)
		-- a pair using the tag as its relation never owns tracking
		if id ~= tag then
			return
		end
		-- not the recorded owner: a guard's undo, not a genuine removal
		if tracked_by[component] ~= tag then
			return
		end
		stop_tracking_component(component)
	end

	-- NetworkedOnce is Networked without continuous change-tracking, for components (and pairs using them as the
	-- relation) whose value the client can simulate on its own (e.g. timers): initial values, removals, and full
	-- snapshots replicate, later value changes don't. use force_replicate to push unexpected changes. exclusive
	-- with the other two tracking tags -- adding one while another is present removes the newly added tag and
	-- errors.
	local function on_networked_once_added(component: Component, id: Id)
		guard_networked_added(component, id, NetworkedOnce, "NetworkedOnce")

		start_tracking_component(component, NetworkedOnce)
	end

	local function on_networked_once_removed(component: Component, id: Id)
		on_tracking_tag_removed(component, id, NetworkedOnce)
	end

	local function on_networked_added(component: Component, id: Id)
		guard_networked_added(component, id, Networked, "Networked")

		start_tracking_component(component, Networked)
	end

	local function on_networked_removed(component: Component, id: Id)
		on_tracking_tag_removed(component, id, Networked)
	end

	-- NetworkedUnreliable is the always-replicate mode, for values that change every frame (positions,
	-- velocities): its reliable tracking is exactly NetworkedOnce's -- membership adds with their initial value,
	-- removals, visibility shifts, and full packets all ride the reliable path, with no changed hook connected,
	-- so per-set cost is zero -- while current values are re-read and re-sent every generate_unreliable_chunks
	-- call, intended for an unreliable transport where a dropped chunk costs one frame of staleness. tags are
	-- refused: an always-streamed tag carries nothing (and chunk values require serdes hooks, which tags cannot
	-- have). exclusive with the other Networked tags, like they are with each other.
	local function on_networked_unreliable_added(component: Component, id: Id)
		guard_networked_added(component, id, NetworkedUnreliable, "NetworkedUnreliable")

		if jecs.is_tag(world, component) then
			world:remove(component, NetworkedUnreliable)
			fail(`NetworkedUnreliable cannot be added to tags! ({id_to_string(component :: any, world)})`)
		end

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

	-- the restaged entity's per-shard entity words, prefetched once by restage_entity for the per-cell loops
	-- below to stage against. entries past the current shard_count are stale and never read (every shard loop
	-- stops at shard_count). restages never nest -- each hook or fan-out restage completes before the next
	-- begins -- so one scratch array serves them all.
	local restage_entity_words = {} :: { VisibilityMask }

	-- stages one of the restaged entity's cells against the prefetched words: only the cell-level narrowing and
	-- the set_visibility writes run per cell, the entity-level fetches and word math having run once per
	-- restage.
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

	-- restage every networked cell the entity owns (unpaired components and pairs it is the subject of), for
	-- when its overall visibility shifts. the resolve mirrors resolve_component_eligibility / cell_vis_masks
	-- with the entity-invariant fetches hoisted out of the cell loop.
	local function restage_own_cells(entity: Entity)
		local entity_masks = allow_masks[entity]
		for _, component in get_components(entity) do
			if IS_PAIR(component :: any) then
				local relation = tracked_relation_gens[ECS_PAIR_FIRST(component :: any)]
				local target = tracked_target_gens[ECS_PAIR_SECOND(component :: any)]
				if relation ~= nil and target ~= nil and is_pair_target_replicable(target :: any) then
					local cell_masks = if entity_masks then entity_masks[relation] else nil
					local target_masks: ShardMasks? = nil
					if replicated_entities[target :: any] ~= nil then
						target_masks = entity_gate_masks(target :: any)
					end
					stage_restaged_cell(component, entity, cell_masks, target_masks)
				end
			elseif tracked_by[component] then
				local cell_masks = if entity_masks then entity_masks[component] else nil
				stage_restaged_cell(component, entity, cell_masks, nil)
			end
		end
	end

	-- restage networked pairs targeting this entity, for when its visibility as a target shifts. the reverse
	-- index holds exactly the live tracked-relation pairs, so this walks only the pairs that actually target the
	-- entity rather than probing every tracked relation. the pair-level resolve and the target's gate are per
	-- pair id, not per subject, so they hoist out of the subject loop; the subjects are other entities, so their
	-- own words can't ride restage_entity_words and stage per subject instead. subjects walk each pair id's
	-- component record directly (the world:each scheme without its per-call closure or per-subject call);
	-- staging never moves a subject between archetypes, so the walk is iteration-safe.
	local function restage_pairs_targeting(entity: Entity)
		local bucket = tracked_pairs_by_target[dense(entity :: any)]
		if bucket == nil then
			return
		end
		local world_archetypes = world.archetypes
		for pair_id in bucket do
			local eligible, privacy_key, target = resolve_component_eligibility(pair_id)
			local target_masks: ShardMasks? = nil
			if target ~= nil and replicated_entities[target] ~= nil then
				target_masks = entity_gate_masks(target)
			end
			local idr = component_index[pair_id :: any]
			if idr == nil then
				continue
			end
			for archetype_id in idr.records do
				for _, subject in world_archetypes[archetype_id].entities do
					local replicated, subject_masks = entity_vis_masks(subject :: any)
					local cell_masks: ShardMasks? = nil
					if replicated and eligible then
						local subject_allow_masks = allow_masks[subject :: any]
						cell_masks = if subject_allow_masks then subject_allow_masks[privacy_key] else nil
					end
					stage_visibility_masks(
						pair_id,
						subject :: any,
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
			fail(`Replicated is not meant to be paired! ({id_to_string(entity :: any, world)})`)
		end

		-- any of the three tracking tags refuses Replicated (see guard_networked_added for the mirror direction),
		-- so the message names whichever one owns the tracking. spelled out here rather than read from a shared
		-- table: create_server sits at luau's 200-local ceiling, and these locals are the hook's own.
		local tracking_tag = tracked_by[entity]
		if tracking_tag then
			world:remove(entity, Replicated)
			local tag_name = if tracking_tag == Networked
				then "Networked"
				elseif tracking_tag == NetworkedOnce then "NetworkedOnce"
				else "NetworkedUnreliable"
			fail(`{tag_name} components cannot be replicated!`)
		end

		replicated_entities[entity] = true

		-- a replicated entity maps through its creation entry, never by name: withdraw the announcement. the staged
		-- retraction is what unmaps the clients the entity is *not* visible to -- its eventual deletion never
		-- reaches them, and a lingering name mapping would misbind the dense id's next tenant -- while a client
		-- receiving the creation adopts the mapping out of name provenance first, so the same retraction leaves
		-- them untouched.
		local dense_id = dense(entity :: any)
		if shared_names.announced_id(dense_id) == (entity :: any) then
			shared_names.retract(dense_id)
		end

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
		replicated_entities[entity] = nil

		-- an unreplicated entity still targeted by tracked pairs is back to mapping by name (if it has one)
		if tracked_pairs_by_target[dense(entity :: any)] ~= nil then
			shared_names.announce(entity)
		end

		restage_entity(entity)
	end

	-- NAME TRACKING

	-- jecs.Name drives two behaviors: a named entity is a replicable pair target (the named_entities mirror is
	-- what is_pair_target_replicable reads), and relevant named ids announce themselves for automatic client
	-- mapping. these hooks keep both live for names set, changed, or removed after initialize's construction
	-- walk seeds the mirror.

	local function on_name_added(entity: Entity, id: Id)
		if id ~= (jecs.Name :: any) then
			return
		end
		named_entities[entity] = true
		-- pairs targeting the entity may just have gained a replicable target
		restage_pairs_targeting(entity)
		-- announce the relevant: a tracked definition, or an unreplicated target of tracked pairs (replicated
		-- targets map through their creation entry instead)
		if
			tracked_by[entity] ~= nil
			or (tracked_pairs_by_target[dense(entity :: any)] ~= nil and replicated_entities[entity] == nil)
		then
			shared_names.announce(entity)
		end
	end

	local function on_name_changed(entity: Entity, id: Id)
		if id ~= (jecs.Name :: any) then
			return
		end
		-- a rename doesn't change replicability; announce-relevance is re-derived (the same condition as
		-- on_name_added) rather than gated on an existing announcement -- a name refused at announce time (empty or
		-- too long) leaves the id unannounced, and its fix arrives through this hook
		if
			tracked_by[entity] ~= nil
			or (tracked_pairs_by_target[dense(entity :: any)] ~= nil and replicated_entities[entity] == nil)
		then
			shared_names.announce(entity)
		end
	end

	local function on_name_removed(entity: Entity, id: Id)
		if id ~= (jecs.Name :: any) then
			return
		end
		named_entities[entity] = nil
		-- pairs targeting the entity may just have lost their replicable target
		restage_pairs_targeting(entity)
		local dense_id = dense(entity :: any)
		if shared_names.announced_id(dense_id) == (entity :: any) then
			shared_names.retract(dense_id)
		end
	end

	-- PRIVACY DELEGATION

	-- pair(InheritsPrivacy, group) delegates an entity's entity-level visibility to the group's ordinary
	-- entity-level filter, so one filter edit on the group narrows every delegating entity. an entity may
	-- delegate to several groups at once -- orthogonal gates (a team's fog of war and a region's interest set)
	-- intersect without duplicating either membership -- so delegation forms a DAG. scoped to the entity-level
	-- gate only -- a (component, group) key can't be encoded in a single pair target, so per-component filters
	-- stay local -- and a delegating entity's own filter intersects every inherited gate: everything narrows,
	-- matching the entity -> cell subset invariant, and blacklists already normalize to allow words so
	-- mixed-polarity delegation composes.

	-- re-derives a delegator's effective entity-level words as own intersect every parent's effective words,
	-- storing the result (absent when every input is absent -- nothing the entity inherits restricts -- with
	-- the entity leaving the store entirely when its last edge is removed) and returning whether the stored
	-- words changed. always a fresh top-down derivation, never an in-place AND of new words into the stored
	-- table: intersection can't restore bits a widening edit (a filter or edge removal) must grant back.
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

		-- fold the restricting inputs together; nil until the first one, then a fresh table -- copied, never
		-- aliased: own words are edited in place by the grant loop and the sweeps, parents' effective words by
		-- later recomputes, and a filter edit replaces its table wholesale
		local derived: ShardMasks? = nil
		if own ~= nil then
			derived = table.clone(own)
		end
		for _, parent in parents do
			local parent_masks = entity_gate_masks(parent)
			if parent_masks == nil then
				continue
			end
			if derived == nil then
				derived = table.clone(parent_masks)
			else
				-- zero words are omitted, so equal restrictions compare equal below (clearing the current key
				-- mid-iteration is safe)
				for shard, word in derived do
					local narrowed = bit32.band(word, parent_masks[shard] or 0)
					if narrowed ~= 0 then
						derived[shard] = narrowed
					else
						derived[shard] = nil
					end
				end
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
		for shard, word in derived do
			if old[shard] ~= word then
				return true
			end
		end
		for shard in old do
			if (derived :: ShardMasks)[shard] == nil then
				return true
			end
		end
		return false
	end

	-- fans an effective-word change on node out over its delegating descendants: each child re-derives against
	-- all of its parents (node's fresh words among them), and an unchanged child prunes its whole branch -- a
	-- descendant needs refreshing only if some parent's words changed, and any such parent, being un-pruned,
	-- fans out to it itself. this early exit is what keeps a group edit cheaper than editing every member: the
	-- restage cell walk is the dominant cost, and it only runs where words actually changed. diamonds (a
	-- descendant reachable through several children) re-derive once per arrival -- an early arrival may read a
	-- sibling branch's words stale, but the last arrival reads everything fresh and stores the final words, and
	-- any intermediate restage is idempotent -- so the walk converges without global ordering, at the cost of
	-- transient duplicate work proportional to the diamond's width.
	local function refresh_descendants(node: Entity)
		local children = delegation_children[node]
		if children == nil then
			return
		end
		for child in children do
			if recompute_effective(child) then
				restage_entity(child)
				refresh_descendants(child)
			end
		end
	end

	-- re-derives one delegator's effective words during a store-wide refresh (a joiner's slot grant), resolving
	-- every parent first so the intersection reads fresh words; refreshed marks the delegators already
	-- re-derived this pass. pre-order marking bounds the walk on any graph, and the guards keep delegation
	-- acyclic, so parents always finish deriving before their delegators read them.
	local function refresh_delegator(entity: Entity, parents: { [number]: Entity }, refreshed: { [Entity]: true })
		if refreshed[entity] ~= nil then
			return
		end
		refreshed[entity] = true
		for _, parent in parents do
			local grandparents = delegation_parents[parent]
			if grandparents ~= nil then
				refresh_delegator(parent, grandparents, refreshed)
			end
		end
		recompute_effective(entity)
	end

	-- delegation_children maintenance, mirroring index_tracked_pair's bucket-set shape; keyed by the full group
	-- entity so the fan-out and the parents mirror agree on identity.
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

	-- whether sought is reachable from node through parent edges, read from the mirror rather than world:target
	-- so the walk stays consistent with what the hooks have processed: the reachability test backing the cycle
	-- guard. the visited set keeps diamonds from re-walking shared ancestry.
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

	-- the guards run before the mirror write, so the removed hook their undo fires recognizes it by the missing
	-- mirror edge. existing delegation is acyclic, so a new cycle must pass through the new edge, and the
	-- reachability walk from the group finds it.
	local function on_inherits_added(entity: Entity, id: Id)
		if id == InheritsPrivacy then
			world:remove(entity, InheritsPrivacy)
			fail(`InheritsPrivacy must be paired with a group entity! ({id_to_string(entity :: any, world)})`)
		end

		local group = jecs.pair_second(world, id) :: Entity
		if delegation_reaches(group, entity, {}) then
			world:remove(entity, id)
			fail(
				`InheritsPrivacy delegation cannot contain cycles! ({id_to_string(entity :: any, world)} -> {id_to_string(
					group :: any,
					world
				)})`
			)
		end

		local parents = delegation_parents[entity]
		if parents == nil then
			parents = {}
			delegation_parents[entity] = parents
		end
		parents[dense(group :: any)] = group
		index_delegation_child(group, entity)
		if recompute_effective(entity) then
			restage_entity(entity)
			refresh_descendants(entity)
		end
	end

	local function on_inherits_removed(entity: Entity, id: Id)
		if id == InheritsPrivacy then
			return
		end
		local parents = delegation_parents[entity]
		if parents == nil then
			return
		end
		-- the pair id only packs the group's dense half (and the group may already be dead mid-cascade), so the
		-- edge resolves through the dense-keyed mirror; a missing edge is the cycle guard undoing its own add
		local dense_group = ECS_PAIR_SECOND(id :: any)
		local group = parents[dense_group]
		if group == nil then
			return
		end
		parents[dense_group] = nil
		if next(parents) == nil then
			delegation_parents[entity] = nil
		end
		deindex_delegation_child(group, entity)
		-- the re-derivation against the remaining edges widens (or clears) the stored words; unchanged words --
		-- a redundant edge removed, or a gate that never restricted -- skip the restage entirely
		if recompute_effective(entity) then
			restage_entity(entity)
			refresh_descendants(entity)
		end
	end

	-- PRIVACY CACHING

	-- writes a sanitized filter over (entity, id)'s value slot directly in its archetype column -- never through
	-- world:set, whose hooks would restage cells and notify user Private listeners over a rewrite that changes
	-- no client's standing (pruned clients hold none). keeping the column in lockstep with the caches is what
	-- makes world:get always return the effective filter, and what keeps stale filter values from pinning
	-- departed client objects until their next edit. the record is re-read per call, so archetype moves between
	-- writes (a blacklist removal mid-prune) never leave it stale; every caller runs after the component landed
	-- (added hooks fire post-move), so the column slot always exists. reads archetype shape (columns_map) like
	-- full_packet's walk, which DontFragment pairs won't occupy: if jecs ships DontFragment and Private adopts
	-- it, pair(Private, component) values leave the archetype columns and this write needs whatever sparse-pair
	-- storage api jecs exposes instead.
	local function write_filter_value(entity: Entity, id: Id, filter: Privacy)
		local record = entity_index.sparse_array[dense(entity :: any)]
		record.archetype.columns_map[id :: any][record.row] = filter
	end

	-- resolves a privacy filter into the table + per-shard words the caches store, erroring on mixed polarities.
	-- whitelist words mark the named allocated clients; blacklist words normalize into allow words too -- each
	-- occupied shard's allocated word minus the named clients -- so every downstream reader keeps allow
	-- semantics (allocate_client keeps both kinds fresh as later joiners take slots). pending clients stay in
	-- the table bitless (allocate_client grants or withholds their bit later); untracked clients are pruned so
	-- later edits don't clone them back in, with the set hook writing the pruned table back over the
	-- component's value (write_filter_value) so the value and the cache stay one table. a blacklist that prunes
	-- to empty blocks nobody: both returns are nil so the caller removes the value outright instead of caching
	-- an empty table (empty always means a block-everyone whitelist).
	local function sanitize_privacy(privacy: Privacy): (Privacy?, ShardMasks?)
		-- shape checks first, so a malformed value is diagnosed rather than misread: a non-table would fault out
		-- of next() below with a bare luau message, and a truthy non-boolean would sail through the polarity
		-- check and *admit* the client it names -- the one direction a filter must never fail in. both raise
		-- through the revert guard around this call, like the mixed-polarity error they join.
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

	-- caches the filter under (entity, key) and returns the sanitized table it cached: a table other than the
	-- one passed means sanitization pruned, and the caller writes it back over the component's value. returns
	-- nil without caching when a blacklist sanitized to nothing (naming only untracked clients) -- it restricts
	-- nobody, and an empty table must keep meaning a block-everyone whitelist, so the caller removes the value
	-- outright (whose removed hook then clears whatever this value replaced)
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

	-- a privacy filter on (entity, key) governs the unpaired cell and every pair using key as the relation on
	-- entity; restage them so the diff picks up who gained or lost access. pairs removed earlier this frame need
	-- no restage: their staged 0 already removes them from every prior viewer.
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

	-- the entity-level filter on entity changed: re-derive its own effective words first when it delegates, then
	-- restage the whole entity and fan out over its delegating descendants. shared by the set and removed hooks'
	-- entity-level arms below.
	local function refresh_entity_gate(entity: Entity)
		if delegation_parents[entity] ~= nil then
			recompute_effective(entity)
		end
		restage_entity(entity)
		refresh_descendants(entity)
	end

	-- set_cached_privacy behind a revert guard: sanitize_privacy's mixed-polarity error fires from inside the
	-- set hook, after the offending value already landed on the entity, so erroring alone would leave the world
	-- holding a filter the caches aren't honoring until the next set/remove. revert first -- like the Networked
	-- guards undo their add before erroring -- back to the previous cached filter when one exists (the
	-- sanitized shape, pruned of departed clients), or removing the value outright when a fresh add has nothing
	-- to revert to; then rethrow. the revert re-fires on_private_set with a filter that sanitizes cleanly
	-- (cached filters are single-polarity tables by construction), so the nested run never re-enters this error
	-- path.
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

	-- a sanitization that pruned earns a warning on top of the rewrite: every pruned client is one the caller
	-- believed the filter governed, and the failure is silent and polarity-dependent -- a pruned whitelist goes
	-- on blocking clients it meant to admit, while a blacklist pruned empty (sanitized == nil) is removed
	-- outright, admitting its named clients the moment they do join. both are spellings of the same ordering
	-- bug: clients must be registered through add_client before a filter names them (a pending client already
	-- counts as tracked), and before construction no client can be tracked at all, so the catch-up warns here
	-- for every populated pre-construction filter (see catch_up). the prune itself stays the standing contract
	-- (filters name only tracked clients -- see prune_privacy_filters); only user sets warn, since
	-- remove_client's departure prune never runs through sanitization.
	local function warn_pruned_clients(entity: Entity, filter: Privacy, sanitized: Privacy?)
		if sanitized == nil then
			warn(
				`a Private blacklist named only untracked clients! it was removed outright, since it restricted nobody -- register clients through add_client before a filter names them; no client can be tracked before duplecs.server(world) constructs. ({id_to_string(
					entity :: any,
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
			`a Private filter named {pruned} untracked client(s)! they were pruned from it, since filters only carry tracked clients -- register clients through add_client before a filter names them; no client can be tracked before duplecs.server(world) constructs. ({id_to_string(
				entity :: any,
				world
			)})`
		)
	end

	-- handles both the added and changed hooks (a world:set fires whichever applies, and the work is identical
	-- either way): cache under the paired component (or Existence for an un-paired Private), then restage the
	-- governed cells; the packet diff turns each mask change into per-client sends and removals, so no
	-- old-vs-new diffing here. an entity-level filter gates everything, so it restages entity-wide and fans out
	-- over the entity's delegating descendants (with the entity's own effective words re-derived first, when it
	-- delegates itself). a filter sanitization pruned (naming departed or never-tracked clients) is written
	-- back over the component's value, so the value and the cache stay one table, and warned about
	-- (warn_pruned_clients above); a blacklist that sanitized to nothing is never cached: the value is removed
	-- outright, mirroring edit_privacy's emptying edits, with the removed hook clearing and restaging whatever
	-- filter the value replaced -- warned about the same way. mutating here is fine: added hooks fire after the
	-- archetype move and changed hooks involve none -- only removed hooks fire mid-transition (see jecs.md).
	--
	-- a nil value is normalized before any of that: a filter is a table, and absence already means unrestricted,
	-- so there is no third state for a present nil to name -- world:add(entity, Private) and world:set(entity,
	-- Private, nil) both land here, and both meant "block everyone" only by accident of an empty cache entry,
	-- which the empty table says outright. rewriting the value to empty_whitelist (rather than stripping it)
	-- keeps that meaning: a filter system must fail closed, so the one interpretation never worth guessing at is
	-- the one that would silently reveal what the caller was trying to hide. it warns rather than erroring
	-- because the resulting state is exactly what the call meant -- the warning is about the spelling, and about
	-- the sibling form it can't catch, since jecs's add returns early on an entity that already carries a filter
	-- and fires no hook at all there (see jecs.md), silently leaving that filter in place.
	local function on_private_set(entity: Entity, id: Id, privacy: Privacy?)
		local filter: Privacy
		if privacy == nil then
			warn(
				`Private filters cannot have a nil value! it now blocks every client, as an empty filter -- set one explicitly, since world:add leaves an existing filter untouched instead. ({id_to_string(
					entity :: any,
					world
				)})`
			)
			write_filter_value(entity, id, empty_whitelist)
			-- then carry on and cache it: the write fires no hooks, so this pass is the only chance -- a value
			-- that landed with no cache behind it would read as no filter at all, failing open in the one place
			-- that must not.
			filter = empty_whitelist
		else
			filter = privacy
		end
		-- a non-table never reaches table.isfrozen: it would fault out of the hook with a bare luau message,
		-- leaving the offending value on the entity with nothing cached behind it. sanitize_privacy's shape check
		-- names it properly instead, through the revert guard below.
		if type(filter) == "table" and table.isfrozen(filter) ~= true then
			table.freeze(filter)
		end
		if id == Private then
			local sanitized = set_cached_privacy_reverting(entity, Existence, id, filter)
			if sanitized == nil then
				warn_pruned_clients(entity, filter, nil)
				world:remove(entity, id)
				return
			end
			if sanitized ~= filter then
				warn_pruned_clients(entity, filter, sanitized)
				write_filter_value(entity, id, sanitized)
			end
			refresh_entity_gate(entity)
			return
		end
		local key = jecs.pair_second(world, id)
		local sanitized = set_cached_privacy_reverting(entity, key, id, filter)
		if sanitized == nil then
			warn_pruned_clients(entity, filter, nil)
			world:remove(entity, id)
			return
		end
		if sanitized ~= filter then
			warn_pruned_clients(entity, filter, sanitized)
			write_filter_value(entity, id, sanitized)
		end
		restage_privacy_cells(entity, key)
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

	-- PRIVACY EDITING

	-- the polarity of a cached filter: cached blacklists are never empty (one emptied by pruning or editing
	-- drops out of the caches entirely), so one sampled value is the polarity -- an empty table samples nil and
	-- reads as what it is, a block-everyone whitelist.
	local function privacy_is_blacklist(privacy: Privacy): boolean
		local _, sample = next(privacy)
		return sample == false
	end

	-- copy-on-write edit: clone -> mutate -> freeze, so world:set fires the changed hook with a fresh immutable
	-- value. membership means the opposite thing per polarity -- a whitelist admits its members, a blacklist
	-- admits everyone else -- so a client's admission is their membership XORed with the polarity, and a state
	-- change always flips membership: a named client un-names, an unnamed one gains the polarity's member value
	-- (so allowing a blacklisted client un-names them rather than writing true, and polarity can never flip
	-- through edits). returns nil when the client is already in the requested state.
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

	-- edits one client's standing in the privacy filter on (entity, key), backed by id (the unpaired or paired
	-- Private). on a whitelist, allowed adds or drops membership (a whitelist emptied this way keeps blocking
	-- everyone); on a blacklist, disallowing names the client and allowing un-names them, with the last name's
	-- removal dropping the Private value outright -- a blacklist blocking nobody restricts nothing, and an empty
	-- table must keep meaning a block-everyone whitelist. disallowing with no filter configured starts a
	-- blacklist (no filter admits everyone, so the starting point is unambiguous); allowing requires an existing
	-- whitelist (set an empty one to start from blocking everyone). the two public entry points below bind
	-- key/id for the entity-level and per-component filters respectively. these rules exist to maintain a
	-- filter's polarity after incremental edits.
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

	-- SERDES

	-- the per-world serdes store (see shared.luau / serdes.luau): its Serdes component and validation hooks
	-- predate every possible registration, so there is nothing to catch up on here
	local Serdes = components.Serdes
	local resolve_serdes = shared_record.resolve_serdes

	-- the packet passes' measure, behind the salvage guard (see wire.measure_section_salvaging): a user encode
	-- hook that throws mid-measure no longer unwinds out of generate_packets after the resolve passes marked the
	-- frame's deltas sent -- the offending values are pruned from the draft, and everything else (the surviving
	-- values, and the nulled/removed lists, which never encode) ships as measured. warn-and-continue: the frame
	-- is salvaged, so erroring would throw away the salvage. the pruned values simply never reach clients --
	-- their cells replicate again on their next staged change (which encodes fresh, and may fail again until the
	-- hook or the value is fixed).
	local function measure_section_guarded(draft: SectionDraft): number
		local size, pruned, salvage_error = measure_section_salvaging(draft, resolve_serdes)
		if salvage_error ~= nil then
			local section_id = draft.relation or draft.component
			warn(
				`a serdes encode hook threw while encoding {id_to_string(section_id :: any, world)}! {pruned} value(s) were dropped from this frame's packets and will not replicate until their cells next change: {salvage_error}`
			)
		end
		return size
	end

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

	-- prunes the departing client's key from every privacy filter, cache and component value alike: whether a
	-- stale name survived a filter would otherwise depend on whether an edit happened in between (edits clone
	-- from the pruned cache), so a rejoin under the same value would be re-admitted or not by that accident --
	-- pruning at departure makes rejoins deterministic (a rejoiner always starts unlisted) -- and an unedited
	-- value would pin the departed client object (typically a Player) indefinitely. copy-on-write like the
	-- edits, since cached values are frozen and callers may snapshot them by reference; the pruned table lands
	-- in the cache and, via write_filter_value, over the component's value, keeping the two one table. one
	-- exception: a blacklist pruned empty restricts nobody, so its Private value is removed outright (an empty
	-- table must keep meaning a block-everyone whitelist), mirroring edit_privacy's emptying edits; a whitelist
	-- pruned empty stays and keeps blocking everyone. no restage and no hooks: the departing client's bit is
	-- out of every allocated word, and no other client's admission changes.
	local function prune_privacy_filters(client: Client)
		for entity, component_filters in privacy_filters do
			for key, filter in component_filters do
				if filter[client] == nil then
					continue
				end
				local pruned = table.clone(filter)
				pruned[client] = nil
				local id = if key == Existence then Private else pair(Private, key)
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
			-- the shard organically emptied: drop its mask trees wholesale (nothing reads them with no occupants, and
			-- a rejoiner rebuilds via its full packet). the allow words keep their stale bits -- the freed-slot sweep
			-- clears those per bit on reuse.
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

	-- whether the client is currently registered with this instance: true from add_client until remove_client,
	-- pending joiners included -- a pending client is already registered (privacy filters may already name
	-- them), even though their slot, and with it every visibility query, only arrives at the tail of the next
	-- generate_packets.
	local function is_client_tracked(client: Client): boolean
		return tracked_clients[client] ~= nil or pending_clients[client] == true
	end

	-- declares that the client world behind an allocated slot is fresh -- it has never reconciled a packet from
	-- this server -- so the next generate_packets returns a full packet for the client in place of their delta.
	-- the slot itself is untouched -- its privacy filters, visibility masks, and delta baseline all persist --
	-- so this exists for handing an already-allocated slot to a new connection: a game keeping slots allocated
	-- across disconnects to preserve their privacy state resyncs whoever takes the slot over. freshness is the
	-- declared precondition, not a resync knob: a full packet carries no removals, so a world that has already
	-- reconciled state would keep whatever the full doesn't name. marking a pending joiner is a no-op (their
	-- join already produces a full packet); marking an untracked client warns.
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

	-- debug introspection: the 1-based shard of an allocated client (nil while pending or untracked). shard
	-- placement is otherwise invisible -- sections are shared across shards -- so tests verifying the compaction
	-- schedule read it directly.
	local function client_shard(client: Client): number?
		local client_index = tracked_clients[client]
		if client_index == nil then
			return nil
		end
		return shard_of(client_index)
	end

	-- ALLOCATION & PACKET GENERATION

	-- the packet frame counter, cycling 0..2^32-1: every packet of one generate_packets call carries it, so a
	-- caller splitting a call's packets across channels can group, dedupe, or order them (wrap-aware) on the
	-- client. independent of the chunk frame counter below.
	local packet_frame = -1

	local function next_packet_frame(): number
		packet_frame = (packet_frame + 1) % 2 ^ 32
		return packet_frame
	end

	-- the recycling pools (see pools.luau). the scratch tables back the packet passes' per-frame lists: the
	-- section drafts' lists, the per-node and per-client accumulators' inner tables, the entity create/delete
	-- lists, and full_packet's collectors -- the flat packet buffer copies or encodes all of their contents, so
	-- none escape a generate_packets call.
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
	-- the derived effective words (bit clears distribute over intersection, so the same per-word sweep keeps
	-- them consistent with their inputs). bits may carry several set bits (compaction batches reused target
	-- slots per shard; allocate_client sweeps one). entries that zero are pruned, like everywhere else, so a
	-- present last word is always nonzero.
	local function sweep_freed_slots(shard: number, bits: VisibilityMask)
		local clear = bit32.bnot(bits)
		local shard_last = last_visibilities[shard]
		if shard_last then
			for _, last_component in shard_last do
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

		-- grant the bit to filters that admit this client: whitelists that named them while pending (their bit
		-- didn't exist yet), and blacklists that don't name them -- this is what keeps blacklists' snapshot-derived
		-- allow words fresh as the population grows. allow_masks mirrors privacy_filters' keys, so the masks table
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

		-- delegation-aware pass: effective words derive from the own words the grant loop just refreshed, so
		-- re-derive every delegator's, parents first. joins are rare and this is pure word math over the delegator
		-- set; no restage -- the joiner's visibility ships via their full packet, and no other client's bits moved.
		if next(delegation_parents) ~= nil then
			local refreshed = {} :: { [Entity]: true }
			for entity, parents in delegation_parents do
				refresh_delegator(entity, parents, refreshed)
			end
		end
	end

	-- builds a full packet for a freshly-allocated client and marks their bit in their shard's last_* masks so
	-- subsequent deltas diff correctly. allocate_client must have run first. walks the replicated set archetype
	-- by archetype rather than per tracked component: cells only replicate on replicated subjects, so the
	-- archetypes of Replicated's component record cover every cell (walked directly -- an uncached
	-- world:query(Replicated):archetypes() rebuilds exactly that record's archetype list per call), and
	-- everything shape-derived -- eligibility, privacy keys, pair halves (read off archetype.types like
	-- restage_own_cells, never world:target), and value columns -- resolves once per archetype, leaving
	-- per-entity work of only the entity's own gate, one filter word per cell, and a column read per value. only
	-- this client's bit matters, so every mask check collapses to one band against the bit (allocated needs no
	-- re-check: the client's own bit is allocated by definition).
	local function full_packet(client: Client, this_packet_frame: number): Packet
		local client_index = tracked_clients[client] :: number
		local shard = shard_of(client_index)
		local bit = slot_bit_of(client_index)
		local sections: { SectionDraft } = fetch_scratch()
		local section_of: { [number]: SectionDraft } = fetch_scratch()
		-- pair drafts collect per relation (their cells landing in per-target runs), in their own map: both maps
		-- key gen-qualified ids here, so one definition serving as an unpaired component and as a relation shares
		-- a key between the two roles at any generation, and the two must draft separate sections
		local pair_section_of: { [number]: SectionDraft } = fetch_scratch()

		local shard_last = last_visibilities[shard]
		if shard_last == nil then
			shard_last = {}
			last_visibilities[shard] = shard_last
		end
		local last_existence = shard_last[Existence]

		local replicated: { number } = fetch_scratch()
		local replicated_count = 0

		-- appends one visible cell to its section draft. relation and target ride in from the archetype resolve
		-- below, already gen-qualified, so pair cells never pay a pair_first/pair_second here; value is the cell's
		-- column read (nil for tags and nulled values).
		local function emit(component: Id, entity: Entity, relation: Entity?, target: Entity?, value: any)
			local last_component = shard_last[component]
			if last_component == nil then
				last_component = {}
				shard_last[component] = last_component
			end
			last_component[entity] = bit32.bor(last_component[entity] or 0, bit)

			local lists: any
			if relation ~= nil then
				local data = pair_section_of[relation :: any]
				if data == nil then
					data = fetch_draft(nil, relation :: any)
					pair_section_of[relation :: any] = data
					table.insert(sections, data)
				end
				lists = get_run(data, target :: any)
			else
				local data = section_of[component :: any]
				if data == nil then
					data = fetch_draft(component :: any)
					section_of[component :: any] = data
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
				table.insert(nulled :: { number }, entity :: any)
			else
				local ids = lists.ids
				local values = lists.values
				if ids == nil then
					ids = fetch_scratch()
					values = fetch_scratch()
					lists.ids = ids
					lists.values = values
				end
				table.insert(ids :: { number }, entity :: any)
				table.insert(values :: { any }, value)
			end
		end

		-- the walked archetype's networked cells, parallel over 1..cell_count: the cell id as staged and keyed in
		-- the last tree (the component, or the packed pair id straight from archetype.types), the privacy key
		-- gating it per entity (the component itself, or the gen-qualified relation -- doubling as emit's relation
		-- argument), the value column (jecs backs tags with a shared empty column, so tag reads are plain nils),
		-- and -- pair cells only -- the gen-qualified target.
		local cell_ids: { number } = fetch_scratch()
		local cell_keys: { number } = fetch_scratch()
		local cell_columns: { { any } } = fetch_scratch()
		local cell_targets: { [number]: number } = fetch_scratch()

		local idr_replicated = component_index[Replicated :: any]
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

			-- resolve the archetype's networked cells once: the tracking and pair-half checks are per component, not
			-- per entity, and a pair target's gate blocking this client blocks the cell for every subject in the
			-- archetype, so it drops here. the pair resolve mirrors restage_own_cells (an unindexed half is
			-- ineligible).
			local cell_count = 0
			for _, component in archetype.types do
				local privacy_key: number
				local target: number? = nil
				if IS_PAIR(component :: any) then
					local relation = tracked_relation_gens[ECS_PAIR_FIRST(component :: any)]
					if relation == nil then
						continue
					end
					local target_gen = tracked_target_gens[ECS_PAIR_SECOND(component :: any)]
					if target_gen == nil or is_pair_target_replicable(target_gen :: any) ~= true then
						continue
					end
					if replicated_entities[target_gen :: any] ~= nil then
						local gate = entity_gate_masks(target_gen :: any)
						if gate ~= nil and bit32.band(gate[shard] or 0, bit) == 0 then
							continue
						end
					end
					privacy_key = relation :: any
					target = target_gen
				elseif tracked_by[component :: any] ~= nil then
					privacy_key = component :: any
				else
					continue
				end
				cell_count += 1
				cell_ids[cell_count] = component :: any
				cell_keys[cell_count] = privacy_key
				cell_columns[cell_count] = columns_map[component :: any]
				-- assigned even when nil, clearing whatever the previous archetype left at this row
				cell_targets[cell_count] = target :: any
			end

			for row, entity in entities do
				-- the entity's own gate: entity_gate_masks inlined so the allow-mask fetch is shared with the cell loop
				-- below
				local entity_masks = allow_masks[entity :: any]
				local gate = effective_masks[entity :: any]
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
					shard_last[Existence] = last_existence
				end
				last_existence[entity :: any] = bit32.bor(last_existence[entity :: any] or 0, bit)

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
						entity :: any,
						if target ~= nil then privacy_key :: any else nil,
						target :: any,
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
	-- beneath it, so per-frame cost tracks the current population rather than the historical peak (staging,
	-- resolve, and finalize all run per occupied shard). lowest-first allocation packs joiners low, so only the
	-- stragglers of a population shrink pin a high shard; the deadzone guarantees at least stragglers + 9 free
	-- bits below, so placement never fails, and re-opening the reclaimed shard takes ~9 net joins, so a
	-- population hovering at a shard boundary never churns. at most one shard is reclaimed per call; a large
	-- drop reclaims over successive calls. a move is a pure server-side bit transfer, invisible to clients:
	-- packets are keyed by client object and deltas diff against whatever last words carry the bit. must run at
	-- the tail of generate_packets -- next_visibilities and component_changes are empty there, leaving the last
	-- trees, the allow words, and the slot bookkeeping as the only stores carrying slot bits.
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
						local shard_last = last_visibilities[moved_shards[old_index]]
						if shard_last == nil then
							shard_last = {}
							last_visibilities[moved_shards[old_index]] = shard_last
						end
						local target_component = shard_last[component]
						if target_component == nil then
							target_component = {}
							shard_last[component] = target_component
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

		-- the derived effective words transfer the same way (bit moves distribute over intersection), their store
		-- being one level flat
		for _, masks in effective_masks do
			transfer_masks_word(masks)
		end

		allocated_masks[reclaimed] = 0
		freed_masks[reclaimed] = 0
		while shard_count > 0 and allocated_masks[shard_count] == 0 do
			shard_count -= 1
		end
	end

	-- the mask trie: a cell's accumulated visibility is the node its run path reaches, so equal cross-shard
	-- visibility converges on one node. its contents are per-frame and trie nodes never escape the pass, so the
	-- expansion pass clears each node it leaves into a free list that append_mask_run drains before allocating,
	-- and the root persists empty between calls.
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

	-- cross-shard packet groups, persistent across calls (see the PacketGroup type): every dirty cell lands in
	-- its group once, its nodes accumulating per-shard runs as the shard loop advances. unpaired components
	-- key groups by their id; pair cells share one group per relation, keyed by the relation's dense half (all a
	-- packed pair id carries) in its own store -- a generation-0 component id can collide with a relation's
	-- dense id, and the two must stay distinct groups. dirty_groups lists the groups touched this frame so the
	-- bucket pass never walks the historical set; group_frame stamps first touches, and last_group_sweep
	-- schedules the eviction sweep that keeps both stores bounded by the recently-live id set.
	local groups = {} :: { [number]: PacketGroup }
	local pair_groups = {} :: { [number]: PacketGroup }
	local dirty_groups = {} :: { PacketGroup }
	local dirty_group_count = 0
	local group_frame = 0
	local last_group_sweep = 0

	-- per-frame accumulators of the packet passes, shared by the pass functions below as upvalues rather than
	-- parameters. the maps themselves persist: release_frame_state hands their inner tables back to the scratch
	-- pool once the frame's packets are assembled, and reset_frame_state clears whatever an errored frame
	-- stranded (the salvage guard contains user encode throws, but an internal error can still unwind
	-- mid-frame) so every call still starts fresh. both stay directly below the declarations so an accumulator
	-- can't be added without its reset and release in view.

	-- entity create/delete lists keyed by global client index
	local replicated_by = {} :: { [number]: { number } }
	local unreplicated_by = {} :: { [number]: { number } }

	-- sections attach per accumulated-visibility node via node_section_drafts, keyed [node][group] -- the group
	-- object itself, so an unpaired component and a relation can never collide however their ids overlap;
	-- unpaired groups draft an unpaired section, pair groups a relation section whose per-target runs the
	-- bucket pass fills. with a single occupied shard every cell has exactly one run, so the trie is skipped
	-- entirely and the drafts key by the raw mask word instead. masks are intersected with each shard's
	-- allocated word at resolve time so a departed client's stale bit lingering in last_visibilities never
	-- creates or widens a section.
	local node_section_drafts = {} :: { [VisibilityNode]: { [PacketGroup]: SectionDraft } }

	-- finalize_node_sections' outputs, per node: the node's sections encoded back-to-back into one shared
	-- buffer, its byte size, and (only when the node has any) the hookless sections' value arrays in write
	-- order -- one array per hookless section, so the outer length counts sections and never values.
	local node_buffers = {} :: { [VisibilityNode]: buffer }
	local node_sizes = {} :: { [VisibilityNode]: number }
	local node_section_values = {} :: { [VisibilityNode]: { { any } } }

	-- per-client accumulators for the expansion pass: the section buffers to stamp, their running byte size, and
	-- the hookless sections' value arrays in section order (the packet's side array, same one-array-per-section
	-- shape as node_section_values), all keyed by global client index.
	local client_buffers = {} :: { [number]: { buffer } }
	local client_sizes = {} :: { [number]: number }
	local client_section_values = {} :: { [number]: { { any } } }

	-- the frame's freshly-announced shared names (gen-qualified id -> name), drained from the shared-name store
	-- and stamped into every allocated client's packet; nil on frames announcing nothing.
	local frame_names: { [number]: string }? = nil

	-- whether several shards are occupied this frame: with one occupied shard the trie is skipped and raw mask
	-- words key node_section_drafts directly.
	local multi_shard = false

	local function reset_frame_state()
		table.clear(replicated_by)
		table.clear(unreplicated_by)
		table.clear(node_section_drafts)
		table.clear(node_buffers)
		table.clear(node_sizes)
		table.clear(node_section_values)
		table.clear(client_buffers)
		table.clear(client_sizes)
		table.clear(client_section_values)
		-- an errored frame's stranded table is abandoned to the GC rather than pooled; release_frame_state is what
		-- recycles it on clean frames
		frame_names = nil
		multi_shard = shard_count > 1
	end

	-- runs after assemble_client_packets: every section buffer has been stamped into the clients' flat packets
	-- and the create/delete lists written inline, so only the hookless value arrays inside client_section_values
	-- (escaped into the packets' side arrays) outlive the frame. releasing a map's values before clearing the
	-- map is safe here -- nothing fetches until the maps are cleared -- and running before the joiner full
	-- packets lets those draw on the freed tables. node_section_drafts is already empty: finalize_node_sections
	-- consumed it.
	local function release_frame_state()
		-- node_buffers holds plain buffers whose bytes were already stamped into the clients' packets, so they just
		-- drop to the GC
		table.clear(node_buffers)
		table.clear(node_sizes)
		for _, section_values in node_section_values do
			release_scratch(section_values)
		end
		table.clear(node_section_values)
		for _, buffers in client_buffers do
			release_scratch(buffers)
		end
		table.clear(client_buffers)
		table.clear(client_sizes)
		table.clear(client_section_values)
		for _, list in replicated_by do
			release_scratch(list)
		end
		table.clear(replicated_by)
		for _, list in unreplicated_by do
			release_scratch(list)
		end
		table.clear(unreplicated_by)
		if frame_names ~= nil then
			release_scratch(frame_names)
			frame_names = nil
		end
	end

	local function get_group(component: number): PacketGroup
		local group = groups[component]
		if group == nil then
			group = {
				key = component,
				frame = group_frame,
				count = 0,
				entities = {},
				values = {},
				send_nodes = {},
				removed_nodes = {},
				row_of = if multi_shard then {} else nil,
				is_tag = jecs.is_tag(world, component :: any),
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

	-- the shared group of every pair cell using component's relation. packed pair ids reuse dense halves across
	-- generations, so the gen-qualified relation (and the relation tag-ness gating the resolve passes' value
	-- reads) re-resolves on the group's first touch each frame -- through the relation gen cache, with an
	-- untracked relation (a stop_tracking_component or a relation death resolving its staged removals) recovered
	-- from the retired store, and the live resolve as a last resort for cells no retirement covers; the targets
	-- resolve per pair id in the resolve passes, since one group now spans every target of the relation.
	local function get_pair_group(component: number): PacketGroup
		local relation_dense = ECS_PAIR_FIRST(component :: any) :: any
		local group = pair_groups[relation_dense]
		if group == nil then
			local relation = (
				tracked_relation_gens[relation_dense]
				or retired_relation_gens[relation_dense]
				or jecs.pair_first(world, component :: any)
			) :: any
			local is_tag = tracked_relation_tags[relation_dense]
			if is_tag == nil then
				is_tag = if (relation :: any) == 0 then false else jecs.is_tag(world, relation)
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
				or jecs.pair_first(world, component :: any)
			) :: any
			group.relation = relation
			local is_tag = tracked_relation_tags[relation_dense]
			if is_tag == nil then
				is_tag = if (relation :: any) == 0 then false else jecs.is_tag(world, relation)
			end
			group.is_tag = is_tag
			if multi_shard and group.pair_rows == nil then
				group.pair_rows = {}
			end
		end
		return group
	end

	local function get_section(node: VisibilityNode, group: PacketGroup): SectionDraft
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

	-- the one special-cased cell: the existence diff resolves into per-client replicated / unreplicated lists
	-- rather than a component group (a bit gained is a create, a bit cleared a delete), and resolves *before*
	-- the component cells because the returned record holds the bits deleted this frame so they can drop
	-- per-component removals the client applies wholesale when deleting the entity (or pair target) locally.
	-- masks are shard-relative, so the diff and the record are both per-shard.
	local function resolve_existence_diff(
		shard_next: ShardVisibility,
		shard_last: ShardVisibility,
		allocated: VisibilityMask,
		base_index: number
	): { [Entity]: VisibilityMask }
		-- pooled; the caller releases it once the component cells resolve
		local entity_unreplicate_mask: { [Entity]: VisibilityMask } = fetch_scratch()

		local existence_visibility = shard_next[Existence]
		if existence_visibility then
			shard_next[Existence] = nil
			local last_existence = shard_last[Existence]

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
					entity_unreplicate_mask[entity] = removed
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
						shard_last[Existence] = last_existence
					end
					last_existence[entity] = new
				end
			end

			if last_existence and next(last_existence) == nil then
				shard_last[Existence] = nil
			end
		end

		return entity_unreplicate_mask
	end

	-- visibility cells of one shard: fold every dirty cell into its component's cross-shard group, its send /
	-- removed words accumulated into section keys. send and removed are disjoint, so a client falls into at most
	-- one of them per cell. a cell whose value also changed emits only its removals here; its sends defer to
	-- resolve_value_cells, run against the post-merge mask so every viewer gets the new value exactly once.
	local function resolve_visibility_cells(
		shard_next: ShardVisibility,
		shard_last: ShardVisibility,
		allocated: VisibilityMask,
		shard_key_base: number,
		entity_unreplicate_mask: { [Entity]: VisibilityMask }
	)
		for component, new_visibility in shard_next do
			local value_changes = component_changes[component]
			local old_visibility = shard_last[component]

			local is_pair = IS_PAIR(component :: any)
			local group = if is_pair then get_pair_group(component :: any) else get_group(component :: any)
			local is_tag = group.is_tag
			local count = group.count
			local entities = group.entities
			local values = group.values
			local send_nodes = group.send_nodes
			local removed_nodes = group.removed_nodes
			local targets = group.targets
			local rows = group.row_of

			-- a pair whose target the client drops this frame needs no explicit removals: dropping the target locally
			-- auto-removes the pair. a live cache entry is the dense id's current tenant (== the target the client
			-- resolves with), so the sends of a dense id recycled within the frame are never taken for the old tenant;
			-- a miss means the pair id carries only removals, which belong to the retired tenant -- naming that gen
			-- keeps the skip generation-precise across a same-frame recycle. the target-side drops are loop-invariant,
			-- so they narrow removed_allowed -- the word removals compute against in place of the raw allocated word --
			-- once, outside the entity loop; the subject's own drop stays per entity.
			local target: number? = nil
			local removed_allowed = allocated
			if is_pair then
				-- the relation-level recycle signature: the relation's dense id retired one definition and re-tracked
				-- another since the last call, so the staged removals belong to the retired definition -- section
				-- relation ids are dense on the wire and the new definition's announcement rebinds the client's mapping
				-- before sections apply, so a shipped removal would misresolve to the new definition. drop them; the
				-- client's mapping-teardown sweep owns the cleanup (see sweep_imported_cells in client.luau). the
				-- target-level signature below is the same check one level down.
				local relation_dense = ECS_PAIR_FIRST(component :: any) :: any
				local retired_relation = retired_relation_gens[relation_dense]
				if retired_relation ~= nil then
					local live_relation = tracked_relation_gens[relation_dense]
					if live_relation ~= nil and live_relation ~= retired_relation then
						removed_allowed = 0
					end
				end

				local dense_target = ECS_PAIR_SECOND(component :: any) :: any
				local retired = retired_target_gens[dense_target]
				target = tracked_target_gens[dense_target]
				if target == nil then
					-- the target died (or shed its last pair) since staging: recover the gen-qualified id retired at deindex
					-- time so removals can still name it on the wire. viewers who imported a dead target drop the pair with
					-- it (their bits clear against the unreplicate record below), but a name-mapped target is never deleted
					-- client-side, so its viewers need the explicit removals.
					target = retired
				else
					if is_tag then
						-- a tag relation's pairs follow their target's tag-ness, and the relation half is already known to be
						-- a tag here, so only the target needs the check (jecs.is_tag on the packed pair id would re-resolve
						-- and re-check both halves); gone targets never send, so the check is moot for them
						is_tag = jecs.is_tag(world, target :: any)
					end
					if retired ~= nil and retired ~= target then
						-- the target-level recycle signature: the dense id retired one tenant and re-indexed as another since
						-- the last call. the staged removals belong to the retired tenant, but pair-run targets are dense on
						-- the wire and the recycle frame's announcement (or creation) rebinds the dense id before sections
						-- apply, so a shipped removal would misresolve to the new tenant -- and in the same-subject case ride
						-- the same run as the new tenant's send and remove the just-added pair. drop them, like the
						-- relation-level signature above; the sweep owns the cleanup.
						removed_allowed = 0
					end
				end
				if target == nil then
					-- gone entirely: every viewer imported the (now dead) target and drops the pair with it locally, so no
					-- removal ships
					removed_allowed = 0
				elseif removed_allowed ~= 0 then
					local target_unrep = entity_unreplicate_mask[target :: any]
					if target_unrep ~= nil then
						removed_allowed = bit32.band(allocated, bit32.bnot(target_unrep))
					end
				end
				-- rows correlate between shards per cell, and a pair group's rows span several pair ids, so its row maps
				-- nest per pair id
				local pair_rows = group.pair_rows
				if pair_rows then
					local pair_id_rows = pair_rows[component :: any]
					if pair_id_rows == nil then
						pair_id_rows = fetch_scratch()
						pair_rows[component :: any] = pair_id_rows
					end
					rows = pair_id_rows
				end
			else
				-- the unpaired-cell recycle signature: this component's tracking stopped (its gen sits retired under
				-- its dense id) and a different definition re-tracked the same dense id since the last call. unpaired
				-- store keys are gen-qualified full ids, so nothing aliases here -- but section component ids are dense
				-- on the wire and the new definition's announcement rebinds the client's mapping before sections
				-- apply, so the removals would misresolve to the new definition (and the two definitions' sections,
				-- aliased on the wire, would race on shared subjects). drop them; the sweep owns the cleanup. a live
				-- entry equal to the component is a same-frame re-track of the same definition, whose genuine removals
				-- must ship.
				local component_dense = dense(component :: any)
				if retired_relation_gens[component_dense] == component then
					local live_relation = tracked_relation_gens[component_dense]
					if live_relation ~= nil and (live_relation :: any) ~= (component :: any) then
						removed_allowed = 0
					end
				end
			end

			for entity, new in new_visibility do
				local old = if old_visibility then old_visibility[entity] or 0 else 0
				local deferred = value_changes ~= nil and value_changes[entity] ~= nil
				local send = if deferred then 0 else bit32.band(new, bit32.bnot(old), allocated)
				local removed = bit32.band(old, bit32.bnot(new), removed_allowed)

				-- drop removals the client applies wholesale this frame: the subject's own unreplication here (the
				-- target's, being loop-invariant, already narrowed removed_allowed above). per-client, so only the
				-- coinciding bits clear; send is already 0 for those slots.
				if removed ~= 0 then
					local subj_unrep = entity_unreplicate_mask[entity]
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
							targets[row] = target :: number
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
						shard_last[component] = old_visibility
					end
					old_visibility[entity] = new
				end
			end

			group.count = count

			if old_visibility and next(old_visibility) == nil then
				shard_last[component] = nil
			end
		end
	end

	-- value cells of one shard: every slot that currently sees the cell (post-merge mask) receives the new
	-- value. pure removals never reach here. values stay staged for the remaining shards; generate_packets
	-- clears the shared store after the shard loop.
	local function resolve_value_cells(shard_last: ShardVisibility, allocated: VisibilityMask, shard_key_base: number)
		for component, changed_values in component_changes do
			local visibility = shard_last[component]
			if visibility == nil then
				continue
			end

			local is_pair = IS_PAIR(component :: any)
			local group = if is_pair then get_pair_group(component :: any) else get_group(component :: any)
			local count = group.count
			local entities = group.entities
			local values = group.values
			local send_nodes = group.send_nodes
			local removed_nodes = group.removed_nodes
			local targets = group.targets
			local rows = group.row_of

			-- the gen-qualified target this pair id's rows carry, read from the live-target gen cache (staged values
			-- never outlive their target: its death stages removals that drop them, so a live entry always exists),
			-- plus the per-pair-id row map (see resolve_visibility_cells)
			local target: number? = nil
			if is_pair then
				target = tracked_target_gens[ECS_PAIR_SECOND(component :: any) :: any]
				local pair_rows = group.pair_rows
				if pair_rows then
					local pair_id_rows = pair_rows[component :: any]
					if pair_id_rows == nil then
						pair_id_rows = fetch_scratch()
						pair_rows[component :: any] = pair_id_rows
					end
					rows = pair_id_rows
				end
			end

			for entity, value in changed_values do
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
						targets[row] = target :: number
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

	-- bucket pass: each cell lands in the section keyed by its accumulated mask node, one insert per cell no
	-- matter how many clients -- or shards -- see it; a pair group's cells land one level deeper, in their
	-- target's run within the section. a cell's send and removed masks are disjoint, so no client ever receives
	-- both for one cell. consuming a group also resets it for the next frame (see the PacketGroup type).
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

			-- one-entry caches over the row loop, mirroring the unreliable pass's cached draft (see
			-- accumulate_unreliable_archetype): consecutive rows usually share their visibility node -- and pair
			-- rows their target, since one pair id's cells resolve consecutively -- so a matching row reuses the
			-- previous row's lists instead of re-walking node_section_drafts (and, for pair groups, the run map).
			-- a real node is never 0, so the 0 sentinel can't false-hit; declared per group because the lists
			-- belong to the group's own drafts.
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
						table.insert(nulled :: any, entity)
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
						table.insert(ids :: any, entity)
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
					table.insert(removed_entities :: any, entity)
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
	-- the whole node shares -- the expansion pass appends one buffer reference per node to each sharing client,
	-- and assembly stamps it with one copy, no matter how many sections the node carries -- filling the per-node
	-- outputs declared above.
	local function finalize_node_sections()
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

	-- appends one node's shared buffer to one client's accumulators. the node's buffer, size, and value arrays
	-- ride in as arguments: they are invariant across the node's clients, so the callers resolve them once per
	-- node rather than paying the node-keyed lookups here, once per client. the value arrays append in the
	-- order their sections were written into the buffer, keeping the packet's side array aligned with it. the
	-- element-wise append below is deliberate: table.move reads as the idiom for concatenating two lists
	-- (wire.luau uses it for exactly that), but which one wins here depends on the shape, and the shape is easy
	-- to misread -- section_values holds one array per *hookless section*, so its length is the node's hookless
	-- section count (rarely more than a handful), while the call itself is paid once per node the client sees.
	-- that makes this many-appends-of-a-short-list, which table.insert wins; table.move only wins the
	-- one-append-of-a-long-list case. benchmarked both ways (2026-08-06): a micro-benchmark puts the crossover
	-- near eight appends of a 4-element source (table.move ~50% faster at one append, ~36% slower at sixteen),
	-- and the swap measured 9.5% slower at high fan-out against 14-20% faster on the broadcast one-node shape,
	-- with the realistic mixed benches at parity either way.
	local function scatter(client_index: number, node_buffer: buffer, node_size: number, section_values: { { any } }?)
		local target_buffers = client_buffers[client_index]
		if target_buffers == nil then
			target_buffers = fetch_scratch()
			client_buffers[client_index] = target_buffers
			client_sizes[client_index] = 0
		end
		client_sizes[client_index] += node_size
		table.insert(target_buffers, node_buffer)
		if section_values then
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

	-- the current trie path's decoded runs, persistent scratch for expand_node: every read at depth i follows a
	-- write at the same depth on the way down, so entries past the current path are never read.
	local path_bases = {} :: { number }
	local path_words = {} :: { number }

	local function expand_node(node: MaskTrieNode, depth: number)
		local node_buffer = node_buffers[node]
		if node_buffer then
			local node_size = node_sizes[node]
			local section_values = node_section_values[node]
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

	-- expansion pass: walk the trie depth-first, decoding each run once no matter how many nodes descend from
	-- it; a node's sections scatter to every client of every run on its path (countrz -> clients_by_index). each
	-- node the walk leaves is cleared into the free list for the next frame's append_mask_run, leaving the
	-- persistent root empty behind it. single-shard keys are the shard's raw mask words, expanded flat.
	local function expand_to_clients()
		if multi_shard then
			expand_node(mask_trie, 0)
			table.clear(mask_trie)
		else
			for mask, node_buffer in node_buffers do
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

	-- assembly pass: stamp each client's accumulated sections into their flat packet buffer, together with their
	-- entity create/delete lists. clients with entity create/delete but no component changes still need a
	-- packet; indices came from allocated bits, so clients_by_index resolves them.
	local function assemble_for(packets: { [Client]: Packet }, this_packet_frame: number, index: number)
		local client = clients_by_index[index]
		if packets[client] == nil then
			packets[client] = assemble_packet(
				this_packet_frame,
				unreplicated_by[index],
				replicated_by[index],
				frame_names,
				client_buffers[index],
				client_sizes[index] or 0,
				client_section_values[index]
			)
		end
	end

	local function assemble_client_packets(packets: { [Client]: Packet }, this_packet_frame: number)
		for index in client_buffers do
			assemble_for(packets, this_packet_frame, index)
		end
		for index in replicated_by do
			assemble_for(packets, this_packet_frame, index)
		end
		for index in unreplicated_by do
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

	-- builds a packet for every client in a single pass: a delta for each allocated client and a full packet for
	-- each pending (newly-joined) client. the shard loop runs on the outside, each occupied shard resolving its
	-- existence diff, dirty cells, and staged values against its own mask words and folding every cell's
	-- per-shard send / removed words into a path through the frame's mask trie (skipped with a single occupied
	-- shard -- the common case -- where the raw mask word keys the sections directly). the passes that follow
	-- (see each function above) are shaped so cell work is paid once per cell per occupied shard, and clients
	-- sharing a node -- across shards included -- have the node's sections, encoded back-to-back into one shared
	-- buffer, stamped into their packet buffers with a single buffer.copy: a cell visible to everyone encodes a
	-- single section no matter how many shards are occupied.
	local function generate_packets(): { [Client]: Packet }
		local packets = {} :: { [Client]: Packet }
		local this_packet_frame = next_packet_frame()
		group_frame += 1
		reset_frame_state()

		-- drain the name states staged since the last call; with nobody allocated there is no delta to ride
		-- (joiners get the full set, and nobody holds a mapping a retraction would need to end), so the drain
		-- discards them instead of collecting
		if shared_names.has_staged() then
			local collected: { [number]: string }? = if client_count > 0 then fetch_scratch() else nil
			shared_names.drain_staged(collected)
			frame_names = collected
		end

		local has_value_changes = next(component_changes) ~= nil

		-- resolve passes, per occupied shard: the existence diff first (the component cells drop removals against
		-- its record), then the dirty visibility cells, then the staged values.
		for shard = 1, shard_count do
			local shard_next = next_visibilities[shard]
			local allocated = allocated_masks[shard]
			local existing_last = last_visibilities[shard]
			-- a shard resolves if it has staged visibility, or if a staged value could land in it -- which takes
			-- allocated clients, a last tree for the value's mask to match, and staged values at all
			if shard_next == nil and (allocated == 0 or existing_last == nil or not has_value_changes) then
				continue
			end

			-- the shard's last tree is ensured up front so the resolve passes merge through it directly; it's pruned
			-- again at the end of the iteration if nothing landed.
			local shard_last = existing_last
			if shard_last == nil then
				shard_last = {}
				last_visibilities[shard] = shard_last
			end

			local base_index = (shard - 1) * 32
			local shard_key_base = shard * shard_key_span

			if shard_next then
				local entity_unreplicate_mask = resolve_existence_diff(shard_next, shard_last, allocated, base_index)
				resolve_visibility_cells(shard_next, shard_last, allocated, shard_key_base, entity_unreplicate_mask)
				release_scratch(entity_unreplicate_mask)
				next_visibilities[shard] = nil
			end

			if allocated ~= 0 then
				resolve_value_cells(shard_last, allocated, shard_key_base)
			end

			if next(shard_last) == nil then
				last_visibilities[shard] = nil
			end
		end
		component_changes = {}
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

		-- fresh clients' fulls build at the same point, where the slot's last masks exactly equal current
		-- visibility (the resolve passes merged this frame's changes in), so full_packet re-marks the same bits it
		-- finds and the next delta diffs correctly. the full replaces whatever delta the frame assembled for the
		-- client: built after the delta resolved, it already contains everything the delta carried.
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

	-- the chunk frame counter, cycling 0..2^32-1 like the packet frame: every chunk of one call carries it,
	-- and clients drop chunks older than the newest reconciled (wrap-aware), so reordered delivery never snaps
	-- values backward. independent of the packet frame counter above.
	local chunk_frame = -1

	-- per-call accumulators of the unreliable pass, mirroring the reliable frame accumulators above: drafts
	-- collect per accumulated-visibility node, keyed [node][cell id] (the component, or the packed pair id), and
	-- the finalize loop turns each node's drafts into its shared chunk list. both maps are cleared at entry so
	-- an errored call's stranded tables are abandoned to the GC, mirroring reset_frame_state's policy (the
	-- salvage guard contains user encode throws, but an internal error can still unwind mid-call).
	local unreliable_node_drafts = {} :: { [VisibilityNode]: { [number]: SectionDraft } }
	local unreliable_node_chunks = {} :: { [VisibilityNode]: { buffer } }

	-- the running call's escaping result map, held as an upvalue only while the expansion pass scatters into it
	-- (the pass functions are shared top-level closures, like the reliable passes')
	local unreliable_packets: { [Client]: { buffer } }? = nil

	-- the walked cell's per-shard last trees, prefetched once per cell id by prefetch_unreliable_visibility
	-- (false for shards holding none), plus the walk's one-entry cache: consecutive entities usually share their
	-- visibility, so the previous entity's node and draft are reused whenever the resolve matches --
	-- single-shard via a word comparison against the cached node key, multi-shard via the per-shard words of the
	-- previous entity (unreliable_cell_words, valid while unreliable_words_valid), which skips the trie walk
	-- entirely. a cached node of 0 marks an invisible entity, so equal-words runs of invisible entities skip on
	-- the comparison alone. entries past shard_count are stale and never read.
	local unreliable_cell_visibility = {} :: { { [Entity]: VisibilityMask } | false }
	local unreliable_cell_words = {} :: { VisibilityMask }
	local unreliable_words_valid = false
	local unreliable_cached_node: VisibilityNode = 0
	local unreliable_cached_draft: SectionDraft? = nil

	local function prefetch_unreliable_visibility(cell: number): boolean
		local any_visible = false
		for shard = 1, shard_count do
			local shard_last = last_visibilities[shard]
			local visibility = if shard_last then shard_last[cell :: any] else nil
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

	-- appends one archetype's cells of one unreliable cell id to the per-node drafts: per entity, the prefetched
	-- last masks resolve to a node (the raw word with one occupied shard, a trie path otherwise -- exactly the
	-- reliable pass's keying), and the live column read lands in the node's draft for the cell -- values under
	-- the ids, nils under nulled. masks intersect each shard's allocated word so a departed client's stale bit
	-- never creates or widens a chunk; a cell with no last mask is invisible (or not yet sent -- its membership
	-- add is still in flight) and skips. cell names the mask-store row and the draft key (the component, or the
	-- packed pair id); component/relation/target are the draft's wire naming, relation and target gen-qualified
	-- as chunk pair sections encode them.
	local function accumulate_unreliable_archetype(
		entities: { any },
		column: { any },
		cell: number,
		component: number?,
		relation: number?,
		target: number?
	)
		for row, entity in entities do
			local node: VisibilityNode
			if multi_shard then
				-- probe the shards' words against the previous entity's: while they keep matching nothing is appended, so
				-- a full match reuses the cached node (0 included -- an invisible run) with no trie walk at all; the
				-- first divergence replays the equal prefix into the trie and the loop appends inline from there, so a
				-- miss costs the plain fused walk plus the comparisons
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

	-- appends one node's chunk list to one client's packet list, creating the list on first touch. the chunk
	-- list and its length ride in as arguments, resolved once per node by the callers like scatter's. the lists
	-- escape to the caller, but the chunk buffers inside are shared by reference across every client of the
	-- node. the element-wise append is deliberate for the same reason as scatter's.
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

	-- builds the always-replicate chunks for every client in a single pass: every visible NetworkedUnreliable
	-- cell's current value is re-read live and re-sent, so the caller should send the returned chunks through an
	-- unreliable transport every frame -- a dropped or reordered chunk costs one frame of staleness, never
	-- state. visibility is read from the last-sent masks (what each client's reliable stream currently holds),
	-- so membership and privacy shifts take effect on this channel at the next generate_packets: a client
	-- legitimately holds a cell until the reliable removal reaches it, so the two channels always agree, and the
	-- two calls may run at independent cadences. cells walk per component through jecs' per-component archetype
	-- records (the world_each scheme -- undocumented internals, like get_components' sparse_array read), so
	-- archetypes without unreliable cells cost nothing; per entity the work is one mask probe per occupied
	-- shard, a column read, and the serdes encode, with cells of equal cross-shard visibility sharing one
	-- serialization no matter how many clients receive it. chunk buffers are shared by reference across every
	-- client of a node -- never mutate them -- and clients with nothing visible are omitted from the returned
	-- map.
	local function generate_unreliable_chunks(chunk_bytes: number?): { [Client]: { buffer } }
		local budget = default_chunk_bytes
		if chunk_bytes ~= nil then
			if chunk_bytes ~= chunk_bytes // 1 or chunk_bytes < min_chunk_bytes or chunk_bytes > max_chunk_bytes then
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
			-- unpaired cells: the component's own archetype records
			local idr = component_index[component :: any]
			if idr ~= nil and prefetch_unreliable_visibility(component :: any) then
				for archetype_id in idr.records do
					local archetype = archetypes[archetype_id]
					local entities = archetype.entities
					if #entities > 0 then
						accumulate_unreliable_archetype(
							entities :: any,
							archetype.columns_map[component :: any] :: any,
							component :: any,
							component :: any,
							nil,
							nil
						)
					end
				end
			end

			-- pair cells: the relation's wildcard record covers exactly the archetypes holding at least one pair of
			-- this relation, and same-relation pairs sit contiguously in archetype.types (see each_target), so the
			-- record's records/counts hand each archetype its exact pair slice with no types scan. the target gen
			-- resolves through the pair index, which covers every live pair of a tracked relation.
			local idr_pair = component_index[pair(component, jecs.Wildcard) :: any]
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
						local target = tracked_target_gens[ECS_PAIR_SECOND(cell :: any) :: any]
						if target ~= nil and prefetch_unreliable_visibility(cell :: any) then
							accumulate_unreliable_archetype(
								entities :: any,
								archetype.columns_map[cell :: any] :: any,
								cell :: any,
								nil,
								component :: any,
								target
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
		-- wire.finalize_chunks): a user encode failure -- a throwing hook, a violated size contract, a value no
		-- chunk can fit, or missing hooks entirely -- drops exactly the offending values from this call's
		-- chunks instead of erroring the whole call. warn-and-continue like measure_section_guarded, except the
		-- always-replicate cadence re-sends the dropped values next call, failing (and warning) again until the
		-- hook or value is fixed.
		local chunk_scratch = buffer.create(budget)
		for node, drafts in unreliable_node_drafts do
			unreliable_node_drafts[node] = nil
			local chunks: { buffer } = fetch_scratch()
			local pruned, salvage_error, salvage_id =
				finalize_chunks(chunk_frame, drafts, budget, resolve_serdes, chunk_scratch, chunks)
			if salvage_error ~= nil then
				warn(
					`a serdes encode failed while chunking {id_to_string(salvage_id :: any, world)}! {pruned} value(s) were dropped from this call's chunks and will not replicate until the hook or value is fixed: {salvage_error}`
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

	-- CONSTRUCTION CATCH-UP

	-- replays schema state added through the shared component set (see shared.luau) before this instance
	-- existed, routing every pre-existing cell through the same handlers the hooks run, so construction order
	-- is invisible: tagging a definition before or after the first duplecs.server(world) behaves identically.
	-- no delta can be missed -- clients only exist on an instance, so nothing but schema predates construction --
	-- which reduces the replay to establishing the mirrors, caches, announcements, and per-definition tracking
	-- hooks (staging against zero occupied shards writes nothing, and a joiner's full packet reads live state),
	-- and to firing the same guards a live add would have, which here surface from the construction call -- the
	-- valueless-Private normalization among them, warning from here and rewriting the value in place. one
	-- behavioral seam: a privacy filter sanitizes against the tracked-client set like any filter set, and no
	-- client can be tracked before construction, so every client a pre-construction filter names is pruned,
	-- from the value as well as the caches -- the standing contract that filters name only tracked clients
	-- (see prune_privacy_filters) -- with each pruned filter warning from the construction call
	-- (warn_pruned_clients), since a populated pre-construction filter can never mean what it says.

	-- holders are collected before any handler runs: the handlers connect hooks (the first
	-- world:added/changed/removed on a component sets EcsOnAdd/etc on it, structurally moving it) and the
	-- guards remove offending tags, either of which would invalidate the live world:each walk collecting them.
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

	local function catch_up_tracking_tag(tag: Component, on_added: (Entity, Id) -> ())
		local definitions = collect_holders(tag)
		local subjects, pair_ids = collect_pair_holders(tag)
		for index, entity in subjects do
			-- always the paired misuse; the handler removes the pair and errors
			on_added(entity, pair_ids[index])
		end
		for _, definition in definitions do
			on_added(definition, tag)
		end
	end

	local function catch_up()
		-- filters and delegation first: everything below reads the gates they establish. Private precedes
		-- InheritsPrivacy so each replayed edge derives its delegator's effective words against own words already
		-- cached; the reverse order converges all the same -- a filter replayed after an edge fans out over its
		-- descendants and re-derives them (see refresh_descendants) -- but pays a wasted derivation per edge.
		local private_holders = collect_holders(Private)
		local private_subjects, private_pair_ids = collect_pair_holders(Private)
		for _, entity in private_holders do
			on_private_set(entity, Private, world:get(entity, Private))
		end
		for index, entity in private_subjects do
			local id = private_pair_ids[index]
			on_private_set(entity, id, world:get(entity, id :: any))
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

	-- connects the replication hooks (the tracking tags, Replicated, Private, InheritsPrivacy, and jecs.Name),
	-- then replays whatever schema state predates this instance -- the shared component set is minted at the
	-- world's first duplecs contact, so a schema module may have tagged definitions, added filters, or
	-- delegated privacy before duplecs.server first ran here. called once before the constructor returns, so
	-- tracking is live from construction either way: a misuse errors at the offending call site when a hook
	-- catches it live, and from the construction call when the catch-up walks find it pre-existing.
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

		hooks.added(world, InheritsPrivacy, on_inherits_added)
		hooks.removed(world, InheritsPrivacy, on_inherits_removed)

		-- seed the named mirror: a plain mirror write -- nothing is tracked or replicated yet, so no announcement
		-- or restage can be due, and the loop body mutates nothing, so the live world:each walk is safe (unlike
		-- the catch-up walks, whose handlers move entities, so they pre-collect). must run before the catch-up
		-- walks, whose announce decisions read the mirror; the order against the hook connections above is free --
		-- their structural moves (the first world:added/changed/removed on a component sets EcsOnAdd/etc on it,
		-- moving it) run strictly before or strictly after this walk, never during it.
		for entity in world:each(jecs.Name) do
			named_entities[entity] = true
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
		Serdes = Serdes,

		-- debug introspection (unstable, for tests and diagnostics)
		_client_shard = client_shard,
	}
end

export type ServerInstance = typeof(create_server(nil :: any, nil :: any))

-- the memoized accessor (duplecs.server): the first call on a world constructs the instance and stores it on
-- the world's shared record -- inside the world itself, see shared.luau for why nothing module-level may
-- reference it -- so every later call returns that same instance and any system can resolve it from the world
-- alone. the split from create_server exists for the memo's types: the record's slot is typed unknown (the
-- instance type lives here, below shared.luau in the require graph), so the early return needs the typeof
-- above to hand callers the full instance type. a constructor error (a pre-existing misuse surfaced by the
-- catch-up walks) simply propagates with nothing memoized: it is a programming bug to stop and fix, not a
-- state to recover from.
return function(world: World): ServerInstance
	local shared_record = get_shared(world)
	local instance = shared_record.server
	if instance ~= nil then
		return instance :: ServerInstance
	end
	local created = create_server(world, shared_record)
	shared_record.server = created
	return created
end
