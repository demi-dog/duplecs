--!strict

-- the server's opt-in byte counters behind set_packet_stats, built by create_packet_stats from the slot
-- bookkeeping the server passes in. while disabled the packet passes pay one branch on their recorder per
-- visibility node -- at finalize and at expansion, and once per full packet -- and nothing per cell or per
-- client. while enabled each node's drafts tally once into a per-key breakdown (tally_node), and the expansion
-- charges it times the node's recipient count, read off the node's mask words (a popcount per word, the trie
-- path's words in multi-shard mode) rather than per client; the per-packet totals come from the returned
-- packets' own headers. a fresh client's delta is assembled and then replaced by its full, so its bits are
-- masked out of the recipient counts (fresh_words) and only the full is charged. debug-rate code, like
-- inspect.luau's describers: it allocates freely, and none of it runs while the counters are off.

local types = require("./types")
local wire = require("./wire")

type Id = types.Id
type Client = types.Client
type Packet = types.Packet
type PacketStats = types.PacketStats
type ComponentStats = types.ComponentStats
type SectionDraft = wire.SectionDraft

local id_width = wire.id_width
local gen_id_width = wire.gen_id_width
local chunk_header_width = wire.chunk_header_width
local read_packet_header = wire.read_packet_header
local read_name = wire.read_name
local read_chunk_section_header = wire.read_chunk_section_header

-- one visibility node's bytes of one stats key (a component, or a relation for its pairs), encoded once and
-- multiplied by the node's recipient count at expansion
type NodeShare = { bytes: number, entries: number, side_values: number }
type NodeBreakdown = { [Id]: NodeShare }

-- what the packet passes call while an entry point records. nodes are keyed like the passes' node stores (the
-- raw mask word with one occupied shard, the trie node with several). charge_word charges a single-shard node;
-- charge_path a trie node, through the run words and base client indices of its path.
export type StatsRecorder = {
	tally_node: (node: any, drafts: { SectionDraft }, count: number) -> (),
	tally_chunk_node: (node: any, drafts: { [any]: SectionDraft }, chunks: { buffer }) -> (),
	charge_full: (drafts: { SectionDraft }) -> (),
	charge_word: (node: any, word: number, shard: number) -> (),
	charge_path: (node: any, words: { number }, bases: { number }, depth: number) -> (),
	finish_packets: (packets: { [Client]: Packet }) -> (),
	finish_chunks: (packets: { [Client]: { buffer } }) -> (),
}

local function new_packet_stats(): PacketStats
	return {
		packets = 0,
		sent_bytes = 0,
		overhead_bytes = 0,
		components = {},
	}
end

local function stats_entry(stats: PacketStats, key: Id): ComponentStats
	local entry = stats.components[key]
	if entry == nil then
		entry = {
			encoded_bytes = 0,
			sent_bytes = 0,
			entries = 0,
			side_values = 0,
		}
		stats.components[key] = entry
	end
	return entry
end

local function node_share(breakdown: NodeBreakdown, key: Id): NodeShare
	local share = breakdown[key]
	if share == nil then
		share = { bytes = 0, entries = 0, side_values = 0 }
		breakdown[key] = share
	end
	return share
end

local function popcount(word: number): number
	local count = 0
	while word ~= 0 do
		word = bit32.band(word, word - 1)
		count += 1
	end
	return count
end

-- tallies a node's (or a full packet's) measured drafts -- measure stashed each one's size and serdes plan on
-- it -- adding their encoded bytes to the stats and returning the per-key breakdown the node's recipients are
-- charged at expansion. pair drafts key by their relation, so a definition serving as both an unpaired
-- component and a relation rolls both roles into one entry. a grouped draft's hookless runs carry their own
-- serdes field; a single-run pair draft encodes the plain layout, whose plan lives on the draft.
local function tally_drafts(stats: PacketStats, drafts: { SectionDraft }, count: number): NodeBreakdown
	local breakdown = {} :: NodeBreakdown
	for i = 1, count do
		local draft = drafts[i]
		local key: Id = (draft.relation or draft.component) :: any
		local size = draft.size :: number
		local entries = 0
		local side_values = 0
		local runs = draft.runs
		if runs ~= nil then
			local grouped = #runs > 1
			for _, run in runs do
				local ids_count = if run.ids then #run.ids else 0
				entries += ids_count + (if run.nulled then #run.nulled else 0) + (if run.removed
					then #run.removed
					else 0)
				local hookless = if grouped then run.serdes == nil else draft.serdes == nil
				if hookless then
					side_values += ids_count
				end
			end
		else
			local ids_count = if draft.ids then #draft.ids else 0
			entries += ids_count + (if draft.nulled then #draft.nulled else 0) + (if draft.removed
				then #draft.removed
				else 0)
			if draft.serdes == nil then
				side_values += ids_count
			end
		end
		local share = node_share(breakdown, key)
		share.bytes += size
		share.entries += entries
		share.side_values += side_values
		stats_entry(stats, key).encoded_bytes += size
	end
	return breakdown
