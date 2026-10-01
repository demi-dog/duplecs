--!strict

-- the debug packet inspector behind both halves' describe_packet / describe_chunk: the public wrapper over
-- wire.luau's header readers, which stay internal. one walk serves the server describing what it just
-- generated and a client describing what it received: each half's factory (see INSPECTORS), built from the
-- references that half passes in, supplies the resolver the walk uses -- how a wire id maps to a local entity,
-- how a local entity is named, and the world's serdes store. it is the tree's one allocating packet decoder:
-- the verification suite drives describe_packet / describe_chunk directly with a resolver mapping every wire
-- id to itself, reshaping the descriptions into its own assertion views.
--
-- byte counts never depend on decoding: every size comes from the wire's own length prefixes and counts, so a
-- section whose ids don't resolve, whose hooks are missing on the describing side, or whose decode hook throws
-- still reports exact bytes -- only its values go nil. decode runs under pcall and is checked against the
-- section's own extent, so a throwing hook or a size declared differently on the two sides is contained to
-- the one section's values, without a warning (describing has no side effects). debug-rate code: it
-- allocates freely and never sits on a packet pass.

local jecs = require("../roblox_packages/jecs")

local types = require("./types")
local wire = require("./wire")

-- jecs.pair retyped to the plain-number domain, like wire.luau's
local pair = (jecs.pair :: any) :: (relation: number, target: number) -> number

type World = types.World
type Id = types.Id
type Entity = types.Entity
type Serdes = types.Serdes
type Packet = types.Packet
type EntityDescription = types.EntityDescription
type NameDescription = types.NameDescription
type SectionDescription = types.SectionDescription
type ComponentDescription = types.ComponentDescription
type PacketDescription = types.PacketDescription
type ChunkDescription = types.ChunkDescription

-- the serdes store's resolver (see serdes.luau), keyed by local ids
type ResolveSerdes = (component: any, relation: any) -> Serdes?

local flag_inline_values = wire.flag_inline_values
local flag_side_values = wire.flag_side_values
local flag_wide = wire.flag_wide
local id_width = wire.id_width
local gen_id_width = wire.gen_id_width
local chunk_header_width = wire.chunk_header_width
local read_id = wire.read_id
local read_gen_id = wire.read_gen_id
local check_version = wire.check_version
local read_packet_header = wire.read_packet_header
local read_name = wire.read_name
local read_section_header = wire.read_section_header
local read_run_header = wire.read_run_header
local check_chunk_version = wire.check_chunk_version
local read_chunk_frame = wire.read_chunk_frame
local read_chunk_section_header = wire.read_chunk_section_header
local decode_values = wire.decode_values

-- DESCRIBE

-- what one half knows about its own world, for resolving the wire's ids: entity maps a dense wire id (what
-- sections and the deletion list carry) and gen_entity a gen-qualified one (the creation and names lists) to
-- the local id, nil when nothing local stands for it; name reads a local entity's jecs.Name; resolve_serdes
-- is the world's serdes store.
export type Resolver = {
	entity: (dense_id: number) -> number?,
	gen_entity: (gen_id: number) -> number?,
	name: (entity: number) -> string?,
	resolve_serdes: ResolveSerdes,
}

-- the per-call naming context: the resolver plus the names the described packet itself announces, keyed by
-- dense id, which take precedence over the local world's (they are what the id means as of this packet)
type Context = {
	resolver: Resolver,
	announced: { [number]: string },
}

local function name_of(context: Context, dense_id: number, entity: number?): string?
	local announced = context.announced[dense_id]
	if announced ~= nil then
		return announced
	end
	if entity == nil then
		return nil
	end
	return context.resolver.name(entity)
end

local function read_ids(data: buffer, offset: number, count: number): { number }
	local list = table.create(count) :: { number }
	for i = 1, count do
		list[i] = read_id(data, offset)
		offset += id_width
	end
	return list
end

-- decodes one list's inline values occupying exactly data[offset, region_end), or nil when the hooks throw
-- or disagree with the region (a static size declared differently on the two sides)
local function decode_region(data: buffer, offset: number, region_end: number, serdes: Serdes, count: number): { any }?
	local ok, values, end_offset = pcall(decode_values, data, offset, serdes, count)
	if not ok or end_offset ~= region_end then
		return nil
	end
	return values
end

