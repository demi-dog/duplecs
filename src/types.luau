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

return {}
