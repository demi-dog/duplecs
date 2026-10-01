--!strict

-- types shared by the client and server halves of duplecs. each half exports its side-specific types itself;
-- init.luau re-exports the public ones.

local jecs = require("../roblox_packages/jecs")

-- internal readability aliases for jecs's types, not part of the public surface: consumers require jecs
-- anyway, so the module root deliberately re-exports none of these.
export type World = jecs.World

-- all three are interchangeable when `T` matches or is `any`; they exist separately purely for readability.
export type Entity = jecs.Entity<nil>
export type Component<T = any> = jecs.Entity<T> -- an entity used as a component.
export type Id<T = any> = jecs.Id<T> -- may be a pair; pairs are not entities and can't contain components.

export type Client = any

-- one privacy filter, the value type of both Private filter levels (see the server half for the mechanics):
-- all-true values admit exactly the named clients (a whitelist), all-false values admit everyone except them
-- (a blacklist); mixing polarities in one table errors, and an empty table reads as a whitelist, blocking
-- everyone.
export type Privacy = { [Client]: boolean }

-- data packs the whole packet -- frame, entity create/delete lists, and every section back-to-back (see
-- wire.luau) -- so a packet is wire-ready as returned. values holds one array per section with hookless
-- values (components without serdes hooks), in section order; a grouped pair section's array concatenates its
-- hookless runs' values in run order. the arrays are shared by reference between every client whose
-- visibility mask matched at build time, so they must never be mutated downstream. one component may appear
-- in several sections of one packet; cells are independent, so the apply order between sections does not
-- matter.
export type Packet = {
	data: buffer,
	values: { { any } }?,
}

-- byte encoding and decoding for one component's values, in the one-buffer-per-value shape third-party serdes
-- libraries expose: encode returns a buffer holding exactly one value's bytes, decode receives one such
-- buffer (always freshly created, never a view into the packet). values are never nil (nulled cells travel in
-- their own list), and hooks must be assigned symmetrically on the server and client before any packets flow.
-- encode runs once per value at generation and the bytes are copied behind a u16 length prefix, so a value
-- encoding to 2^16 bytes or more is refused; a static `size` omits the prefix (every value must then encode
-- to exactly that many bytes, and both sides must declare it, since it changes the framing). hooks must be
-- pure and should never throw: both packet generators contain an encode failure by pruning exactly the
-- offending values with a warning, re-encoding the failed list's survivors (hence pure) -- a pruned value
-- replicates again at its cell's next staged change, or every call on the unreliable channel -- and both
-- reconcile entry points contain a decode failure by skipping exactly that value with a warning (the framing
-- carries every length), the rest of the packet still applying.
export type Serdes<T = any> = {
	size: number?,
	encode: (value: T) -> buffer,
	decode: (buf: buffer) -> T,
}

-- the debug inspector's record views (see inspect.luau, which builds them for both halves'
-- describe_packet / describe_chunk). every id is a raw wire id -- dense for everything a section carries and
-- for the deletion list, gen-qualified in the creation and names lists, the packed pair id for a pair's
-- component -- and entity is the local id the describing half resolves it to, nil when it resolves to
-- nothing. byte counts come from the wire's own length prefixes and counts, never from decoding, so they are
-- exact whether or not values decode. like every public table shape, these may gain fields in a minor release
-- but never lose or change one.
export type EntityDescription = {
	id: number,
	entity: Entity?,
	name: string?,
}

export type NameDescription = {
	id: number,
	entity: Entity?,
	-- the announced name; for a retraction, the name the describing world resolves for the id, if any
	name: string?,
	retracted: boolean,
}

-- one section of a packet or chunk, or one per-target run of a grouped pair section. values decode only where
-- the describing half resolves the section's ids and serdes hooks (a throwing decode hook leaves them nil
-- too); hookless values are read off the packet's side array and always present. ids is always a list (empty
-- for a section setting no values); nulled and removed are nil when absent.
export type SectionDescription = {
	component: number,
	relation: number?,
	target: number?,
	name: string?,
	relation_name: string?,
	target_name: string?,
	entity: Id?,
	layout: "plain" | "grouped",
	bytes: number,
	value_bytes: number,
	ids: { number },
	values: { any }?,
	nulled: { number }?,
	removed: { number }?,
	side_values: number,
}

-- one component's (or concrete pair's) sections summed across a packet or chunk
export type ComponentDescription = {
	bytes: number,
	value_bytes: number,
	entries: number,
	side_values: number,
	name: string?,
	relation_name: string?,
	target_name: string?,
}

export type PacketDescription = {
	frame: number,
	bytes: number,
	header_bytes: number,
	entity_list_bytes: number,
	names_bytes: number,
	created: { EntityDescription },
	deleted: { EntityDescription },
	names: { NameDescription },
	sections: { SectionDescription },
	components: { [number]: ComponentDescription },
}

export type ChunkDescription = {
	frame: number,
	bytes: number,
	header_bytes: number,
	sections: { SectionDescription },
	components: { [number]: ComponentDescription },
}

-- the server's opt-in byte counters for one generate_packets / generate_unreliable_chunks call (see
-- stats.luau). encoded_bytes is paid once per group of clients sharing the bytes; sent_bytes, entries, and
-- side_values are summed over every recipient.
export type ComponentStats = {
	encoded_bytes: number,
	sent_bytes: number,
	entries: number,
	side_values: number,
}

export type PacketStats = {
	packets: number,
	sent_bytes: number,
	overhead_bytes: number,
	components: { [Id]: ComponentStats },
}

return {}