-- the naming half of a section or run description: component (the packed pair id for pairs), the local id,
-- and the names. returns the local relation for a pair whose halves both resolve, for section_serdes.
local function name_section(
	context: Context,
	section: SectionDescription,
	first_id: number,
	target_id: number?
): number?
	local resolver = context.resolver
	if target_id == nil then
		local entity = resolver.entity(first_id)
		section.component = first_id
		section.entity = entity :: any
		section.name = name_of(context, first_id, entity)
		return nil
	end
	local relation = resolver.entity(first_id)
	local target = resolver.entity(target_id)
	section.component = pair(first_id, target_id)
	section.relation = first_id
	section.target = target_id
	section.relation_name = name_of(context, first_id, relation)
	section.target_name = name_of(context, target_id, target)
	if relation ~= nil and target ~= nil then
		section.entity = pair(relation, target) :: any
		return relation
	end
	return nil
end

-- the serdes hooks a described section's inline values decode with, through the local ids only: an unmapped
-- half means the describing world could not decode them either
local function section_serdes(context: Context, section: SectionDescription, relation: number?): Serdes?
	local entity = section.entity
	if entity == nil then
		return nil
	end
	return context.resolver.resolve_serdes(entity, relation)
end

local function new_section(layout: "plain" | "grouped"): SectionDescription
	return {
		component = 0,
		layout = layout,
		bytes = 0,
		value_bytes = 0,
		ids = {},
		side_values = 0,
	}
end

-- reads one list group (ids, values, nulled, removed) laid out from offset, filling the section's lists and
-- value_bytes. value_end is where the inline values stop (nil for hookless lists, whose values ride side, a
-- slice of the side array starting after side_cursor). relation is name_section's return.
local function read_lists(
	context: Context,
	section: SectionDescription,
	relation: number?,
	data: buffer,
	offset: number,
	ids_count: number,
	nulled_count: number,
	removed_count: number,
	value_end: number?,
	side: { any }?,
	side_cursor: number
)
	section.ids = read_ids(data, offset, ids_count)
	offset += ids_count * id_width
	if value_end ~= nil then
		section.value_bytes = value_end - offset
		if ids_count > 0 then
			local serdes = section_serdes(context, section, relation)
			if serdes ~= nil then
				section.values = decode_region(data, offset, value_end, serdes, ids_count)
			end
		end
		offset = value_end
	elseif ids_count > 0 then
		section.side_values = ids_count
		if side ~= nil then
			local values = table.create(ids_count)
			table.move(side, side_cursor + 1, side_cursor + ids_count, 1, values)
			section.values = values
		end
	end
	if nulled_count > 0 then
		section.nulled = read_ids(data, offset, nulled_count)
		offset += nulled_count * id_width
	end
	if removed_count > 0 then
		section.removed = read_ids(data, offset, removed_count)
	end
end

-- folds one described section (or run) into the per-component rollup, keyed like the section itself
local function roll_up(components: { [number]: ComponentDescription }, section: SectionDescription)
	local entry = components[section.component]
	if entry == nil then
		entry = {
			bytes = 0,
			value_bytes = 0,
			entries = 0,
			side_values = 0,
			name = section.name,
			relation_name = section.relation_name,
			target_name = section.target_name,
		}
		components[section.component] = entry
	end
	entry.bytes += section.bytes
	entry.value_bytes += section.value_bytes
	entry.entries += #section.ids + (if section.nulled then #section.nulled else 0) + (if section.removed
		then #section.removed
		else 0)
	entry.side_values += section.side_values
end

