--!strict
--!native
--!optimize 2

-- the wire format: the layouts below are the authoritative reference, and every function that encodes or
-- decodes their bytes lives in this module -- the server's packet passes (server.luau) drive the writers, the
-- client's reconcile (client.luau) consumes the header readers.

-- note: in warn/error strings, `$` prefixes verified-live entity ids and `?` unverifiable ones (this module
-- never has a world to verify against, so its ids all print behind `?`) -- see diagnostics.luau, which owns
-- the convention and the [duplecs] prefix every message carries.

-- entity, component, relation, and target ids on the wire are 24-bit dense ids (u16 low half + u8 high half,
-- little-endian): jecs packs a gen-qualified id as index + generation * 2^24 with index < 2^24 and generation
-- < 2^16, and the server never holds two live entities sharing a dense id, so 3 bytes identify any live id.
-- the generation matters in exactly two places -- the replicated (creation) list and the names list, where a
-- client first learns an id (including the generation get_server_entity exposes for client->server requests) --
-- so their entries stay full-gen 40-bit ids (u32 low half + u8 high half) at 5 bytes. write_id / read_id and
-- write_gen_id / read_gen_id below are the one encode/decode authority; write_id truncates whatever
-- gen-qualified id it is handed to its dense half.

-- counts and section lengths are u16 by default; a writer whose section (or packet lists) would overflow one
-- sets its wide flag and writes u32s instead, so the narrow common case never pays for the pathological one.
-- counts of empty lists are omitted entirely, gated by the has_* / packet_* flag bits.