end

-- the chunk counterpart of tally_drafts, read back off a node's finished chunks: every chunk section's bytes
-- (continuations' repeated headers included) go to its component, keyed back from the wire's dense id
-- through the node's drafts; the chunk headers are overhead, counted from the returned lists.
local function tally_chunks(stats: PacketStats, drafts: { [any]: SectionDraft }, chunks: { buffer }): NodeBreakdown
	local key_of = {} :: { [number]: Id }
	for _, draft in drafts do
		local key: Id = (draft.relation or draft.component) :: any
		key_of[(key :: any) % 2 ^ 24] = key
	end
	local breakdown = {} :: NodeBreakdown
	for _, chunk in chunks do
		local offset = chunk_header_width
		local chunk_size = buffer.len(chunk)
		while offset < chunk_size do
			local _, next_offset, _, first_id, _, ids_count, nulled_count = read_chunk_section_header(chunk, offset)
			local key = key_of[first_id]
			local size = next_offset - offset
			local share = node_share(breakdown, key)
			share.bytes += size
			share.entries += ids_count + nulled_count
			stats_entry(stats, key).encoded_bytes += size
			offset = next_offset
		end
	end
	return breakdown
end

-- charges a node's breakdown to its recipients: every byte, entry, and side value once per client receiving
-- the node's shared bytes
local function charge_recipients(stats: PacketStats, breakdown: NodeBreakdown?, recipients: number)
	if breakdown == nil or recipients == 0 then
		return
	end
	for key, share in breakdown do
		local entry = stats_entry(stats, key)
		entry.sent_bytes += share.bytes * recipients
		entry.entries += share.entries * recipients
		entry.side_values += share.side_values * recipients
	end
end

-- a packet's bytes outside its sections: the header, the entity lists, and the names list, read off the
-- packet's own header -- independent of the per-node attribution, so the two summing to the packet's length
-- is a real check rather than a tautology
local function packet_overhead(data: buffer): number
	local _, offset, unreplicated_count, replicated_count, names_count = read_packet_header(data)
	offset += unreplicated_count * id_width + replicated_count * gen_id_width
	for _ = 1, names_count do
		local _, _, next_offset = read_name(data, offset)
		offset = next_offset
	end
	return offset
end

-- the server's counters, built from the slot bookkeeping it passes in: tracked_clients and fresh_clients,
-- read as a reliable call opens to find the fresh clients' bits, and its slot math. returns the three public
-- exports plus the per-call openers, which return the recorder while the counters are on and nil while off --
-- the nil the passes branch on. one recorder serves every call, and opening resets it, so whatever an errored
-- call left behind is dropped.
local function create_packet_stats(
	tracked_clients: { [Client]: number },
	fresh_clients: { [Client]: true },
	shard_of: (client_index: number) -> number,
	slot_bit_of: (client_index: number) -> number
)
	local packet_stats_enabled = false
	local last_packet_stats: PacketStats? = nil
	local last_chunk_stats: PacketStats? = nil

	-- the open call's counters; every node's breakdown, keyed like the node stores; and the fresh clients' bits
	-- per shard, for the reliable call's recipient counts
	local building_stats = new_packet_stats()
	local node_breakdowns = {} :: { [any]: NodeBreakdown }
	local fresh_words = {} :: { [number]: number }

	-- one mask word's recipients within its shard, fresh clients excluded
	local function node_recipients(word: number, shard: number): number
		local fresh = fresh_words[shard]
		if fresh ~= nil then
			word = bit32.band(word, bit32.bnot(fresh))
		end
		return popcount(word)
	end

	local function tally_node(node: any, drafts: { SectionDraft }, count: number)
		node_breakdowns[node] = tally_drafts(building_stats, drafts, count)
	end

	local function tally_chunk_node(node: any, drafts: { [any]: SectionDraft }, chunks: { buffer })
		node_breakdowns[node] = tally_chunks(building_stats, drafts, chunks)
	end

	-- a full packet is its own encoding, sent to its one recipient
	local function charge_full(drafts: { SectionDraft })
		charge_recipients(building_stats, tally_drafts(building_stats, drafts, #drafts), 1)
	end

	local function charge_word(node: any, word: number, shard: number)
		charge_recipients(building_stats, node_breakdowns[node], node_recipients(word, shard))
	end

	-- a base client index's shard is the shard of its first slot
	local function charge_path(node: any, words: { number }, bases: { number }, depth: number)
		local recipients = 0
		for i = 1, depth do
			recipients += node_recipients(words[i], shard_of(bases[i]))
		end
		charge_recipients(building_stats, node_breakdowns[node], recipients)
	end

	-- closes a call's counters with the returned buffers' own totals, returning the finished stats
	local function finish_stats(buffers: { buffer }, overheads: { number }): PacketStats
		local stats = building_stats
		for i, data in buffers do
			stats.packets += 1
			stats.sent_bytes += buffer.len(data)
			stats.overhead_bytes += overheads[i]
		end
		table.clear(node_breakdowns)
		table.clear(fresh_words)
		return stats
	end

	local function finish_packets(packets: { [Client]: Packet })
		local buffers = {} :: { buffer }
		local overheads = {} :: { number }
		for _, packet in packets do
			table.insert(buffers, packet.data)
			table.insert(overheads, packet_overhead(packet.data))
		end
		last_packet_stats = finish_stats(buffers, overheads)
	end

	local function finish_chunks(packets: { [Client]: { buffer } })
		local buffers = {} :: { buffer }
		local overheads = {} :: { number }
		for _, chunks in packets do
			for _, chunk in chunks do
				table.insert(buffers, chunk)
				table.insert(overheads, chunk_header_width)
			end
		end
		last_chunk_stats = finish_stats(buffers, overheads)
	end

	local recorder: StatsRecorder = {
		tally_node = tally_node,
		tally_chunk_node = tally_chunk_node,
		charge_full = charge_full,
		charge_word = charge_word,
		charge_path = charge_path,
		finish_packets = finish_packets,
		finish_chunks = finish_chunks,
	}

	local function open(): StatsRecorder?
		if not packet_stats_enabled then
			return nil
		end
		building_stats = new_packet_stats()
		table.clear(node_breakdowns)
		table.clear(fresh_words)
		return recorder
	end

	-- opens a generate_packets call's counters, with the fresh clients' bits marked for exclusion
	local function begin_packets(): StatsRecorder?
		local opened = open()
		if opened ~= nil then
			for client in fresh_clients do
				local client_index = tracked_clients[client]
				if client_index ~= nil then
					local shard = shard_of(client_index)
					fresh_words[shard] = bit32.bor(fresh_words[shard] or 0, slot_bit_of(client_index))
				end
			end
		end
		return opened
	end

	-- opens a generate_unreliable_chunks call's counters; chunks have no fulls to replace them
	local function begin_chunks(): StatsRecorder?
		return open()
	end

	-- turning the counters off drops the last calls' tables, so a stale reading can't outlive the switch
	local function set_packet_stats(enabled: boolean)
		packet_stats_enabled = enabled == true
		if not packet_stats_enabled then
			last_packet_stats = nil
			last_chunk_stats = nil
		end
	end

	local function get_packet_stats(): PacketStats?
		return last_packet_stats
	end

	local function get_chunk_stats(): PacketStats?
		return last_chunk_stats
	end

	return {
		set_packet_stats = set_packet_stats,
		get_packet_stats = get_packet_stats,
		get_chunk_stats = get_chunk_stats,
		begin_packets = begin_packets,
		begin_chunks = begin_chunks,
	}
end

return {
	create_packet_stats = create_packet_stats,
}
