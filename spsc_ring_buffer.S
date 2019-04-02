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
