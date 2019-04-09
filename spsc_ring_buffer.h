#ifndef SPSC_RING_BUFFER_H
#define SPSC_RING_BUFFER_H

#include <stdint.h>
#include <stddef.h>

#define SPSC_CACHELINE_SIZE 64

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

void spsc_init(spsc_ring_buffer_t* rb, void* buffer, uint64_t capacity, uint64_t element_size);

int spsc_push(spsc_ring_buffer_t* rb, const void* element);

int spsc_pop(spsc_ring_buffer_t* rb, void* element);

#ifdef __cplusplus
}
#endif

#endif /* SPSC_RING_BUFFER_H */