-- describes one packet section at data[section_offset], appending one description (one per run for a grouped
-- section) and returning the offset past it and the advanced side-array cursor. a grouped section's shared
-- framing -- flags, length, relation id, run count -- divides evenly across its runs, the remainder bytes
-- going one each to the earliest runs, so the runs' bytes sum to the section's.
local function describe_section(
	context: Context,
	sections: { SectionDescription },
	data: buffer,
	section_offset: number,
	packet_values: { { any } }?,
	values_index: number
): (number, number)
	local flags, next_offset, offset, first_id, target_id, ids_count, nulled_count, removed_count, run_count =
		read_section_header(data, section_offset)

	if run_count ~= nil then
		local side: { any }? = nil
		if bit32.band(flags, flag_side_values) ~= 0 then
			values_index += 1
			side = if packet_values then packet_values[values_index] else nil
		end
		local wide = bit32.band(flags, flag_wide) ~= 0
		local framing = offset - section_offset
		local share = framing // run_count
		local remainder = framing % run_count
		local side_cursor = 0
		for r = 1, run_count do
			local run_offset = offset
			local run_flags, list_offset, run_target, run_end, run_ids, run_nulled, run_removed =
				read_run_header(data, run_offset, wide)
			local lists_end = list_offset + (run_ids + run_nulled + run_removed) * id_width
			local value_end: number? = nil
			if bit32.band(run_flags, flag_inline_values) ~= 0 then
				lists_end = run_end :: number
				value_end = lists_end - (run_nulled + run_removed) * id_width
			end
			local section = new_section("grouped")
			local relation = name_section(context, section, first_id, run_target)
			section.bytes = lists_end - run_offset + share + (if r <= remainder then 1 else 0)
			read_lists(
				context,
				section,
				relation,
				data,
				list_offset,
				run_ids,
				run_nulled,
				run_removed,
				value_end,
				side,
				side_cursor
			)
			if value_end == nil then
				side_cursor += run_ids
			end
			table.insert(sections, section)
			offset = lists_end
		end
		return next_offset, values_index
	end

	local section = new_section("plain")
	local relation = name_section(context, section, first_id, target_id)
	section.bytes = next_offset - section_offset
	local value_end: number? = nil
	local side: { any }? = nil
	if bit32.band(flags, flag_inline_values) ~= 0 then
		value_end = next_offset - (nulled_count + removed_count) * id_width
	elseif ids_count > 0 then
		values_index += 1
		side = if packet_values then packet_values[values_index] else nil
	end
	read_lists(context, section, relation, data, offset, ids_count, nulled_count, removed_count, value_end, side, 0)
	table.insert(sections, section)
	return next_offset, values_index
end

local function describe_entity(context: Context, id: number, gen: boolean): EntityDescription
	local resolver = context.resolver
	local entity = if gen then resolver.gen_entity(id) else resolver.entity(id)
	return {
		id = id,
		entity = entity :: any,
		name = name_of(context, id % 2 ^ 24, entity),
	}
end

local function describe_packet(packet: Packet, resolver: Resolver): PacketDescription
	local data = packet.data
	check_version(data)
	local frame, offset, unreplicated_count, replicated_count, names_count = read_packet_header(data)
	local header_bytes = offset

	-- the names list sits past the entity lists, but its announcements name ids those lists carry, so it is
	-- read first
	local names_offset = offset + unreplicated_count * id_width + replicated_count * gen_id_width
	local announced = {} :: { [number]: string }
	local name_entries = {} :: { { id: number, name: string } }
	local cursor = names_offset
	for _ = 1, names_count do
		local id, name, next_offset = read_name(data, cursor)
		if #name > 0 then
			announced[id % 2 ^ 24] = name
		end
		table.insert(name_entries, { id = id, name = name })
		cursor = next_offset
	end
	local context: Context = { resolver = resolver, announced = announced }

	local deleted = table.create(unreplicated_count) :: { EntityDescription }
	for i = 1, unreplicated_count do
		deleted[i] = describe_entity(context, read_id(data, offset), false)
		offset += id_width
	end
	local created = table.create(replicated_count) :: { EntityDescription }
	for i = 1, replicated_count do
		created[i] = describe_entity(context, read_gen_id(data, offset), true)
		offset += gen_id_width
	end

	local names = table.create(names_count) :: { NameDescription }
	for i, entry in name_entries do
		local entity = resolver.gen_entity(entry.id)
		local retracted = #entry.name == 0
		local name: string? = entry.name
		if retracted then
			name = if entity ~= nil then resolver.name(entity) else nil
		end
		names[i] = {
			id = entry.id,
			entity = entity :: any,
			name = name,
			retracted = retracted,
		}
	end

	local sections = {} :: { SectionDescription }
	local packet_values = packet.values
	local values_index = 0
	offset = cursor
	local data_size = buffer.len(data)
	while offset < data_size do
		offset, values_index = describe_section(context, sections, data, offset, packet_values, values_index)
	end

	local components = {} :: { [number]: ComponentDescription }
	for _, section in sections do
		roll_up(components, section)
	end

	return {
		frame = frame,
		bytes = data_size,
		header_bytes = header_bytes,
		entity_list_bytes = names_offset - header_bytes,
		names_bytes = cursor - names_offset,
		created = created,
		deleted = deleted,
		names = names,
		sections = sections,
		components = components,
	}
