# Bandwidth

What replication sends: the byte cost of everything duplecs puts on the wire — per-entry prices that follow directly from the wire format, plus measured packet sizes for representative frames. Every number comes from one benchmark, [`tests/benchmarks/bench_bandwidth.luau`](../../tests/benchmarks/bench_bandwidth.luau), and unlike the [performance guide](012-performance.md)'s timings, bytes are deterministic: the same shapes produce the same bytes on any machine, so the tables here are exact rather than ballpark (see [Refreshing the numbers](#refreshing-the-numbers)).

## How to read the numbers

Four things frame every table below:

- **Bytes are per receiving client.** Encoding work is shared — a change visible to thirty clients is encoded once — but each client still receives its own packet, so the server's *upload* for a change is its byte cost times the number of clients who can see it. Visibility filters cut bandwidth exactly as directly as they cut visibility: a client's packet only ever contains what that client is allowed to see.
- **The reliable stream charges for changes, not state.** A quiet frame returns no packet at all — zero bytes, however large the world — and nothing is ever re-sent. Byte volume follows how much changes, not how often `generate_packets` runs: calling less often batches the same entries into fewer packets, and successive changes to one value coalesce, so only the latest ships. The unreliable channel is the opposite — every visible value, every call — which is why it gets [its own section](#the-unreliable-channel).
- **Hookless buffer bytes are not the whole cost.** Values with [serdes hooks](008-serdes.md) pack into the packet buffer and are fully priced below. A hookless value contributes only its 3-byte entity id to the buffer; the value itself rides the packet's `values` side array, which your transport serializes on its own terms — usually for several times what a purpose-built encoding would take (see [The side array](#the-side-array)).
- **The budget these numbers meet.** Roblox's guidance is roughly 50 KB/s per player. Ordinary deltas sit far below it — the measured frames below are a few hundred bytes — and the two spenders that actually reach it are the [join snapshot](#joins) and the [unreliable channel](#the-unreliable-channel).

## The fixed costs

Every packet starts with 6 bytes — the wire version, the packet frame, and a flag byte — plus 2 bytes for each list the packet actually carries (entity creations, entity deletions, name announcements); absent lists cost nothing, not even their counts. Counts and lengths are 2 bytes throughout, and a packet or section whose counts overflow 65,535 switches itself to 4-byte counts — so pathological sizes pay two extra bytes per count rather than hitting a cap.

A settled world sends nothing at all: `generate_packets` on a frame with no changes returns no packet for any client.

## Values

A changed value costs, on top of its section's framing:

| Encoding | Buffer bytes per value | Where the value's bytes go |
| --- | --- | --- |
| Hookless (no serdes) | 3 | the side array — the transport serializes it |
| Serdes with a static `size` | 3 + `size` | inline in the buffer |
| Serdes without a declared `size` | 5 + encoded length | inline, behind a 2-byte length prefix |

The 3 bytes are the entity id every entry pays. Changed values of one component addressed to the same viewers share one **section**, whose framing — 6 bytes, or 8 when values ride inline — is paid once for the whole batch, so framing amortizes to nothing in bulk and matters only when viewer sets fragment (see [Visibility fragmentation](#visibility-fragmentation)). Measured, with everything visible to everyone:

| Changed values in the frame | Packet size | Per value |
| --- | --- | --- |
| 1, hookless | 15 B + 1 side value | 15 B |
| 64, hookless | 204 B + 64 side values | 3.2 B |
| 1024, hookless | 3,084 B + 1,024 side values | 3.0 B |
| 64, 8-byte serdes (`size = 8`) | 718 B | 11.2 B |
| 64, 8-byte serdes, no `size` | 846 B | 13.2 B |

Don't read the hookless rows as the cheap option — their buffer is small because the values aren't in it. And two levers cut value traffic to zero:

- **`NetworkedOnce` ships one value per lifetime** — the add replicates, changes never do (see [Replication basics](002-replication.md)). For values the client can simulate itself, this is the whole bandwidth story.
- **Equal re-sets still ship.** jecs fires its changed hook even when a set writes the value already stored, so a system that re-sets unchanged values every frame ships them every frame. Guard chatty systems with an equality check before the set.

## Adds, removes, and toggles

Structure is cheap and flat: a tag add, a tag remove, or a component removal is a 3-byte entity id in the appropriate section list, sharing the same 6-byte section framing as values. Adding a *data* component is just a value set — the rows above. Measured at 64 ops per frame, each of these is a 204-byte packet — 3.2 B per op.

## Pairs

A pair section names the relation once, so what a pair costs depends on how many distinct targets are in play that frame:

| Shape | Packet size | Per value |
| --- | --- | --- |
| 64 pair values, one shared target | 207 B + 64 side values | 3.2 B |
| 64 pair values, 64 distinct targets | 590 B + 64 side values | 9.2 B |

With a shared target the section carries the relation and target once (9 bytes) and 3 bytes per subject — pair traffic at plain-component prices. Distinct targets group under one section that pays the relation once, plus 6 bytes of framing per target alongside each subject's 3. And a pair is never sent to a client who cannot see its target ([Replicating relationships](003-pairs.md)), so pair bandwidth follows target visibility for free.

## Entity lifecycle

| Shape | Packet size | Per entity |
| --- | --- | --- |
| 64 spawns, two hookless components each | 724 B + 128 side values | 11.3 B |
| 64 despawns | 200 B | 3.1 B |

A newly visible entity costs a 5-byte creation entry — the one place (besides names) the wire spends a full generation-qualified id, since this is where the client learns it — plus its components at the value rates above. A despawn is a 3-byte deletion entry, *flat*: the component removals are implied by the deletion and never itemized, so mass despawn frames are the cheapest mass anything in the format.

## Shared names

A [shared-name announcement](004-entity-mapping.md) costs 6 bytes plus the name itself, a retraction 6 bytes — measured, 8 announcements with 12-byte names make a 152-byte packet. Announcements are one-shot schema traffic (each definition announces once per client, plus once in every full packet), so name length is never a per-frame concern; it just scales the join snapshot and the one delta that carries the announcement.

## Joins

A joiner's full packet is everything currently visible to them, priced at exactly the rates above: a 5-byte creation entry per entity, 3 bytes per visible component plus its value, and section framing. Measured from the same world the [performance guide](012-performance.md#joiners)'s joiner uses — 1,024 entities, 1,536 visible components, hookless values:

| | |
| --- | --- |
| Full packet | 11,310 B + 1,280 side values |
| Per visible component | 7.4 B |
| Per entity | 11.0 B |

Joins scale linearly with visible content and land in one send: a world holding tens of thousands of visible components produces a full packet in the hundreds of kilobytes, through one remote, at exactly the moment a player joins. If that describes your world, budget for the spike — or narrow what a fresh joiner can see (visibility filters admit clients gradually just fine).

## The unreliable channel

`generate_unreliable_chunks` re-sends every visible value on every call, so its cost is a rate multiplied by a population — the one place duplecs bandwidth grows without anything changing. Per call and client: a 5-byte header per chunk, 8 bytes of section framing per component per chunk, and 3 bytes plus the encoded size per value. Measured with 8-byte values at the default 980-byte budget:

| Visible values | Per call | At 20 Hz | At 60 Hz |
| --- | --- | --- | --- |
| 16 | 189 B (1 chunk) | 3.8 KB/s | 11.3 KB/s |
| 128 | 1,434 B (2 chunks) | 28.7 KB/s | 86 KB/s |
| 512 | 5,710 B (6 chunks) | 114 KB/s | 343 KB/s |

The rule of thumb: an 8-byte encoding streams at ~11 B per value per call, so a 50 KB/s budget buys about 150 streamed values at 30 Hz — before the reliable stream and joins take their share. Both knobs matter equally: halving the call rate and halving the encoded size save the same bytes, and a quantized encoding (positions as three 16-bit integers instead of three doubles, say) routinely cuts this channel by two thirds. Visibility is the third knob — only values visible to a client enter their chunks, so distance-gating a streamed component pays for itself immediately.

## Visibility fragmentation

Sections are shared per (component, viewer set), so framing overhead follows how many *distinct* viewer sets your changed values split into — the same axis the [performance guide](012-performance.md#visibility-fragmentation) measures for CPU. The extremes, 512 changed hookless values either all sharing one 16-client whitelist or each holding its own:

| Distinct whitelists | Packet size | Per value |
| --- | --- | --- |
| 1 | 1,548 B | 3.0 B |
| 512 | 4,614 B | 9.0 B |

At the fragmented extreme every value is its own one-entry section — 6 bytes of framing wrapping 3 bytes of id. The design lever is the perf guide's, verbatim: share filters (teams, regions, [inherited filters](006-visibility-inheritance.md)) and both costs stay at the top row; filters with equal membership count as the same viewer set even when they are different tables.

## The side array

Hookless values never enter the buffer: each hookless section contributes one array to the packet's `values`, and sending those is the transport's business. On a Roblox remote, every element costs a type tag plus its payload — a plain number lands around 9 bytes, and a table a multiple of that — plus framing for the arrays themselves, so a hookless value's true wire cost is usually several times its 3-byte buffer share. That is the deliberate day-one trade: ship without writing any encodings, then move your chattiest components onto [serdes hooks](008-serdes.md), where the same value costs its encoded bytes and nothing else. The tables above tell you which components are worth the trip — it is almost always the ones in the [unreliable channel](#the-unreliable-channel) and whatever dominates your join snapshot.

## Refreshing the numbers

```sh
lune run tests/benchmarks/bench_bandwidth.luau
```

Every table in this guide restates that benchmark's output, byte-exact. There is no hardware to calibrate for — re-running is a *version* check: a number that moved means the wire format did, and the [changelog](../../CHANGELOG.md) notes wire changes per release. The workload shapes (batch sizes, encodings, whitelist pools) are constants at the top of the benchmark and are restated by its output, so a reading is always interpretable on its own.
