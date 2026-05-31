/* ===========================================================================
 * spsc_ring_buffer.S — Lock-Free SPSC Ring Buffer for ARMv8-A
 *                      (Cortex-A53, Cortex-A76, and any ARMv8-A core)
 * ===========================================================================
 *
 * OVERVIEW
 * --------
 * A Single-Producer Single-Consumer (SPSC) ring buffer is the simplest form
 * of lock-free queue. Only ONE thread may call push (the producer) and only
 * ONE thread may call pop (the consumer). This constraint means we never need
 * atomic read-modify-write (no LDXR/STXR, no CAS), we only need proper
 * load/store ordering.
 *
 * WHY MEMORY BARRIERS ON CORTEX-A76?
 * -----------------------------------
 * ARM processors (including Cortex-A76) have a WEAK memory model. This means
 * the CPU is free to reorder loads and stores for performance, as long as the
 * reordering is invisible to the CURRENT thread. But another thread on another
 * core CAN observe these reorderings.
 *
 * ACQUIRE-RELEASE SEMANTICS (ARMv8.0-A relies on RCsc)
 * -------------------------
 * ARMv8-A provides two key instructions for ordering without full barriers:
 *
 *   LDAR  (Load-Acquire Register)
 *     Mnemonic breakdown: LD = Load, A = Acquire, R = Register
 *     Semantics: loads a value AND prevents any subsequent memory operation
 *     (load or store) from being reordered BEFORE this load (the one-way
 *     "acquire" fence).
 *
 *     IMPORTANT — RCsc strength: LDAR is more than a one-way fence. It also
 *     cannot be reordered before a PRIOR STLR, even one to a DIFFERENT
 *     address. In other words, all LDAR/STLR operations in the system slot
 *     into a single total order that every core agrees on. This is the
 *     "Release Consistent sequentially consistent" (RCsc) property, and it
 *     maps to C++11 memory_order_seq_cst. This is exactly what ARMv8.3's
 *     RCpc LDAPR will later relax.
 *
 *   STLR  (Store-Release Register)
 *     Mnemonic breakdown: ST = Store, L = reLease, R = Register
 *     Semantics: stores a value AND ensures all preceding memory operations
 *     (loads and stores) are visible BEFORE this store is seen by others
 *     (the one-way "release" fence).
 *
 * Together, STLR (producer) + LDAR (consumer) form an ACQUIRE-RELEASE PAIR:
 *   - Producer: write data, then STLR tail  ->  data is visible before tail
 *   - Consumer: LDAR tail, then read data   ->  sees data written before tail
 *
 * These are cheaper than full DMB barriers because each only enforces ordering
 * in one direction (acquire = downstream fence, release = upstream fence),
 * whereas DMB is a bidirectional fence that stalls more of the pipeline.
 *
 * CACHED INDICES OPTIMIZATION
 * ---------------------------
 * In the basic SPSC design, the producer must read `tail` (LDAR) on every
 * push to check if the buffer is full, and the consumer must read `head`
 * (LDAR) on every pop to check if the buffer is empty.
 *
 * This is wasteful: if the buffer has 1000 free slots, the producer doesn't
 * need to re-check tail for the next 999 pushes!
 *
 * common optimization: each side keeps a local cache of the other's index.
 *   - Producer keeps `cached_tail`: the last known value of tail
 *   - Consumer keeps `cached_head`: the last known value of head
 *
 * The cached value is only refreshed (with an expensive LDAR) when the stale
 * cache suggests the buffer MIGHT be full/empty. This dramatically reduces
 * cross-core cache traffic and expensive acquire loads in the common case.
 *
 * WHAT ABOUT LDAPR? (ARMv8.3-A FEAT_LRCPC, RCpc)
 * ----------------------------------------------
 * ARMv8.3-A introduced LDAPR (Load-Acquire RCpc Register). It provides
 * "Release Consistent processor consistent" (RCpc) ordering, which is a
 * weaker, and for this queue, sufficient, form of acquire.
 *
 * Unfortunatelly, the Cortex-A53 implements ARMv8.0-A. FEAT_LRCPC (LDAPR)
 * was not added until ARMv8.3-A, so on the A53 the LDAPR encoding is
 * simply not a valid instruction. Therefore this implementation uses
 * LDAR/STLR throughout. The cost is a marginally stronger-than-necessary
 * ordering on each acquire load; the benefit is correct, portable code
 * on every ARMv8.0-A part including the A53.
 *
 * STRUCT LAYOUT (must match C header)
 * -----------------------------------
 * The struct is carefully laid out so that fields accessed by different threads
 * reside on DIFFERENT CACHE LINES (64 bytes on Cortex-A76). This prevents
 * "false sharing" where writes by one core invalidate the cache line on the
 * other core, even for unrelated data.
 *
 * Offset  Field           Accessed by     Description
 * ------  -----           -----------     -----------
 *   0     buffer          both (RO)       Pointer to element storage
 *   8     capacity        both (RO)       Number of slots (must be power of 2)
 *  16     mask            both (RO)       capacity - 1 (for fast modulo via AND)
 *  24     element_size    both (RO)       Size of each element in bytes
 *  32     (padding)       -               Pad to 64-byte boundary
 *  ---    CACHE LINE BOUNDARY (64) ---
 *  64     head            producer (W)    Next write index
 *                         consumer (R)
 *  72     cached_tail     producer only   Producer's snapshot of tail
 *  80     (padding)       -               Pad to 64-byte boundary
 *  ---    CACHE LINE BOUNDARY (128) ---
 * 128     tail            consumer (W)    Next read index
 *                         producer (R)
 * 136     cached_head     consumer only   Consumer's snapshot of head
 * 144     (padding)       -               Pad to 64-byte boundary
 *  ---    END (192) ---
 */