-- packet buffer layout (little-endian, in order):
--   u8  version                  the wire format version (wire_version below);
--                                reconcile_packet refuses a mismatch
--   u32 packet_frame             cycles 0..2^32-1, shared by every packet of one call
--   u8  flags                    packet_flag_unreplicated | packet_flag_replicated
--                                | packet_flag_wide | packet_flag_names
--   uN  unreplicated_count       only when packet_flag_unreplicated is set
--   uN  replicated_count         only when packet_flag_replicated is set
--   uN  names_count              only when packet_flag_names is set
--   id24 unreplicated[unreplicated_count]
--   id40 replicated[replicated_count]
--   names[names_count]           each: id40 entity, u8 length, `length` name bytes
--   sections back-to-back until the end of the buffer
-- (uN is u16, or u32 when packet_flag_wide is set) the names list announces shared definitions (networked
-- components and named pair targets) as (id, jecs.Name) entries, so a client world defining the same names
-- maps them automatically; announcements apply after the entity lists and before any section resolves. an
-- entry with length 0 is a *retraction* -- the announcement is withdrawn and clients end the mapping it
-- established -- and applies only after every section: a retracting packet's sections may still reference the
-- id (e.g. the explicit pair removals a named target's death stages). names are never empty strings, so the
-- zero length is unambiguous.

-- section layout within the packet buffer (little-endian, in order):
--   u8  flags                    flag_pair | flag_inline_values | flag_has_ids
--                                | flag_has_nulled | flag_has_removed | flag_wide
--   uN  length                   total bytes of the section, prefix included;
--                                only when flag_inline_values is set (inline
--                                values are unskippable without it -- every
--                                other section's size follows from its counts)
--   id24 component               (unpaired sections) or
--   id24 relation, id24 target   (single-target pair sections)
--   uN  ids_count                only when flag_has_ids is set
--   uN  nulled_count             only when flag_has_nulled is set
--   uN  removed_count            only when flag_has_removed is set
--   id24 ids[ids_count]
--   serdes-encoded values        (only when flag_inline_values is set)
--   id24 nulled[nulled_count]
--   id24 removed[removed_count]
-- (uN is u16, or u32 when flag_wide is set) the length prefix lets the reconciler skip a section it cannot
-- resolve locally without decoding it; only inline values need one (serdes-encoded bytes have no computable
-- size without the hooks), while every other section skips through its counts, mirroring the runs of the
-- grouped layout below.

-- each serdes-encoded inline value rides as a u16 length prefix followed by its encoded bytes (see the Serdes
-- type in types.luau); a registration with a static size omits the prefix. the framing is part of the value
-- stream's encoding, not a flag-gated field -- hooks are required to be symmetric, so both sides already
-- agree on the sizing -- and the prefix stays u16 even in wide sections, so a value encoding to 2^16 bytes or
-- more is refused at packet generation.

-- a pair section carrying several targets of one relation encodes the grouped layout instead, paying the
-- relation id once and framing each target's lists as a run; a single-target pair draft keeps the plain
-- layout above, which is smaller until a second target shares the section. grouped pair section layout
-- (little-endian, in order):
--   u8  flags                    flag_pair | flag_runs | flag_side_values
--                                | flag_wide
--   uN  length                   total bytes of the section, prefix included;
--                                always present -- skipping an unresolvable
--                                relation would otherwise mean walking every
--                                run header
--   id24 relation
--   uN  run_count                always >= 1
--   runs back-to-back until the end of the section, each:
--     u8  run_flags              flag_inline_values | flag_has_ids
--                                | flag_has_nulled | flag_has_removed
--     id24 target
--     uN  run_length             total bytes of the run, prefix included; only
--                                when flag_inline_values is set (inline values
--                                are unskippable without it -- every other
--                                run's size follows from its counts)
--     uN  ids_count              only when flag_has_ids is set
--     uN  nulled_count           only when flag_has_nulled is set
--     uN  removed_count          only when flag_has_removed is set
--     id24 ids[ids_count]
--     serdes-encoded values      (only when flag_inline_values is set)
--     id24 nulled[nulled_count]
--     id24 removed[removed_count]
-- (uN is u16, or u32 when the section's flag_wide is set) hookless runs' values do not ride runs
-- individually: they concatenate, in run order, into a single entry of the packet's side array -- marked by
-- flag_side_values so a reader always consumes exactly one entry per flagged section -- with each hookless
-- run claiming ids_count entries, so a reader that skips runs (or the whole section) keeps the side cursor
-- aligned without decoding anything.

-- an unreliable chunk is the self-contained unit of the always-replicate (NetworkedUnreliable) channel: the
-- server re-reads every visible unreliable cell each call and packs the values into chunks of at most the
-- caller's byte budget, so a dropped or reordered chunk costs one frame of staleness, never state. chunks
-- carry values and nulled ids only -- membership and removals ride the reliable path -- and their values are
-- always serdes-encoded (chunking requires byte-exact sizing, so unreliable components must have hooks; there
-- is no side array). unreliable chunk layout (little-endian, in order):
--   u8  version                  wire_version + chunk_version_flag: the high
--                                bit keeps a chunk loudly distinguishable from
--                                a reliable packet, so either buffer handed to
--                                the wrong reconcile entry point is refused
--                                with a pointed error instead of misparsing
--   u32 frame                    the unreliable frame counter, shared by every
--                                chunk of one call; the client drops chunks
--                                older than the newest it has reconciled
--                                (wrap-aware), so reordered delivery never
--                                snaps values backward
--   sections back-to-back until the end of the buffer, each:
--     u8  flags                  flag_pair | flag_has_ids | flag_has_nulled
--     u16 length                 total bytes of the section, prefix included;
--                                always present (values are serdes-encoded, so
--                                a section is unskippable without it) and
--                                never wide -- the chunk budget is capped
--                                below 2^16
--     id24 component             (unpaired sections) or
--     id24 relation, id24 target (pair sections; always single-target -- the
--                                grouped run layout never rides in chunks)
--     u16 ids_count              only when flag_has_ids is set
--     u16 nulled_count           only when flag_has_nulled is set
--     id24 ids[ids_count]
--     serdes-encoded values
--     id24 nulled[nulled_count]
-- one component's cells may span chunks: when the next cell would overflow the budget, the section closes and
-- a fresh section naming the same component opens the next chunk -- section headers repeat, cells never
-- split. nulled ids fill a section only once the value cells are exhausted.

-- read_packet_header / read_section_header below are the one decode authority for the header half of each
-- layout (everything above the id lists); readers walk the lists themselves from the returned counts and
-- offset, so the client's reconcile stays a fused stream-parse-and-apply allocating nothing of its own --
-- only decode's per-value buffers (see client.luau). built on the same readers, decode_packet /
-- decode_section parse a packet into an allocating record view of raw wire ids for the verification suite and
-- diagnostics.

local jecs = require("../roblox_packages/jecs")

-- jecs.pair under the plain-number domain this module works in (draft and wire ids are numbers, and the
-- packed pair id they combine into is one too), so the serdes-key and record-view call sites don't cast
-- per call. every id is a number at runtime, so this is a retyped view of the original, not a copy.
local pair = (jecs.pair :: any) :: (relation: number, target: number) -> number

local types = require("./types")
local diagnostics = require("./diagnostics")

local fail = diagnostics.fail
local id_to_string = diagnostics.id_to_string

type Serdes<T = any> = types.Serdes<T>

-- resolves the serdes hooks a section's inline values are encoded with (finalize_section) or decoded with
-- (decode_section), shaped like the serdes store's resolve_serdes (see serdes.luau)
type ResolveSerdes = (component: any, relation: any) -> Serdes?

-- section buffer flag bits. flag_inline_values / flag_has_* double as the run flag bits of grouped pair
-- sections, whose section-level flags only ever carry flag_pair | flag_runs | flag_side_values | flag_wide.
local flag_pair = 0b00000001
local flag_inline_values = 0b00000010
local flag_has_ids = 0b00000100
local flag_has_nulled = 0b00001000
local flag_has_removed = 0b00010000
local flag_wide = 0b00100000
local flag_runs = 0b01000000
local flag_side_values = 0b10000000

-- packet buffer flag bits
local packet_flag_unreplicated = 0b0001
local packet_flag_replicated = 0b0010
local packet_flag_wide = 0b0100
local packet_flag_names = 0b1000

-- bytes per dense (id24) and full-gen (id40) wire id, the widths of the packet header's leading version byte
-- and packet frame, and the largest value a narrow (u16) count or length can carry before a writer must set
-- its wide flag
local id_width = 3
local gen_id_width = 5
local version_width = 1
local packet_frame_width = 4
local narrow_limit = 0xffff

-- the wire format version, written as the packet buffer's leading u8 -- ahead of the packet frame, so it sits
-- at a fixed offset no matter how the rest of the layout shifts across versions. the client's
-- reconcile_packet refuses any packet whose version isn't this one.
--
-- BUMP THIS on any change to the byte layout of a packet, section, run, id, count, or unreliable chunk in
-- this module -- a client on an older build must reject a newer packet loudly rather than silently misparse
-- it. retrofitting a version field after 1.0.0 would itself have been a breaking wire change, which is why it
-- ships now. (the byte's high bit is claimed by chunk_version_flag below, so 127 format revisions of headroom
-- remain -- still ample.)
local wire_version = 2

-- the leading version byte of an unreliable chunk is wire_version with this high bit set, keeping the two
-- buffer kinds mutually unparseable: check_version / check_chunk_version each refuse the other kind with a
-- pointed error instead of a bogus version mismatch.
local chunk_version_flag = 0x80

-- the width of a chunk's header: the version byte plus the u32 unreliable frame counter; sections follow
-- immediately after.
local chunk_frame_width = 4
local chunk_header_width = version_width + chunk_frame_width

-- the chunk budget bounds generate_unreliable_chunks accepts, both derived from the layout above rather than
-- picked. the floor is the smallest budget an empty chunk can still fit one cell of *any* section into: a
-- chunk header, the widest section header (flags, length, and a pair section's relation and target), one
-- count field, and one id -- below it the packing loop could open a chunk that fits nothing at all. the
-- ceiling is what a chunk section's u16 length field can address.
local min_chunk_bytes = chunk_header_width + (1 + 2 + id_width * 2) + 2 + id_width
local max_chunk_bytes = narrow_limit

-- the split points of the ids' wire halves. the dense encoding leans on jecs' index/generation split at 2^24:
-- a dense id is a gen-qualified id's low 24 bits, so write_id truncates the generation of whatever id it is
-- handed and gets the dense half for free.
local id_split = 2 ^ 16
local gen_id_split = 2 ^ 32

local function write_id(data: buffer, offset: number, id: number)
	buffer.writeu16(data, offset, id % id_split)
	buffer.writeu8(data, offset + 2, id // id_split % 256)
end

local function read_id(data: buffer, offset: number): number
	return buffer.readu16(data, offset) + buffer.readu8(data, offset + 2) * id_split
end

local function write_gen_id(data: buffer, offset: number, id: number)
	buffer.writeu32(data, offset, id % gen_id_split)
	buffer.writeu8(data, offset + 4, id // gen_id_split)
end

local function read_gen_id(data: buffer, offset: number): number
	return buffer.readu32(data, offset) + buffer.readu8(data, offset + 4) * gen_id_split
end

-- reads a packet buffer's leading wire format version byte. it sits at offset 0 ahead of every other field
-- precisely so it stays readable no matter how the rest of the layout changes between versions.
local function read_version(data: buffer): number
	return buffer.readu8(data, 0)
end

-- validates a packet buffer's leading version byte against wire_version, erroring loudly on a mismatch. every
-- entry point that consumes a whole packet buffer -- the client's reconcile_packet and get_packet_frame, and
-- the record-view decode_packet below -- gates on this before reading any other field, so a build handed a
-- packet from a different wire format refuses it rather than misparsing it.
local function check_version(data: buffer)
	local version = read_version(data)
	if version ~= wire_version then
		if bit32.band(version, chunk_version_flag) ~= 0 then
			fail(
				`received an unreliable chunk on the reliable path! unreliable chunks must be applied with reconcile_chunk.`
			)
		end
		fail(
			`received a packet encoded with wire format version {version}, but this build of duplecs speaks version {wire_version}! the sender and receiver must run compatible duplecs versions.`
		)
	end
end

-- the chunk-side counterpart to check_version: validates an unreliable chunk's leading version byte, refusing
-- a reliable packet (or a chunk from a different wire format) before any other field is read.
local function check_chunk_version(data: buffer)
	local version = read_version(data)
	if version == wire_version + chunk_version_flag then
		return
	end
	if bit32.band(version, chunk_version_flag) ~= 0 then
		fail(
			`received an unreliable chunk encoded with wire format version {version - chunk_version_flag}, but this build of duplecs speaks version {wire_version}! the sender and receiver must run compatible duplecs versions.`
		)
	end
	fail(`received a reliable packet on the unreliable path! reliable packets must be applied with reconcile_packet.`)
end

-- reads a chunk's frame counter (the u32 just past the version byte), shared by every chunk of one
-- generate_unreliable_chunks call.
local function read_chunk_frame(data: buffer): number
	return buffer.readu32(data, version_width)
end

-- reads a packet buffer's frame counter (the field just past the version byte). the full header read below
-- returns it too; this is the standalone accessor for callers that want only the packet frame without walking
-- the counts.
local function read_packet_frame(data: buffer): number
	return buffer.readu32(data, version_width)
end

-- reads a packet buffer's header: the packet frame, the offset of the first entity list, and the three
-- flag-gated list counts.
local function read_packet_header(data: buffer): (number, number, number, number, number)
	local packet_frame = buffer.readu32(data, version_width)
	local flags = buffer.readu8(data, version_width + packet_frame_width)
	local count_width = 2
	local read_count = buffer.readu16
	if bit32.band(flags, packet_flag_wide) ~= 0 then
		count_width = 4
		read_count = buffer.readu32
	end
	local offset = version_width + packet_frame_width + 1
	local unreplicated_count = 0
	if bit32.band(flags, packet_flag_unreplicated) ~= 0 then
		unreplicated_count = read_count(data, offset)
		offset += count_width
	end
	local replicated_count = 0
	if bit32.band(flags, packet_flag_replicated) ~= 0 then
		replicated_count = read_count(data, offset)
		offset += count_width
	end
	local names_count = 0
	if bit32.band(flags, packet_flag_names) ~= 0 then
		names_count = read_count(data, offset)
		offset += count_width
	end
	return packet_frame, offset, unreplicated_count, replicated_count, names_count
end

-- reads one shared-name entry at data[offset] within a packet's names list: the full-gen wire id, its name
-- (empty for a retraction), and the offset just past the entry.
local function read_name(data: buffer, offset: number): (number, string, number)
	local id = read_gen_id(data, offset)
	local length = buffer.readu8(data, offset + gen_id_width)
	local name = buffer.readstring(data, offset + gen_id_width + 1, length)
	return id, name, offset + gen_id_width + 1 + length
end

-- reads a section's header at data[section_offset]: the flags, the offset just past the section, the offset
-- of the first id list (grouped: of the first run), the raw wire ids naming the section -- the component, or
-- the relation with the target as the fifth return for single-target pair sections -- the three flag-gated
-- list counts, and (grouped sections only) the run count as the ninth return. callers branch pair-ness on the
-- target being non-nil and grouped-ness on the run count being non-nil; a grouped section's runs parse
-- through read_run_header from the returned offset.
local function read_section_header(
	data: buffer,
	section_offset: number
): (number, number, number, number, number?, number, number, number, number?)
	local flags = buffer.readu8(data, section_offset)
	local count_width = 2
	local read_count = buffer.readu16
	if bit32.band(flags, flag_wide) ~= 0 then
		count_width = 4
		read_count = buffer.readu32
	end
	local offset = section_offset + 1

	-- the length prefix rides only where counts can't size the section: grouped sections always, plain sections
	-- only with inline values (see the layouts); everything else computes its end from the counts below
	local has_length = bit32.band(flags, flag_runs + flag_inline_values) ~= 0
	local next_offset = 0
	if has_length then
		next_offset = section_offset + read_count(data, offset)
		offset += count_width
	end

	local first_id = read_id(data, offset)
	offset += id_width

	if bit32.band(flags, flag_runs) ~= 0 then
		local run_count = read_count(data, offset)
		offset += count_width
		return flags, next_offset, offset, first_id, nil, 0, 0, 0, run_count
	end

	local target_id: number? = nil
	if bit32.band(flags, flag_pair) ~= 0 then
		target_id = read_id(data, offset)
		offset += id_width
	end

	local ids_count = 0
	if bit32.band(flags, flag_has_ids) ~= 0 then
		ids_count = read_count(data, offset)
		offset += count_width
	end
	local nulled_count = 0
	if bit32.band(flags, flag_has_nulled) ~= 0 then
		nulled_count = read_count(data, offset)
		offset += count_width
	end
	local removed_count = 0
	if bit32.band(flags, flag_has_removed) ~= 0 then
		removed_count = read_count(data, offset)
		offset += count_width
	end

	if not has_length then
		next_offset = offset + (ids_count + nulled_count + removed_count) * id_width
	end

	return flags, next_offset, offset, first_id, target_id, ids_count, nulled_count, removed_count, nil
end

-- reads one run's header at data[run_offset] within a grouped pair section (wide must match the section's
-- flag_wide): the run flags, the offset of the run's id list, the raw target id, the offset just past the run --
-- only when the run carries inline values; every other run ends where its counted lists do -- and the three
-- flag-gated list counts.
local function read_run_header(
	data: buffer,
	run_offset: number,
	wide: boolean
): (number, number, number, number?, number, number, number)
	local count_width = 2
	local read_count = buffer.readu16
	if wide then
		count_width = 4
		read_count = buffer.readu32
	end
	local run_flags = buffer.readu8(data, run_offset)
	local offset = run_offset + 1
	local target_id = read_id(data, offset)
	offset += id_width

	local run_end: number? = nil
	if bit32.band(run_flags, flag_inline_values) ~= 0 then
		run_end = run_offset + read_count(data, offset)
		offset += count_width
	end

	local ids_count = 0
	if bit32.band(run_flags, flag_has_ids) ~= 0 then
		ids_count = read_count(data, offset)
		offset += count_width
	end
	local nulled_count = 0
	if bit32.band(run_flags, flag_has_nulled) ~= 0 then
		nulled_count = read_count(data, offset)
		offset += count_width
	end
	local removed_count = 0
	if bit32.band(run_flags, flag_has_removed) ~= 0 then
		removed_count = read_count(data, offset)
		offset += count_width
	end

	return run_flags, offset, target_id, run_end, ids_count, nulled_count, removed_count
end

-- reads one chunk section's header at data[section_offset] (the chunk layout above): the flags, the offset
-- just past the section (off the always-present length prefix), the offset of the id list, the raw wire ids
-- naming the section -- the component, or the relation with the target as the fifth return for pair sections --
-- and the two flag-gated list counts. chunk counts are always u16 (the budget is capped below 2^16, so
-- nothing widens).
local function read_chunk_section_header(
	data: buffer,
	section_offset: number
): (number, number, number, number, number?, number, number)
	local flags = buffer.readu8(data, section_offset)
	local next_offset = section_offset + buffer.readu16(data, section_offset + 1)
	local offset = section_offset + 3
	local first_id = read_id(data, offset)
	offset += id_width
	local target_id: number? = nil
	if bit32.band(flags, flag_pair) ~= 0 then
		target_id = read_id(data, offset)
		offset += id_width
	end
	local ids_count = 0
	if bit32.band(flags, flag_has_ids) ~= 0 then
		ids_count = buffer.readu16(data, offset)
		offset += 2
	end
	local nulled_count = 0
	if bit32.band(flags, flag_has_nulled) ~= 0 then
		nulled_count = buffer.readu16(data, offset)
		offset += 2
	end
	return flags, next_offset, offset, first_id, target_id, ids_count, nulled_count
end

-- sizing half of a serdes registration, shared by both finalizers' sizing passes: encodes each value once,
-- appending the encoded buffers to the caller's stash for the write pass to copy -- so there is no size call
-- and no second serialization -- and returns the values' summed wire size (2 + len behind each u16 prefix, or
-- exactly the static size with no prefix) plus the advanced stash count. a length the prefix can't carry, or
-- one disagreeing with a static size, would corrupt the packet, so both error here instead.
local function encode_buffer_values(
	component: any,
	encode: (value: any) -> buffer,
	static: number?,
	values: { any },
	stash: { buffer },
	stash_count: number
): (number, number)
	local values_size = 0
	for _, value in values do
		local encoded = encode(value)
		local length = buffer.len(encoded)
		if static ~= nil then
			if length ~= static then
				fail(
					`serdes hooks with a static size must encode exactly that size! ({id_to_string(component)} encoded {length} bytes, size is {static})`
				)
			end
			values_size += length
		else
			if length > narrow_limit then
				fail(
					`serdes values must encode to fewer than 2^16 bytes! ({id_to_string(component)} encoded {length} bytes)`
				)
			end
			values_size += 2 + length
		end
		stash_count += 1
		stash[stash_count] = encoded
	end
	return values_size, stash_count
end

-- write half of a serdes registration: copies `count` stashed encoded buffers into the section behind their
-- u16 prefixes (none when the sizing pass ran against a static size), returning the advanced offset and stash
-- cursor.
local function write_buffer_values(
	data: buffer,
	offset: number,
	prefixed: boolean,
	count: number,
	stash: { buffer },
	cursor: number
): (number, number)
	for _ = 1, count do
		cursor += 1
		local encoded = stash[cursor]
		local length = buffer.len(encoded)
		if prefixed then
			buffer.writeu16(data, offset, length)
			offset += 2
		end
		buffer.copy(data, offset, encoded)
		offset += length
	end
	return offset, cursor
end

-- one target's lists within a pair draft. targets are carried gen-qualified so two same-frame tenants of one
-- dense id land in separate runs server-side; the encoder truncates them to their dense halves on the wire
-- like every other section id. serdes and values_size are the run's slice of the measure plan (see
-- measure_section below), stashed by the sizing pass and consumed by the write pass.
export type SectionRun = {
	target: number,
	ids: { number }?,
	values: { any }?,
	nulled: { number }?,
	removed: { number }?,
	serdes: Serdes?,
	values_size: number?,
}

-- the accumulation shape the server's packet passes build (see server.luau, which also owns the pooling of
-- drafts, runs, and their lists) and measure_section / write_section encode into one section of a packet
-- buffer. exactly one of component / relation is set: an unpaired draft carries its lists directly, while a
-- pair draft groups every cell of one relation into per-target runs (run_of keys them by the gen-qualified
-- target the rows carry). the plan fields (size through encoded) are stashed by measure_section and consumed
-- by write_section, so a draft must always be measured before it is written; the pools clear them with the
-- rest of the draft on release. the unreliable pass builds the same shape for finalize_chunks, whose pair
-- drafts carry their single gen-qualified target directly instead of runs (chunk pair sections are always
-- single-target); the packet finalizers never read target.
export type SectionDraft = {
	component: number?,
	relation: number?,
	target: number?,
	runs: { SectionRun }?,
	run_of: { [number]: SectionRun }?,
	ids: { number }?,
	values: { any }?,
	nulled: { number }?,
	removed: { number }?,
	size: number?,
	flags: number?,
	wide: boolean?,
	hookless: number?,
	serdes: Serdes?,
	encoded: { buffer }?,
}

-- sizing half of the grouped layout (see measure_section below): resolves each run's serdes hooks for its
-- concrete pair and computes the section's total wire size. fixed bytes sum directly, count fields only tally --
-- they all widen together once anything would overflow u16. the plan stashes on the draft and its runs for
-- write_grouped_section: each run's resolved hooks and (inline runs) its values' summed wire size, so the
-- write pass can prefix each run's length without a second resolve or sizing sweep; inline runs also stash
-- their encoded buffers on the draft, appended flat in run order for the write pass to copy, so nothing
-- serializes twice.
local function measure_grouped_section(draft: SectionDraft, resolve_serdes: ResolveSerdes): number
	local relation = draft.relation :: number
	local runs = draft.runs :: { SectionRun }
	local run_count = #runs

	local size = 1 + id_width -- section flags + relation
	local gated_counts = 0
	local inline_runs = 0
	local hookless_runs = 0
	local encoded_values: { buffer }? = nil
	local encoded_count = 0
	local wide = run_count > narrow_limit
	for _, run in runs do
		size += 1 + id_width -- run flags + target
		local run_ids = run.ids
		local run_nulled = run.nulled
		local run_removed = run.removed
		local ids_count = if run_ids then #run_ids else 0
		local nulled_count = if run_nulled then #run_nulled else 0
		local removed_count = if run_removed then #run_removed else 0
		if ids_count > narrow_limit or nulled_count > narrow_limit or removed_count > narrow_limit then
			wide = true
		end
		local serdes: Serdes? = nil
		if ids_count > 0 then
			gated_counts += 1
			local pair_id = pair(relation, run.target)
			serdes = resolve_serdes(pair_id, relation)
			if serdes then
				inline_runs += 1
				local stash: { buffer } = encoded_values or {}
				encoded_values = stash
				local values_size
				values_size, encoded_count = encode_buffer_values(
					pair_id,
					serdes.encode,
					serdes.size,
					run.values :: { any },
					stash,
					encoded_count
				)
				size += values_size
				run.values_size = values_size
			else
				hookless_runs += 1
			end
		end
		run.serdes = serdes
		if nulled_count > 0 then
			gated_counts += 1
		end
		if removed_count > 0 then
			gated_counts += 1
		end
		size += (ids_count + nulled_count + removed_count) * id_width
	end

	-- the uN fields: section length, run count, the gated list counts, and one run length per inline run
	local count_fields = 2 + gated_counts + inline_runs
	if size + count_fields * 2 > narrow_limit then
		wide = true
	end
	size += count_fields * (if wide then 4 else 2)

	local flags = flag_pair + flag_runs
	if hookless_runs > 0 then
		flags += flag_side_values
	end
	if wide then
		flags += flag_wide
	end

	draft.size = size
	draft.flags = flags
	draft.wide = wide
	draft.hookless = hookless_runs
	draft.encoded = encoded_values
	return size
end

-- write half of the grouped layout (see write_section below): encodes the measured draft at
-- data[section_offset] -- the relation once, then one run per target -- off the plan measure_grouped_section
-- stashed. hookless runs' values concatenate into the returned side array in run order -- a lone hookless
-- run's array escapes by reference, so the caller must compare against the return before pooling any list.
local function write_grouped_section(data: buffer, section_offset: number, draft: SectionDraft): (number, { any }?)
	local relation = draft.relation :: number
	local runs = draft.runs :: { SectionRun }
	local size = draft.size :: number
	local hookless_runs = draft.hookless :: number
	local encoded_values = draft.encoded
	local count_width = 2
	local write_count = buffer.writeu16
	if draft.wide then
		count_width = 4
		write_count = buffer.writeu32
	end

	buffer.writeu8(data, section_offset, draft.flags :: number)
	write_count(data, section_offset + 1, size)
	local offset = section_offset + 1 + count_width
	write_id(data, offset, relation)
	offset += id_width
	write_count(data, offset, #runs)
	offset += count_width

	local side: { any }? = nil
	local encoded_cursor = 0
	for _, run in runs do
		local run_ids = run.ids
		local run_values = run.values
		local run_nulled = run.nulled
		local run_removed = run.removed
		local ids_count = if run_ids then #run_ids else 0
		local nulled_count = if run_nulled then #run_nulled else 0
		local removed_count = if run_removed then #run_removed else 0

		local serdes = run.serdes

		local run_flags = 0
		local run_gated = 0
		if ids_count > 0 then
			run_flags = flag_has_ids
			run_gated = 1
		end
		if nulled_count > 0 then
			run_flags += flag_has_nulled
			run_gated += 1
		end
		if removed_count > 0 then
			run_flags += flag_has_removed
			run_gated += 1
		end
		if serdes then
			run_flags += flag_inline_values
		end

		buffer.writeu8(data, offset, run_flags)
		offset += 1
		write_id(data, offset, run.target)
		offset += id_width
		if serdes then
			local values_size = run.values_size :: number
			local run_size = 1
				+ id_width
				+ count_width * (1 + run_gated)
				+ (ids_count + nulled_count + removed_count) * id_width
				+ values_size
			write_count(data, offset, run_size)
			offset += count_width
		end
		if ids_count > 0 then
			write_count(data, offset, ids_count)
			offset += count_width
		end
		if nulled_count > 0 then
			write_count(data, offset, nulled_count)
			offset += count_width
		end
		if removed_count > 0 then
			write_count(data, offset, removed_count)
			offset += count_width
		end

		if run_ids then
			for _, id in run_ids do
				write_id(data, offset, id)
				offset += id_width
			end
		end
		if serdes then
			offset, encoded_cursor = write_buffer_values(
				data,
				offset,
				serdes.size == nil,
				ids_count,
				encoded_values :: { buffer },
				encoded_cursor
			)
		elseif ids_count > 0 then
			-- hookless: the values join the section's single side array; a lone hookless run's array escapes whole by
			-- reference
			if hookless_runs == 1 then
				side = run_values
			else
				local merged: { any } = side or {}
				side = merged
				table.move(run_values :: { any }, 1, ids_count, #merged + 1, merged)
			end
		end
		if run_nulled then
			for _, id in run_nulled do
				write_id(data, offset, id)
				offset += id_width
			end
		end
		if run_removed then
			for _, id in run_removed do
				write_id(data, offset, id)
				offset += id_width
			end
		end
	end

	return offset, side
end

-- sizing half of the plain layout (see measure_section below): resolves the section's serdes hooks and
-- computes its total wire size -- flags u8 + one uN count per present list, all widening to u32 together when
-- any would overflow u16, with the length prefix (uN, widening with the rest) riding only alongside inline
-- values; every other section's size follows from its counts (see the layout). the plan (the final flags,
-- wide-ness, resolved hooks, and encode stash) lands on the draft for write_plain_section. a pair draft with
-- a single run collapses into this layout, which is smaller than the grouped one until a second target shares
-- the section.
local function measure_plain_section(draft: SectionDraft, resolve_serdes: ResolveSerdes): number
	local relation = draft.relation
	local target: number? = nil

	local ids = draft.ids
	local values = draft.values
	local nulled = draft.nulled
	local removed = draft.removed
	local runs = draft.runs
	if runs ~= nil then
		local run = runs[1]
		target = run.target
		ids = run.ids
		values = run.values
		nulled = run.nulled
		removed = run.removed
	end

	local ids_count = if ids then #ids else 0
	local nulled_count = if nulled then #nulled else 0
	local removed_count = if removed then #removed else 0

	local serdes_key: any = if relation ~= nil then pair(relation :: number, target :: number) else draft.component
	local serdes = if values then resolve_serdes(serdes_key, relation) else nil

	local flags = 0
	local list_count = 0
	if ids_count > 0 then
		flags = flag_has_ids
		list_count = 1
	end
	if nulled_count > 0 then
		flags += flag_has_nulled
		list_count += 1
	end
	if removed_count > 0 then
		flags += flag_has_removed
		list_count += 1
	end

	local size = 1 + list_count * 2 + (ids_count + nulled_count + removed_count) * id_width
	if relation ~= nil then
		flags += flag_pair
		size += id_width * 2
	else
		size += id_width
	end
	local encoded_values: { buffer }? = nil
	if serdes then
		flags += flag_inline_values
		size += 2
		local stash = table.create(ids_count) :: { buffer }
		encoded_values = stash
		local values_size = encode_buffer_values(serdes_key, serdes.encode, serdes.size, values :: { any }, stash, 0)
		size += values_size
	end
	-- only an encoded length can overflow: with no prefix, counts alone decide the width however many bytes the
	-- id lists span
	local wide = ids_count > narrow_limit
		or nulled_count > narrow_limit
		or removed_count > narrow_limit
		or (serdes ~= nil and size > narrow_limit)
	if wide then
		flags += flag_wide
		size += list_count * 2
		if serdes then
			size += 2
		end
	end

	draft.size = size
	draft.flags = flags
	draft.wide = wide
	draft.serdes = serdes
	draft.encoded = encoded_values
	return size
end

-- write half of the plain layout (see write_section below): encodes the measured draft at
-- data[section_offset] off the plan measure_plain_section stashed, returning the offset just past the section
-- and (hookless sections) the values array escaping into the packet's side array, index-aligned with the
-- encoded ids.
local function write_plain_section(data: buffer, section_offset: number, draft: SectionDraft): (number, { any }?)
	local relation = draft.relation
	local target: number? = nil

	local ids = draft.ids
	local values = draft.values
	local nulled = draft.nulled
	local removed = draft.removed
	local runs = draft.runs
	if runs ~= nil then
		local run = runs[1]
		target = run.target
		ids = run.ids
		values = run.values
		nulled = run.nulled
		removed = run.removed
	end

	local ids_count = if ids then #ids else 0
	local nulled_count = if nulled then #nulled else 0
	local removed_count = if removed then #removed else 0

	local serdes = draft.serdes
	local count_width = 2
	local write_count = buffer.writeu16
	if draft.wide then
		count_width = 4
		write_count = buffer.writeu32
	end

	buffer.writeu8(data, section_offset, draft.flags :: number)
	local offset = section_offset + 1
	if serdes then
		write_count(data, offset, draft.size :: number)
		offset += count_width
	end
	if relation ~= nil then
		write_id(data, offset, relation)
		write_id(data, offset + id_width, target :: number)
		offset += id_width * 2
	else
		write_id(data, offset, draft.component :: number)
		offset += id_width
	end
	if ids_count > 0 then
		write_count(data, offset, ids_count)
		offset += count_width
	end
	if nulled_count > 0 then
		write_count(data, offset, nulled_count)
		offset += count_width
	end
	if removed_count > 0 then
		write_count(data, offset, removed_count)
		offset += count_width
	end

	if ids then
		for _, id in ids do
			write_id(data, offset, id)
			offset += id_width
		end
	end
	if serdes then
		offset = write_buffer_values(data, offset, serdes.size == nil, ids_count, draft.encoded :: { buffer }, 0)
	end
	if nulled then
		for _, id in nulled do
			write_id(data, offset, id)
			offset += id_width
		end
	end
	if removed then
		for _, id in removed do
			write_id(data, offset, id)
			offset += id_width
		end
	end

	return offset, if serdes == nil then values else nil
end

-- the measure/write split: measure_section computes one draft's total wire size -- dispatching a pair draft
-- with several runs to the grouped layout, everything else to the plain one -- and stashes on the draft (and
-- its runs) everything the write pass needs, so nothing is resolved, sized, or encoded twice; write_section
-- then encodes the measured draft at data[offset], returning the offset just past the section and (hookless
-- sections) the values array escaping into the packet's side array. the split lets a caller sum several
-- drafts' sizes into one exactly-sized buffer and lay the sections out back-to-back -- one allocation, and
-- one downstream copy per client, per visibility node rather than per section (see server.luau's
-- finalize_node_sections). either way a section encodes once no matter how many clients share it.
local function measure_section(draft: SectionDraft, resolve_serdes: ResolveSerdes): number
	local runs = draft.runs
	if runs ~= nil and #runs > 1 then
		return measure_grouped_section(draft, resolve_serdes)
	end
	return measure_plain_section(draft, resolve_serdes)
end

local function write_section(data: buffer, offset: number, draft: SectionDraft): (number, { any }?)
	local runs = draft.runs
	if runs ~= nil and #runs > 1 then
		return write_grouped_section(data, offset, draft)
	end
	return write_plain_section(data, offset, draft)
end

-- per-value half of the salvages below: re-encodes one list's values under pcall, enforcing the same contract
-- encode_buffer_values does (a buffer back, a static size matched exactly, the u16 prefix limit respected),
-- and prunes the offenders in place with ids and values compacted in lockstep. limit optionally narrows the
-- prefix limit for dynamically-sized values -- the chunk salvage passes the largest value its budget can pack,
-- so an oversized value prunes here instead of re-throwing the budget error forever on that always-resending
-- channel (static sizes skip it: one oversized static value means all are, and the wholesale strip already
-- covers that). returns the pruned count and the first captured error.
local function prune_failing_values(
	component: any,
	serdes: Serdes,
	ids: { number },
	values: { any },
	limit: number?
): (number, any)
	local encode = serdes.encode
	local static: number? = serdes.size
	local count = #ids
	local kept = 0
	local first_error: any = nil
	for i = 1, count do
		-- result is unknown rather than pcall's inferred buffer: it holds whatever the user hook actually
		-- returned until the check below, and the error strings the checks swap in after
		local ok, result: unknown = pcall(encode, values[i])
		if ok and type(result) ~= "buffer" then
			ok = false
			result = `serdes encode hooks must return a buffer! ({id_to_string(component)} returned a {type(result)})`
		end
		if ok then
			-- cast: ok surviving the buffer check above is what refines result, which the solver can't track
			local length = buffer.len(result :: buffer)
			if static ~= nil then
				if length ~= static then
					ok = false
					result =
						`serdes hooks with a static size must encode exactly that size! ({id_to_string(component)} encoded {length} bytes, size is {static})`
				end
			elseif length > narrow_limit then
				ok = false
				result =
					`serdes values must encode to fewer than 2^16 bytes! ({id_to_string(component)} encoded {length} bytes)`
			elseif limit ~= nil and length > limit then
				ok = false
				result =
					`an unreliable value exceeds the chunk byte budget! ({id_to_string(component)} encoded {length} bytes, limit {limit})`
			end
		end
		if ok then
			kept += 1
			ids[kept] = ids[i]
			values[kept] = values[i]
		elseif first_error == nil then
			first_error = result
		end
	end
	for i = count, kept + 1, -1 do
		ids[i] = nil
		values[i] = nil
	end
	return count - kept, first_error
end

-- the salvage pass behind measure_section_salvaging: every value list the failed measure could have been
-- encoding re-runs through prune_failing_values; hookless lists never encode, so they are skipped. lists are
-- only ever emptied in place -- never nil'd, and runs are never dropped -- so the pooled tables stay on the
-- draft for release_draft to reclaim, and an emptied list encodes as a no-op section (or run) costing a few
-- header bytes on a frame that was otherwise lost entirely. returns the total pruned count and the first
-- captured error.
local function salvage_section_values(draft: SectionDraft, resolve_serdes: ResolveSerdes): (number, any)
	local relation = draft.relation
	local runs = draft.runs
	if runs ~= nil then
		local pruned = 0
		local first_error: any = nil
		for _, run in runs do
			local ids = run.ids
			if ids == nil or #ids == 0 then
				continue
			end
			local pair_id = pair(relation :: number, run.target)
			local serdes = resolve_serdes(pair_id, relation)
			if serdes == nil then
				continue
			end
			local run_pruned, run_error = prune_failing_values(pair_id, serdes, ids, run.values :: { any })
			pruned += run_pruned
			if first_error == nil then
				first_error = run_error
			end
		end
		return pruned, first_error
	end
	local ids = draft.ids
	if ids == nil or #ids == 0 then
		return 0, nil
	end
	local serdes = resolve_serdes(draft.component, nil)
	if serdes == nil then
		return 0, nil
	end
	return prune_failing_values(draft.component, serdes, ids, draft.values :: { any })
end

-- guarded counterpart to measure_section for the packet passes: user encode hooks run inside measure (via
-- encode_buffer_values), so a hook that throws -- or returns a non-buffer, or violates its size contract --
-- would otherwise unwind out of generate_packets *after* the resolve passes marked the frame's deltas sent,
-- losing the frame silently for every client (and stranding a joiner mid-full_packet, allocated with partial
-- last marks and no packet). instead: measure under one pcall (the happy path's whole cost), salvage on
-- failure -- re-encode per value and prune exactly the offenders -- and re-measure; a hook nondeterministic
-- enough to pass the salvage and then throw again has every value send stripped wholesale (hookless lists
-- included: only a full strip guarantees the final measure runs no user code even if an encode hook mutated
-- the serdes store mid-frame), after which nulled/removed lists are all that encode and never run hooks, so a
-- throw out of the final measure is an internal bug and propagates. returns the measured size plus, on a
-- salvage, the pruned value count and the error to report -- the caller owns the warn.
local function measure_section_salvaging(draft: SectionDraft, resolve_serdes: ResolveSerdes): (number, number, any)
	local ok, size = pcall(measure_section, draft, resolve_serdes)
	if ok then
		return size, 0, nil
	end
	local first_error: any = size
	local pruned, salvage_error = salvage_section_values(draft, resolve_serdes)
	if salvage_error ~= nil then
		first_error = salvage_error
	end
	ok, size = pcall(measure_section, draft, resolve_serdes)
	if ok then
		return size, pruned, first_error
	end
	local runs = draft.runs
	if runs ~= nil then
		for _, run in runs do
			local ids = run.ids
			if ids ~= nil then
				pruned += #ids
				table.clear(ids)
				table.clear(run.values :: { any })
			end
		end
	else
		local ids = draft.ids
		if ids ~= nil then
			pruned += #ids
			table.clear(ids)
			table.clear(draft.values :: { any })
		end
	end
	return measure_section(draft, resolve_serdes), pruned, first_error
end

-- measure + write in one step, for callers encoding a section into its own scratch buffer: the draft's
-- parallel arrays encode into an exactly-sized buffer, with a hookless section's values returned as the
-- second value to travel in the packet's side array. no longer called by the packet passes (they sum measured
-- drafts into shared multi-section buffers), but kept on the module's surface as the single-section entry
-- point.
local function finalize_section(draft: SectionDraft, resolve_serdes: ResolveSerdes): (buffer, { any }?)
	local size = measure_section(draft, resolve_serdes)
	local data = buffer.create(size)
	local _, side = write_section(data, 0, draft)
	return data, side
end

-- the pre-encode pass of finalize_chunks, one draft's values into its stash: enforces the same contract
-- encode_buffer_values does (a buffer back, a static size matched exactly, the u16 prefix limit respected)
-- plus the chunk-specific bound -- limit is the largest value the caller's budget can pack, so anything past
-- it errors here rather than surfacing as a budget error mid-packing. runs under finalize_chunks' per-draft
-- pcall: user hooks run nowhere else, so packing never throws out of a half-written section.
local function encode_chunk_values(
	component: any,
	encode: (value: any) -> buffer,
	static: number?,
	values: { any },
	count: number,
	stash: { buffer },
	limit: number
)
	if static ~= nil and static > limit then
		fail(
			`an unreliable value exceeds the chunk byte budget! ({id_to_string(component)} encodes {static} bytes, limit {limit})`
		)
	end
	for i = 1, count do
		local encoded = encode(values[i])
		local length = buffer.len(encoded)
		if static ~= nil then
			if length ~= static then
				fail(
					`serdes hooks with a static size must encode exactly that size! ({id_to_string(component)} encoded {length} bytes, size is {static})`
				)
			end
		elseif length > narrow_limit then
			fail(
				`serdes values must encode to fewer than 2^16 bytes! ({id_to_string(component)} encoded {length} bytes)`
			)
		elseif length > limit then
			fail(
				`an unreliable value exceeds the chunk byte budget! ({id_to_string(component)} encoded {length} bytes, limit {limit})`
			)
		end
		stash[i] = encoded
	end
end

-- encodes one visibility group's unreliable drafts into chunk buffers of at most `budget` bytes each (the
-- chunk layout above), appended to `chunks`. cells pack greedily in draft order: when the next cell would
-- overflow the open chunk, the chunk closes and a fresh section naming the same component opens the next one,
-- so every chunk stands alone. every value encodes up front through the draft's resolved serdes hooks
-- (required: chunking needs byte-exact sizing) into a per-draft stash the packing loop sizes and copies from,
-- so user code runs only in the pre-encode pass -- which is also the salvage guard, the chunk counterpart to
-- measure_section_salvaging: a draft whose values can't encode -- a throwing hook, a violated size contract,
-- a value no chunk could fit, or missing hooks entirely -- fails its per-draft pcall before any of it packs,
-- has the offenders pruned via prune_failing_values and the survivors re-encoded, and packs whatever remains
-- (nothing, when the hook is nondeterministic enough to fail the re-encode too). returns the total pruned
-- value count plus the first captured error and the cell id it names -- the caller owns the warn, and the
-- dropped values simply skip this call's chunks (the always-replicate cadence re-sends, and may re-fail, them
-- next call). scratch is the caller's staging buffer of at least `budget` bytes; each completed chunk is
-- copied out of it into an exactly-sized buffer, so pooled draft lists never escape.
local function finalize_chunks(
	frame: number,
	-- keyed by cell id; the keys are ignored here (the server's accumulators key by their branded id types)
	drafts: { [any]: SectionDraft },
	budget: number,
	resolve_serdes: ResolveSerdes,
	scratch: buffer,
	chunks: { buffer }
): (number, any, number?)
	local chunks_count = #chunks
	-- the write offset into scratch; 0 means no chunk is open
	local offset = 0

	-- the aggregated salvage report: values dropped across every salvaged draft, plus the first captured
	-- error and the cell id it names
	local pruned = 0
	local salvage_error: any = nil
	local salvage_id: number? = nil

	-- one stash shared by every draft of the call (a draft's encodes are dead once it packs, and clearing
	-- keeps the array's capacity), so per-draft cost stays one pcall and a clear rather than an allocation
	local shared_stash: { buffer }? = nil

	for _, draft in drafts do
		local relation = draft.relation
		local ids = draft.ids
		local values = draft.values
		local nulled = draft.nulled
		local ids_count = if ids then #ids else 0
		local nulled_count = if nulled then #nulled else 0

		-- bytes every section of this draft pays, continuations included: flags + length + the naming ids
		local header_bytes = 3 + id_width
		if relation ~= nil then
			header_bytes += id_width
		end

		local serdes_key: any = if relation ~= nil
			then pair(relation :: number, draft.target :: number)
			else draft.component
		local static: number? = nil
		local stash: { buffer }? = nil
		if ids_count > 0 then
			-- the largest value the budget can pack behind an empty chunk's header and count fields
			local limit = budget - chunk_header_width - header_bytes - 4 - id_width
			if limit > narrow_limit then
				limit = narrow_limit
			end
			local serdes = resolve_serdes(serdes_key, relation)
			if serdes == nil then
				-- missing hooks can't size the values, so none can ship: contained like a throwing hook below
				-- rather than erroring the whole call -- the values drop, and the nulled ids still pack
				pruned += ids_count
				if salvage_error == nil then
					salvage_error =
						`unreliable values cannot be serialized without serdes hooks! ({id_to_string(serdes_key)})`
					salvage_id = serdes_key
				end
				ids_count = 0
			else
				static = serdes.size
				local encoded: { buffer }
				if shared_stash == nil then
					encoded = table.create(ids_count) :: { buffer }
					shared_stash = encoded
				else
					encoded = shared_stash :: { buffer }
					table.clear(encoded)
				end
				-- cast: encode_chunk_values returns nothing, so the solver rejects binding pcall's error slot
				local ok, encode_error = pcall(
					encode_chunk_values :: any,
					serdes_key,
					serdes.encode,
					static,
					values :: { any },
					ids_count,
					encoded,
					limit
				)
				if not ok then
					-- the per-draft salvage, mirroring measure_section_salvaging: re-encode the values one at
					-- a time, prune exactly the offenders in place, and re-run the pre-encode over the
					-- survivors; nothing has packed yet, so there is nothing to unwind
					local first_error: any = encode_error
					local draft_pruned, prune_error =
						prune_failing_values(serdes_key, serdes, ids :: { number }, values :: { any }, limit)
					if prune_error ~= nil then
						first_error = prune_error
					end
					ids_count = #(ids :: { number })
					table.clear(encoded)
					ok, encode_error = pcall(
						encode_chunk_values :: any,
						serdes_key,
						serdes.encode,
						static,
						values :: { any },
						ids_count,
						encoded,
						limit
					)
					if not ok then
						-- a hook nondeterministic enough to pass the salvage and then fail again (or a static
						-- size the budget can't fit, which the prune can't reach) has the draft's values
						-- stripped wholesale; the nulled ids still pack below
						draft_pruned += ids_count
						ids_count = 0
					end
					pruned += draft_pruned
					if salvage_error == nil then
						salvage_error = first_error
						salvage_id = serdes_key
					end
				end
				stash = encoded
			end
		end

		-- packing: pure buffer math and stash copies -- no user code runs past here, so a throw below is an
		-- internal bug and propagates
		local id_index = 1
		local nulled_index = 1
		while id_index <= ids_count or nulled_index <= nulled_count do
			if offset == 0 then
				buffer.writeu8(scratch, 0, wire_version + chunk_version_flag)
				buffer.writeu32(scratch, version_width, frame)
				offset = chunk_header_width
			end

			local remaining = budget - offset - header_bytes

			-- fit pass: how many value cells the open chunk takes, the u16 ids_count field charged with the first
			local take_ids = 0
			local values_size = 0
			if id_index <= ids_count and remaining >= 2 then
				local avail = remaining - 2
				if static ~= nil then
					local most = avail // (id_width + static)
					local left = ids_count - id_index + 1
					take_ids = if most < left then most else left
					values_size = take_ids * static
				else
					local stashed = stash :: { buffer }
					while id_index + take_ids <= ids_count do
						local value_size = 2 + buffer.len(stashed[id_index + take_ids])
						if values_size + take_ids * id_width + id_width + value_size > avail then
							break
						end
						values_size += value_size
						take_ids += 1
					end
				end
				if take_ids > 0 then
					remaining = avail - take_ids * id_width - values_size
				end
			end

			-- nulled ids fill only once the value cells are exhausted, their u16 count field charged with the first
			local take_nulled = 0
			if id_index + take_ids > ids_count and nulled_index <= nulled_count and remaining >= 2 + id_width then
				local most = (remaining - 2) // id_width
				local left = nulled_count - nulled_index + 1
				take_nulled = if most < left then most else left
			end

			if take_ids == 0 and take_nulled == 0 then
				if offset == chunk_header_width then
					-- an empty chunk that fits nothing: unreachable, since every value is bounded against the same budget
					-- in the pre-encode pass above (an oversized one is pruned there, never packed) and min_chunk_bytes
					-- floors the budget at one cell of any section. kept as an invariant so a layout change can't turn
					-- it into a silent infinite loop, and worded for what would actually be wrong if it ever fired.
					fail(
						`an unreliable section does not fit an empty chunk! ({id_to_string(serdes_key)}, budget {budget})`
					)
				end
				-- the open chunk is full: close it and retry against a fresh one
				local chunk = buffer.create(offset)
				buffer.copy(chunk, 0, scratch, 0, offset)
				chunks_count += 1
				chunks[chunks_count] = chunk
				offset = 0
				continue
			end

			local flags = 0
			local section_size = header_bytes
			if take_ids > 0 then
				flags = flag_has_ids
				section_size += 2 + take_ids * id_width + values_size
			end
			if take_nulled > 0 then
				flags += flag_has_nulled
				section_size += 2 + take_nulled * id_width
			end
			if relation ~= nil then
				flags += flag_pair
			end

			buffer.writeu8(scratch, offset, flags)
			buffer.writeu16(scratch, offset + 1, section_size)
			offset += 3
			if relation ~= nil then
				write_id(scratch, offset, relation)
				write_id(scratch, offset + id_width, draft.target :: number)
				offset += id_width * 2
			else
				write_id(scratch, offset, draft.component :: number)
				offset += id_width
			end
			if take_ids > 0 then
				buffer.writeu16(scratch, offset, take_ids)
				offset += 2
			end
			if take_nulled > 0 then
				buffer.writeu16(scratch, offset, take_nulled)
				offset += 2
			end

			if take_ids > 0 then
				local id_list = ids :: { number }
				for k = id_index, id_index + take_ids - 1 do
					write_id(scratch, offset, id_list[k])
					offset += id_width
				end
				local stashed = stash :: { buffer }
				if static ~= nil then
					-- static sizes are pre-verified, so the copies advance arithmetically with no prefix
					for k = id_index, id_index + take_ids - 1 do
						buffer.copy(scratch, offset, stashed[k])
						offset += static
					end
				else
					for k = id_index, id_index + take_ids - 1 do
						local encoded = stashed[k]
						local length = buffer.len(encoded)
						buffer.writeu16(scratch, offset, length)
						buffer.copy(scratch, offset + 2, encoded)
						offset += 2 + length
					end
				end
				id_index += take_ids
			end
			if take_nulled > 0 then
				local nulled_list = nulled :: { number }
				for k = nulled_index, nulled_index + take_nulled - 1 do
					write_id(scratch, offset, nulled_list[k])
					offset += id_width
				end
				nulled_index += take_nulled
			end
		end
	end

	if offset ~= 0 then
		local chunk = buffer.create(offset)
		buffer.copy(chunk, 0, scratch, 0, offset)
		chunks_count += 1
		chunks[chunks_count] = chunk
	end

	return pruned, salvage_error, salvage_id
end

-- stamps one client's flat packet buffer from the shared scratch sections (the packet layout above).
-- sections_size must be the summed byte length of section_buffers, so the buffer allocates exactly once.
-- names carries the shared-name announcements as a (gen-qualified id -> name) map, with an empty-string name
-- encoding a retraction; values carries the hookless sections' value arrays in section order (see the Packet
-- type in types.luau).
local function assemble_packet(
	frame: number,
	unreplicated: { number }?,
	replicated: { number }?,
	names: { [number]: string }?,
	section_buffers: { buffer }?,
	sections_size: number,
	values: { { any } }?
): types.Packet
	local unreplicated_count = if unreplicated then #unreplicated else 0
	local replicated_count = if replicated then #replicated else 0
	local names_count = 0
	local names_size = 0
	if names then
		for _, name in names do
			names_count += 1
			names_size += gen_id_width + 1 + #name
		end
	end

	-- packet frame u32 + flags u8 + one u16 count per present list, all counts widening to u32 together when
	-- any would overflow u16
	local flags = 0
	local list_count = 0
	if unreplicated_count > 0 then
		flags = packet_flag_unreplicated
		list_count = 1
	end
	if replicated_count > 0 then
		flags += packet_flag_replicated
		list_count += 1
	end
	if names_count > 0 then
		flags += packet_flag_names
		list_count += 1
	end
	local count_width = 2
	local write_count = buffer.writeu16
	if unreplicated_count > narrow_limit or replicated_count > narrow_limit or names_count > narrow_limit then
		flags += packet_flag_wide
		count_width = 4
		write_count = buffer.writeu32
	end

	local data = buffer.create(
		version_width
			+ packet_frame_width
			+ 1
			+ list_count * count_width
			+ unreplicated_count * id_width
			+ replicated_count * gen_id_width
			+ names_size
			+ sections_size
	)
	buffer.writeu8(data, 0, wire_version)
	buffer.writeu32(data, version_width, frame)
	buffer.writeu8(data, version_width + packet_frame_width, flags)
	local offset = version_width + packet_frame_width + 1
	if unreplicated_count > 0 then
		write_count(data, offset, unreplicated_count)
		offset += count_width
	end
	if replicated_count > 0 then
		write_count(data, offset, replicated_count)
		offset += count_width
	end
	if names_count > 0 then
		write_count(data, offset, names_count)
		offset += count_width
	end
	if unreplicated then
		for _, entity in unreplicated do
			write_id(data, offset, entity)
			offset += id_width
		end
	end
	if replicated then
		for _, entity in replicated do
			write_gen_id(data, offset, entity)
			offset += gen_id_width
		end
	end
	if names_count > 0 then
		for id, name in names :: { [number]: string } do
			write_gen_id(data, offset, id)
			offset += gen_id_width
			buffer.writeu8(data, offset, #name)
			offset += 1
			buffer.writestring(data, offset, name)
			offset += #name
		end
	end
	if section_buffers then
		for _, section in section_buffers do
			buffer.copy(data, offset, section)
			offset += buffer.len(section)
		end
	end
	return {
		data = data,
		values = values,
	}
end

-- the record views decode_section / decode_packet parse into, for the verification suite and diagnostics --
-- never the reconcile path, which stream-applies without materializing records. every entity and component id
-- is a raw wire id, never mapped through a client's mapping table: dense for everything a section carries (and
-- the packet's unreplicated list), gen-qualified only in the replicated list and the names view; component is
-- the packed pair id for pair sections. list fields are nil when their list is absent from the wire.
export type DecodedSection = {
	component: number,
	relation: number?,
	target: number?,
	ids: { number }?,
	values: { any }?,
	nulled: { number }?,
	removed: { number }?,
}

-- one component's view merged across a packet's sections (the same component may span several sections of one
-- packet when its cells resolve to different visibility masks), each section's lists appended in packet
-- order.
export type DecodedComponent = {
	relation: number?,
	target: number?,
	ids: { number }?,
	values: { any }?,
	nulled: { number }?,
	removed: { number }?,
}

export type DecodedPacket = {
	data: buffer,
	values: { { any } }?,
	frame: number,
	replicated: { number },
	unreplicated: { number },
	names: { [number]: string },
	sections: { DecodedSection },
	components: { [number]: DecodedComponent },
}

-- decodes `count` serdes-encoded values at data[offset], returning them and the offset just past; shared by
-- the record-view decoders below. each value decodes from a fresh value-sized buffer, its length read off the
-- u16 prefix unless the registration declares a static size (see the Serdes type in types.luau).
local function decode_values(data: buffer, offset: number, serdes: Serdes, count: number): ({ any }, number)
	local decoded: { any } = table.create(count)
	local decode = serdes.decode
	local static: number? = serdes.size
	for i = 1, count do
		local length: number
		if static ~= nil then
			length = static
		else
			length = buffer.readu16(data, offset)
			offset += 2
		end
		local encoded = buffer.create(length)
		buffer.copy(encoded, 0, data, offset, length)
		offset += length
		decoded[i] = decode(encoded)
	end
	return decoded, offset
end

-- decodes one section at data[section_offset] into DecodedSection records -- a list, because a grouped pair
-- section decodes into one record per run -- returning them, the offset just past the section, and the
-- advanced side-array cursor. a hookless single-list section's values field is the very table the packet's
-- side array carries (shared by reference across clients whose masks matched at build time), so it must never
-- be mutated; a grouped section's hookless runs get fresh slices of their shared entry instead. decoding
-- inline values without resolvable serdes hooks errors -- their size is unknowable without the hooks.
local function decode_section(
	data: buffer,
	section_offset: number,
	packet_values: { { any } }?,
	values_index: number,
	resolve_serdes: ResolveSerdes?
): ({ DecodedSection }, number, number)
	local flags, next_offset, offset, first_id, target_id, ids_count, nulled_count, removed_count, run_count =
		read_section_header(data, section_offset)

	local function read_ids(count: number): { number }?
		if count == 0 then
			return nil
		end
		local list = table.create(count) :: { number }
		for i = 1, count do
			list[i] = read_id(data, offset)
			offset += id_width
		end
		return list
	end

	if run_count ~= nil then
		local relation = first_id
		local side: { any }? = nil
		local side_cursor = 0
		if bit32.band(flags, flag_side_values) ~= 0 then
			values_index += 1
			side = (packet_values :: { { any } })[values_index]
		end
		local wide = bit32.band(flags, flag_wide) ~= 0

		local sections = table.create(run_count) :: { DecodedSection }
		for r = 1, run_count do
			local run_flags, list_offset, run_target, _, run_ids_count, run_nulled_count, run_removed_count =
				read_run_header(data, offset, wide)
			offset = list_offset

			local component = pair(relation, run_target)
			local ids = read_ids(run_ids_count)
			local values: { any }? = nil
			if run_ids_count > 0 then
				if bit32.band(run_flags, flag_inline_values) ~= 0 then
					local serdes = if resolve_serdes then resolve_serdes(component, relation) else nil
					if serdes == nil then
						fail(`decode_section: no serdes hooks to decode the inline values of {id_to_string(component)}`)
					end
					-- cast: fail never returns, but the solver doesn't treat user functions as diverging
					values, offset = decode_values(data, offset, serdes :: Serdes, run_ids_count)
				else
					local sliced: { any } = table.create(run_ids_count)
					table.move(side :: { any }, side_cursor + 1, side_cursor + run_ids_count, 1, sliced)
					side_cursor += run_ids_count
					values = sliced
				end
			end
			local nulled = read_ids(run_nulled_count)
			local removed = read_ids(run_removed_count)

			sections[r] = {
				component = component,
				relation = relation,
				target = run_target,
				ids = ids,
				values = values,
				nulled = nulled,
				removed = removed,
			}
		end
		return sections, next_offset, values_index
	end

	local component = first_id
	local relation: number? = nil
	if target_id ~= nil then
		relation = first_id
		component = pair(first_id, target_id)
	end

	local ids = read_ids(ids_count)
	local values: { any }? = nil
	if ids_count > 0 then
		if bit32.band(flags, flag_inline_values) ~= 0 then
			local serdes = if resolve_serdes then resolve_serdes(component, relation) else nil
			if serdes == nil then
				fail(`decode_section: no serdes hooks to decode the inline values of {id_to_string(component)}`)
			end
			-- cast: fail never returns, but the solver doesn't treat user functions as diverging
			values, offset = decode_values(data, offset, serdes :: Serdes, ids_count)
		else
			values_index += 1
			values = (packet_values :: { { any } })[values_index]
		end
	end
	local nulled = read_ids(nulled_count)
	local removed = read_ids(removed_count)

	local section = {
		component = component,
		relation = relation,
		target = target_id,
		ids = ids,
		values = values,
		nulled = nulled,
		removed = removed,
	}
	return { section }, next_offset, values_index
end

local merged_fields = { "ids", "values", "nulled", "removed" }

-- parses a packet's flat wire buffer into the DecodedPacket record view: the packet frame, the entity
-- create/delete lists, the shared-name announcements (retractions decode as empty-string entries), every
-- decoded section in packet order, and a per-component view merged by appending each section's lists in
-- packet order. the raw data/values fields ride along so the record still reconciles when handed to a
-- client's reconcile_packet.
local function decode_packet(packet: types.Packet, resolve_serdes: ResolveSerdes?): DecodedPacket
	local data = packet.data
	local packet_values = packet.values
	check_version(data)

	local packet_frame, offset, unreplicated_count, replicated_count, names_count = read_packet_header(data)

	local unreplicated = table.create(unreplicated_count) :: { number }
	for i = 1, unreplicated_count do
		unreplicated[i] = read_id(data, offset)
		offset += id_width
	end
	local replicated = table.create(replicated_count) :: { number }
	for i = 1, replicated_count do
		replicated[i] = read_gen_id(data, offset)
		offset += gen_id_width
	end

	local names = {} :: { [number]: string }
	for _ = 1, names_count do
		local id, name, next_offset = read_name(data, offset)
		names[id] = name
		offset = next_offset
	end

	local sections = {} :: { DecodedSection }
	local values_index = 0
	local data_size = buffer.len(data)
	while offset < data_size do
		local decoded, section_end, next_values_index =
			decode_section(data, offset, packet_values, values_index, resolve_serdes)
		offset = section_end
		values_index = next_values_index
		table.move(decoded, 1, #decoded, #sections + 1, sections)
	end

	local components = {} :: { [number]: DecodedComponent }
	for _, decoded in sections do
		local merged = components[decoded.component]
		if merged == nil then
			merged = {
				relation = decoded.relation,
				target = decoded.target,
			} :: DecodedComponent
			components[decoded.component] = merged
		end
		local decoded_any = decoded :: any
		local merged_any = merged :: any
		for _, field in merged_fields do
			local source = decoded_any[field]
			if source ~= nil then
				local list = merged_any[field]
				if list == nil then
					list = {}
					merged_any[field] = list
				end
				table.move(source, 1, #source, #list + 1, list)
			end
		end
	end

	return {
		data = data,
		values = packet_values,
		frame = packet_frame,
		replicated = replicated,
		unreplicated = unreplicated,
		names = names,
		sections = sections,
		components = components,
	}
end

export type DecodedChunk = {
	frame: number,
	sections: { DecodedSection },
}

-- parses one unreliable chunk into a record view for the verification suite and diagnostics: the frame
-- counter and every section in chunk order, with raw (dense) wire ids like decode_section's records;
-- component is the packed pair id for pair sections, and removed is always nil (removals never ride chunks).
-- chunk values are always serdes-encoded, so unresolvable hooks error like decode_section's inline case.
local function decode_chunk(chunk: buffer, resolve_serdes: ResolveSerdes?): DecodedChunk
	check_chunk_version(chunk)
	local frame = read_chunk_frame(chunk)

	local sections = {} :: { DecodedSection }
	local sections_count = 0
	local offset = chunk_header_width
	local chunk_size = buffer.len(chunk)
	while offset < chunk_size do
		local _, next_offset, list_offset, first_id, target_id, ids_count, nulled_count =
			read_chunk_section_header(chunk, offset)

		local component = first_id
		local relation: number? = nil
		if target_id ~= nil then
			relation = first_id
			component = pair(first_id, target_id)
		end

		offset = list_offset
		local ids: { number }? = nil
		local values: { any }? = nil
		if ids_count > 0 then
			local list = table.create(ids_count) :: { number }
			for i = 1, ids_count do
				list[i] = read_id(chunk, offset)
				offset += id_width
			end
			ids = list
			local serdes = if resolve_serdes then resolve_serdes(component, relation) else nil
			if serdes == nil then
				fail(`decode_chunk: no serdes hooks to decode the values of {id_to_string(component)}`)
			end
			-- cast: fail never returns, but the solver doesn't treat user functions as diverging
			values, offset = decode_values(chunk, offset, serdes :: Serdes, ids_count)
		end
		local nulled: { number }? = nil
		if nulled_count > 0 then
			local list = table.create(nulled_count) :: { number }
			for i = 1, nulled_count do
				list[i] = read_id(chunk, offset)
				offset += id_width
			end
			nulled = list
		end

		sections_count += 1
		sections[sections_count] = {
			component = component,
			relation = relation,
			target = target_id,
			ids = ids,
			values = values,
			nulled = nulled,
			removed = nil,
		}
		offset = next_offset
	end

	return {
		frame = frame,
		sections = sections,
	}
end

return {
	-- section buffer flag bits
	flag_pair = flag_pair,
	flag_inline_values = flag_inline_values,
	flag_has_ids = flag_has_ids,
	flag_has_nulled = flag_has_nulled,
	flag_has_removed = flag_has_removed,
	flag_wide = flag_wide,
	flag_runs = flag_runs,
	flag_side_values = flag_side_values,

	-- packet buffer flag bits
	packet_flag_unreplicated = packet_flag_unreplicated,
	packet_flag_replicated = packet_flag_replicated,
	packet_flag_wide = packet_flag_wide,
	packet_flag_names = packet_flag_names,

	wire_version = wire_version,
	chunk_version_flag = chunk_version_flag,

	version_width = version_width,
	id_width = id_width,
	gen_id_width = gen_id_width,
	chunk_header_width = chunk_header_width,
	min_chunk_bytes = min_chunk_bytes,
	max_chunk_bytes = max_chunk_bytes,

	write_id = write_id,
	read_id = read_id,
	write_gen_id = write_gen_id,
	read_gen_id = read_gen_id,

	-- packet writers
	measure_section = measure_section,
	measure_section_salvaging = measure_section_salvaging,
	write_section = write_section,
	finalize_section = finalize_section,
	assemble_packet = assemble_packet,
	finalize_chunks = finalize_chunks,

	-- shared header readers
	read_version = read_version,
	check_version = check_version,
	read_packet_frame = read_packet_frame,
	read_packet_header = read_packet_header,
	read_name = read_name,
	read_section_header = read_section_header,
	read_run_header = read_run_header,
	check_chunk_version = check_chunk_version,
	read_chunk_frame = read_chunk_frame,
	read_chunk_section_header = read_chunk_section_header,

	-- record-view decoders (test/debug-facing; reconcile never uses them)
	decode_section = decode_section,
	decode_packet = decode_packet,
	decode_chunk = decode_chunk,
}
