#ifndef SPSC_RING_BUFFER_H
#define SPSC_RING_BUFFER_H

#include <stdint.h>
#include <stddef.h>

#define SPSC_CACHELINE_SIZE 64

/*
 * Ring buffer structure.
 *
 * MEMORY LAYOUT (must match assembly offsets exactly):
 *
 *   Offset   Field           Size   Notes
 *   ------   -----           ----   -----
 *     0      buffer          8      Pointer to element storage
 *     8      capacity        8      Number of slots (power of 2)
 *    16      mask            8      capacity - 1 (for fast modulo)
 *    24      element_size    8      Bytes per element
 *           (automatic padding by _Alignas — 32 bytes inserted by compiler)
 *   ---- CACHE LINE BOUNDARY (offset 64) ----
 *    64      head            8      Next write index  [producer writes, consumer reads]
 *    72      cached_tail     8      Producer's local snapshot of tail
 *           (automatic padding by _Alignas — 48 bytes inserted by compiler)
 *   ---- CACHE LINE BOUNDARY (offset 128) ----
 *   128      tail            8      Next read index   [consumer writes, producer reads]
 *   136      cached_head     8      Consumer's local snapshot of head
 *           (automatic tail padding — 48 bytes for sizeof to be multiple of 64)
 *   ---- END (offset 192) ----
 */
typedef struct {
    void        *buffer;                    /* +0:   element storage          */
    uint64_t     capacity;                  /* +8:   number of slots          */
    uint64_t     mask;                      /* +16:  capacity - 1             */
    uint64_t     element_size;              /* +24:  bytes per element        */

    _Alignas(SPSC_CACHELINE_SIZE)
    uint64_t     head;                      /* +64:  next write position      */
    uint64_t     cached_tail;               /* +72:  snapshot of consumer tail*/

    _Alignas(SPSC_CACHELINE_SIZE)
    uint64_t     tail;                      /* +128: next read position       */
    uint64_t     cached_head;               /* +136: snapshot of producer head*/
} spsc_ring_buffer_t;

/*
 * Verify struct size at compile time.
 * If this fires, the struct layout doesn't match the assembly offsets.
 */
_Static_assert(sizeof(spsc_ring_buffer_t) == 192, "spsc_ring_buffer_t size mismatch — check padding");
_Static_assert(__builtin_offsetof(spsc_ring_buffer_t, head) == 64, "head must be at offset 64");
_Static_assert(__builtin_offsetof(spsc_ring_buffer_t, tail) == 128, "tail must be at offset 128");

#ifdef __cplusplus
extern "C" {
#endif

/*
 * spsc_init - Initialize the ring buffer.
 *
 * @rb:           Pointer to the ring buffer struct (must be 64-byte aligned).
 * @buffer:       Pointer to pre-allocated storage for elements.
 *                Must hold at least (capacity * element_size) bytes.
 *                Should be naturally aligned for the element type.
 * @capacity:     Number of slots. MUST be a power of 2.
 * @element_size: Size of each element in bytes.
 *
 * Must be called before any thread calls spsc_push() or spsc_pop().
 * Not thread-safe with respect to push/pop.
 */
void spsc_init(spsc_ring_buffer_t* rb, void* buffer, uint64_t capacity, uint64_t element_size);

/*
 * spsc_push - Enqueue one element (PRODUCER THREAD ONLY).
 *
 * @rb:      Pointer to the ring buffer struct.
 * @element: Pointer to the element to copy into the buffer.
 *           Must point to at least `element_size` readable bytes.
 *
 * Returns:  0 on success, 1 if the buffer is full.
 *
 * Memory ordering:
 *   The element data is written with plain stores, then head is updated
 *   with a store-release (STLR). This guarantees the consumer sees the
 *   element data before it sees the updated head.
 */
int spsc_push(spsc_ring_buffer_t* rb, const void* element);

/*
 * spsc_pop — Dequeue one element (CONSUMER THREAD ONLY).
 *
 * @rb:      Pointer to the ring buffer struct.
 * @element: Pointer to destination buffer where the dequeued element
 *           will be copied. Must have space for `element_size` bytes.
 *
 * Returns:  0 on success, 1 if the buffer is empty.
 *
 * Memory ordering:
 *   Head is read with a load-acquire (LDAR), ensuring we see all data
 *   the producer wrote before updating head. After copying, tail is
 *   updated with a store-release (STLR) to signal the slot is free.
 */
int spsc_pop(spsc_ring_buffer_t* rb, void* element);

#ifdef __cplusplus
}
#endif

#endif /* SPSC_RING_BUFFER_H */

