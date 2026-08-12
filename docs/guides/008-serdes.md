# Serdes: Packing Values into the Buffer

Serdes — serialize/deserialize — hooks give a component's values a byte encoding, so they pack inline into the packet buffer instead of traveling as plain Luau values in the packet's `values` side array. You don't need them to get replicating — hookless components work out of the box — but they are the main bandwidth lever: a side-array value pays Roblox's generic serialization; an inline value pays exactly the bytes you encode. Exact contracts live in the spec's [Serdes](../spec.md#serdes-server--client) section.

## The shape: one buffer per value

A registration is a `Serdes` value set on the **component definition entity** itself:

```lua
-- in shared/components.luau
world:set(Loadout, net.Serdes, {
	encode = function(value)
		-- return a buffer holding exactly this value's bytes
	end,
	decode = function(data)
		-- return the value, from one such buffer
	end,
})
```

`encode` returns a freshly-created buffer per value; `decode` receives one (always a fresh buffer, never a view into the packet). This one-buffer-per-value shape is deliberately the signature third-party serdes libraries expose — which makes a library the easy starting point.

## The easy path: a third-party library

Rather than hand-writing byte layouts, hand the job to a serialization library and adapt its API in a few lines. With [Squash](https://github.com/Data-Oriented-House/Squash), for example, describe the value's shape once and bridge through its cursor API:

```lua
-- in shared/components.luau

local Squash = require("./roblox_packages/squash")
local T = Squash.T

local loadout_shape = Squash.record({
	primary = T(Squash.string()),
	ammo = T(Squash.uint(2)),
	attachments = T(Squash.array(Squash.string())),
})

local loadout_serdes = {
	encode = function(value)
		local cursor = Squash.cursor()
		loadout_shape.ser(cursor, value)
		return Squash.tobuffer(cursor)
	end,
	decode = function(data)
		return loadout_shape.des(Squash.frombuffer(data))
	end,
}

world:set(Loadout, net.Serdes, loadout_serdes)
```

Any library that can take a value to a buffer and back fits the same adapter. This is the recommended starting point: correctness (matching writes to reads) lives in one declarative shape, and duplecs handles the framing. Each encoded value is copied into the packet behind a `u16` length prefix, and values addressed to entities a client cannot map are skipped over by that prefix, without decoding.

## Register symmetrically, before packets flow

Hooks must be assigned on **both sides** — same components, same encodings — before any packets flow: receiving inline values for a component with no local hooks is an error during reconciliation. The natural home is the shared component definitions module both sides already run (see [Getting started](001-getting-started.md)), so a registration can never exist on one side only:

```lua
-- in shared/components.luau
local Loadout = world:component() :: jecs.Entity<Loadout>
world:set(Loadout, jecs.Name, "Loadout")
world:set(Loadout, net.Serdes, loadout_serdes)
```

(`net` here is `duplecs.shared(world)` — the component set that is the same on both sides, and carries `Serdes` — so the module needs nothing passed in beyond the world.)

## Fixed-width values: declare `size`

When every value encodes to the same byte length, declare it and the per-value length prefix disappears from the wire — and duplecs can size packets arithmetically without even calling `encode` where possible:

```lua
-- in shared/components.luau
world:set(Position, net.Serdes, {
	size = 12,
	encode = function(value: Vector3): buffer
		local data = buffer.create(12)
		buffer.writef32(data, 0, value.X)
		buffer.writef32(data, 4, value.Y)
		buffer.writef32(data, 8, value.Z)
		return data
	end,
	decode = function(data: buffer): Vector3
		return Vector3.new(buffer.readf32(data, 0), buffer.readf32(data, 4), buffer.readf32(data, 8))
	end,
})
```

With `size` declared, every value must encode to exactly that many bytes — a mismatch is refused at generation. Both sides must also agree on whether `size` is declared at all: the prefix is part of the value stream's encoding, so declaring it on one side only breaks the framing.

## Relations and concrete pairs

A registration on a relation covers every pair using it as the relation. When one particular target needs a different encoding, register for the concrete pair — it takes precedence over the relation's own:

```lua
-- in shared/components.luau
world:set(DamageOver, net.Serdes, number_serdes)                    -- every pair(DamageOver, *)
world:set(DamageOver, jecs.pair(net.Serdes, fire), fire_serdes)     -- pair(DamageOver, fire) only
```

Tags cannot carry serdes hooks (they have no values); registering one errors. Registrations follow their ids' lifetimes — deleting the definition (or a concrete pair's target) clears them — and registration tables are frozen once set, like visibility filters.

## Rules your hooks must follow

- **Pure and non-throwing.** `encode` may legitimately run more than once per value (failure containment re-encodes surviving values), so it must have no side effects. A throw is contained, not catastrophic: exactly the failing values are pruned from that frame with a warning naming the component, and everything else ships. But a pruned value simply never reaches clients until it next changes — for a `NetworkedOnce` component that may be never (push with `force_replicate` once the hook is fixed) — so treat encode failures as bugs to fix, not a flow-control mechanism.
- **Stay under 64 KiB per value.** A single value encoding to 2^16 bytes or more is refused at generation (the `u16` prefix can't frame it). Values that large belong outside the packet stream anyway.
- **Never `nil`.** Hooks never see `nil` values — nulled entries travel in their own list — so encodings don't need a nil case.

## When to bother

Reasonable priorities, in order: [`NetworkedUnreliable`](009-unreliable.md) components **must** have hooks — chunking requires byte-exact sizing and there is no side-array fallback (generating drops a hookless value with a warning, and reconciling one errors). High-frequency or high-volume reliable components benefit most. Low-traffic components can stay hookless indefinitely — the side array is correct, just not compact. Adding hooks to a component later changes how its values are framed on the wire, so both sides must gain them together, like any other wire-affecting change.
