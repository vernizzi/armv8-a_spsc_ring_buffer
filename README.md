# SPSC Ring Buffer (ARMv8-A Assembly)

A lock-free **Single-Producer Single-Consumer** ring buffer written in
hand-rolled ARMv8-A assembly, targeting the Cortex-A53.

## Background

This is an old project of mine from when I was trying to *properly* understand
how atomics, memory barriers, and lock-free programming actually work at the
hardware level, not just at the `std::atomic` API surface, but down at the
instruction and memory-model layer where the real ordering guarantees live.

I recently dug it back out and decided to document it properly, both as a
reference for my future self and in case it's useful to anyone else trying to
bridge the gap between the C++ memory model and what the silicon actually does.

AArch64 wasn't a random choice. Unlike x86, which has a fairly strong memory
model that papers over a lot of reordering, ARM is genuinely weakly ordered, so
you can't get away with sloppy reasoning, the hardware will happily reorder
things across cores and expose every mistake.

## Where the Documentation Lives

Most of the explanation is written **inline in the assembly file itself**
(`spsc_ring_buffer.S`). I deliberately kept the prose next to the code it
describes, so reading the source top-to-bottom doubles as a walkthrough of:

- Why an SPSC queue needs **no** atomic read-modify-write (no `LDXR`/`STXR`, no CAS), just correct load/store ordering.
- Acquire-release semantics via `LDAR` / `STLR`, and why they're cheaper than a full `DMB` barrier.
- The producer→consumer **happens-before** edge that makes the data transfer safe.
- The cache-line layout used to avoid **false sharing** between the producer and consumer.
- Why the capacity is a power of two (cheap `AND` instead of modulo).
- The cached-indices optimization to cut cross-core cache traffic.

If you want the details, read the comments in the `.S` file, they're the
primary documentation.

## ARMv8-A vs ARMv8.3-A: Memory Ordering and the C++ Memory Model

One of the things this project clarified for me is the distinction between two
flavors of acquire ordering and how they map onto C++11's `std::memory_order`.
Since this matters for *why* the code uses the instructions it does, here's a
summary.

### The two consistency models

| Model | Meaning | ARM instruction | C++ mapping |
|-------|---------|-----------------|-------------|
| **RCsc** | Release Consistent *sequentially consistent* | `LDAR` / `STLR` | `memory_order_seq_cst` |
| **RCpc** | Release Consistent *processor consistent* | `LDAPR` / `STLR` | `memory_order_acquire` / `memory_order_release` |

### What's actually different

Both models give you a correct **acquire**: nothing after the load can be
reordered before it, and reading a value published by a `STLR` establishes the
synchronizes-with / happens-before edge. So the publish-data-then-set-a-flag
pattern works identically under both.

The **only** difference is what happens with a **Store-Release followed by a
Load-Acquire to a *different* address**:

- **RCsc (`LDAR`)** keeps that ordering. All release/acquire operations across
  the system fall into a single total order that every core agrees on. This is
  what `seq_cst` promises, and it's what forbids the classic Store-Buffering
  outcome.
- **RCpc (`LDAPR`)** relaxes it. A prior `STLR` to a different address may be
  reordered after the `LDAPR`, so there's no enforced global total order. This
  matches what plain `acquire`/`release` actually requires, no more, no less.

### Why it matters for this queue

`LDAR` is **stronger than `memory_order_acquire` actually requires**. A
compiler targeting ARMv8.0-A must emit `LDAR` for an acquire load, so every
acquire pays for an SC-grade store→load ordering it never asked for.

For an SPSC ring buffer, correctness rests entirely on the per-index
release/acquire happens-before edge, there's no Dekker/Store-Buffering-style
handshake anywhere. That means the extra global ordering `LDAR` provides is
dead weight. On an ARMv8.3+ core you could swap the acquire loads to `LDAPR`
for a small throughput win at zero correctness cost.

### Why this implementation still uses `LDAR`

The **Cortex-A53 implements ARMv8.0-A**, and `LDAPR` was introduced as
`FEAT_LRCPC` in **ARMv8.3-A**. On the A53 the `LDAPR` encoding simply isn't a
valid instruction. So this code uses `LDAR`/`STLR` throughout: marginally
stronger ordering than strictly necessary, in exchange for correct, portable
behavior on every ARMv8.0-A part.

## Target

- Primary: Cortex-A53 (ARMv8.0-A, AArch64)
- Builds and runs correctly on any ARMv8-A core