end

local function describe_chunk(chunk: buffer, resolver: Resolver): ChunkDescription
	check_chunk_version(chunk)
	local context: Context = { resolver = resolver, announced = {} }

	local sections = {} :: { SectionDescription }
	local offset = chunk_header_width
	local chunk_size = buffer.len(chunk)
	while offset < chunk_size do
		local _, next_offset, list_offset, first_id, target_id, ids_count, nulled_count =
			read_chunk_section_header(chunk, offset)
		local section = new_section("plain")
		local relation = name_section(context, section, first_id, target_id)
		section.bytes = next_offset - offset
		-- chunk values are always inline
		local value_end = next_offset - nulled_count * id_width
		read_lists(context, section, relation, chunk, list_offset, ids_count, nulled_count, 0, value_end, nil, 0)
		table.insert(sections, section)
		offset = next_offset
	end

	local components = {} :: { [number]: ComponentDescription }
	for _, section in sections do
		roll_up(components, section)
	end

	return {
		frame = read_chunk_frame(chunk),
		bytes = chunk_size,
		header_bytes = chunk_header_width,
		sections = sections,
		components = components,
	}
end

-- INSPECTORS

-- the describe pair over one resolver, as each half exports it
local function create_inspector(
	resolver: Resolver
): ((packet: Packet) -> PacketDescription, (chunk: buffer) -> ChunkDescription)
	local function describe_resolved_packet(packet: Packet): PacketDescription
		return describe_packet(packet, resolver)
	end

	local function describe_resolved_chunk(chunk: buffer): ChunkDescription
		return describe_chunk(chunk, resolver)
	end

	return describe_resolved_packet, describe_resolved_chunk
end

-- both halves name a local entity by its jecs.Name in the describing world
local function create_name_reader(world: World): (entity: number) -> string?
	return function(entity: number): string?
		local name = world:get(entity :: any, jecs.Name)
		return if type(name) == "string" then name else nil
	end
end

-- the server's view, whose wire ids are its own: a dense wire id resolves to the live entity holding that slot
-- now, a gen-qualified one only while that exact entity lives, and values decode through the world's serdes
-- store. resolution reads the world as it stands when describe runs, so describing a packet right after
-- generating it names everything it carries, while an entity deleted since (a deletion entry's, typically)
-- resolves to nothing.
local function create_server_inspector(world: World, resolve_serdes: ResolveSerdes)
	-- never replaced on a live world
	local entity_index = world.entity_index
	return create_inspector({
		entity = function(dense_id: number): number?
			return jecs.entity_index_get_alive(entity_index :: any, dense_id) :: any
		end,
		gen_entity = function(gen_id: number): number?
			if world:contains(gen_id :: any) then
				return gen_id
			end
			return nil
		end,
		name = create_name_reader(world),
		resolve_serdes = resolve_serdes,
	})
end

-- a client's view: wire ids resolve through its mapping -- client_entity_map (dense server id -> client
-- entity) and get_client_entity (the generation-checked lookup of a gen-qualified server id) -- to a live
-- mapped entity only, so describing before reconcile sees the mappings the packet has yet to establish as
-- unresolved, the packet's own announcements still naming them. values decode through the world's serdes
-- store.
local function create_client_inspector(
	world: World,
	resolve_serdes: ResolveSerdes,
	client_entity_map: { [number]: Entity },
	get_client_entity: (server_entity: number) -> Entity?
)
	return create_inspector({
		entity = function(dense_id: number): number?
			local client_entity = client_entity_map[dense_id]
			if client_entity ~= nil and world:contains(client_entity) then
				return client_entity :: any
			end
			return nil
		end,
		gen_entity = function(gen_id: number): number?
			local client_entity = get_client_entity(gen_id)
			if client_entity ~= nil and world:contains(client_entity) then
				return client_entity :: any
			end
			return nil
		end,
		name = create_name_reader(world),
		resolve_serdes = resolve_serdes,
	})
end

return {
	describe_packet = describe_packet,
	describe_chunk = describe_chunk,
	create_server_inspector = create_server_inspector,
	create_client_inspector = create_client_inspector,
}