// targeting arm cortex a53
.text
    .arch   armv8-a

// --- Struct field offsets (keep in sync with spsc_ring_buffer.h) ---
    .equ    OFF_BUFFER,         0          // void*  element storage pointer
    .equ    OFF_CAPACITY,       8          // u64    slot count (power of 2)
    .equ    OFF_MASK,           16         // u64    capacity - 1 (fast modulo)
    .equ    OFF_ELEM_SIZE,      24         // u64    bytes per element
    // --- 64-byte cache line boundary ---
    .equ    OFF_HEAD,           64         // u64    next write index (producer)
    .equ    OFF_CACHED_TAIL,    72         // u64    producer's snapshot of tail
    // --- 64-byte cache line boundary ---
    .equ    OFF_TAIL,           128        // u64    next read index (consumer)
    .equ    OFF_CACHED_HEAD,    136        // u64    consumer's snapshot of head

// int spsc_init(rb=x0, buffer=x1, capacity=x2, element_size=x3) — one-time setup
    .global spsc_init
    .type   spsc_init, %function
spsc_init:
    // Store read-only config fields
    str     x1, [x0, #OFF_BUFFER]
    str     x2, [x0, #OFF_CAPACITY]
    sub     x4, x2, #1
    str     x4, [x0, #OFF_MASK]            // mask = capacity - 1
    str     x3, [x0, #OFF_ELEM_SIZE]

    // Zero all indices (buffer starts empty)
    str     xzr, [x0, #OFF_HEAD]
    str     xzr, [x0, #OFF_CACHED_TAIL]
    str     xzr, [x0, #OFF_TAIL]
    str     xzr, [x0, #OFF_CACHED_HEAD]

    ret
    .size   spsc_init, . - spsc_init

// int spsc_push(rb=x0, element=x1) -> 0 ok / 1 full — PRODUCER ONLY
    .global spsc_push
    .type   spsc_push, %function
spsc_push:
    // Prologue: save callee-saved registers
    stp     x19, x20, [sp, #-48]!
    stp     x21, x22, [sp, #16]
    stp     x23, x24, [sp, #32]

    mov     x19, x0                        // x19 = rb (preserved)
    mov     x20, x1                        // x20 = element source

    ldr     x21, [x19, #OFF_HEAD]          // plain load: producer owns head

    // next_head = (head + 1) & mask
    ldr     x9, [x19, #OFF_MASK]
    add     x22, x21, #1
    and     x22, x22, x9

    // Full check vs cached_tail (full when next_head == tail; one slot wasted)
    ldr     x10, [x19, #OFF_CACHED_TAIL]
    cmp     x22, x10
    b.ne    .Lpush_has_space

    // Cache was stale: reload real tail with acquire, then re-check
    add     x11, x19, #OFF_TAIL
    ldar    x10, [x11]                     // acquire: see consumer's reads before its tail store
    str     x10, [x19, #OFF_CACHED_TAIL]
    cmp     x22, x10
    b.eq    .Lpush_full                     // still equal -> truly full

.Lpush_has_space:
    // dest = buffer + head * element_size
    ldr     x23, [x19, #OFF_ELEM_SIZE]
    ldr     x24, [x19, #OFF_BUFFER]
    mul     x9, x21, x23
    add     x24, x24, x9

    // Byte-by-byte copy element into slot (use LDP/STP for production)
    mov     x9, x23
.Lpush_copy:
    cbz     x9, .Lpush_copy_done
    ldrb    w10, [x20], #1
    strb    w10, [x24], #1
    sub     x9, x9, #1
    b       .Lpush_copy
.Lpush_copy_done:

    // Publish new head with release: guarantees data writes land before head
    add     x9, x19, #OFF_HEAD
    stlr    x22, [x9]

    mov     x0, #0                         // success
    b       .Lpush_return

.Lpush_full:
    mov     x0, #1                         // full

.Lpush_return:
    // Epilogue: restore callee-saved registers
    ldp     x23, x24, [sp, #32]
    ldp     x21, x22, [sp, #16]
    ldp     x19, x20, [sp], #48
    ret
    .size   spsc_push, . - spsc_push

// int spsc_pop(rb=x0, element=x1) -> 0 ok / 1 empty — CONSUMER ONLY
    .global spsc_pop
    .type   spsc_pop, %function
spsc_pop:
    // Prologue: save callee-saved registers
    stp     x19, x20, [sp, #-48]!
    stp     x21, x22, [sp, #16]
    stp     x23, x24, [sp, #32]

    mov     x19, x0                        // x19 = rb
    mov     x20, x1                        // x20 = destination

    ldr     x21, [x19, #OFF_TAIL]          // plain load: consumer owns tail

    // Empty check vs cached_head (empty when tail == head)
    ldr     x10, [x19, #OFF_CACHED_HEAD]
    cmp     x21, x10
    b.ne    .Lpop_has_data

    // Cache was stale: reload real head with acquire, then re-check
    add     x11, x19, #OFF_HEAD
    ldar    x10, [x11]                     // acquire: see producer's data written before its head store
    str     x10, [x19, #OFF_CACHED_HEAD]
    cmp     x21, x10
    b.eq    .Lpop_empty                     // still equal -> truly empty

.Lpop_has_data:
    // src = buffer + tail * element_size
    ldr     x23, [x19, #OFF_ELEM_SIZE]
    ldr     x24, [x19, #OFF_BUFFER]
    mul     x9, x21, x23
    add     x24, x24, x9

    // Byte-by-byte copy slot into caller's buffer
    mov     x9, x23
.Lpop_copy:
    cbz     x9, .Lpop_copy_done
    ldrb    w10, [x24], #1
    strb    w10, [x20], #1
    sub     x9, x9, #1
    b       .Lpop_copy
.Lpop_copy_done:

    // new_tail = (tail + 1) & mask
    ldr     x9, [x19, #OFF_MASK]
    add     x22, x21, #1
    and     x22, x22, x9

    // Publish new tail with release: guarantees our reads finish before slot is freed
    add     x9, x19, #OFF_TAIL
    stlr    x22, [x9]

    mov     x0, #0                         // success
    b       .Lpop_return

.Lpop_empty:
    mov     x0, #1                         // empty

.Lpop_return:
    // Epilogue: restore callee-saved registers
    ldp     x23, x24, [sp, #32]
    ldp     x21, x22, [sp, #16]
    ldp     x19, x20, [sp], #48
    ret
    .size   spsc_pop, . - spsc_pop
