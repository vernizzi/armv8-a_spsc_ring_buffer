#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <pthread.h>
#include <assert.h>

#include "spsc_ring_buffer.h"

/*
 * RING_CAPACITY must be a power of 2.
 * Usable slots = RING_CAPACITY - 1 = 15 (one slot is "wasted" to
 * distinguish full from empty without a separate count variable).
 */
#define RING_CAPACITY   16

/*
 * Total number of items the producer will send.
 * The consumer will verify it receives all of them in order.
 */
#define NUM_ITEMS       1000000

static spsc_ring_buffer_t rb;

static uint64_t ring_storage[RING_CAPACITY];

static void* producer_func(void* arg) {
    (void)arg;

    for (uint64_t i = 0; i < NUM_ITEMS; i++) {
        /* try to push, if the buffer is full, spin-retry */
        while (spsc_push(&rb, &i) != 0) {
            /* Buffer full, spin. the consumer will free a slot soon */
        }
    }

    printf("[Producer] Done. Pushed %d items.\n", NUM_ITEMS);
    return NULL;
}

static void* consumer_func(void* arg) {
    (void)arg;
    uint64_t expected = 0;
    uint64_t value;

    while (expected < NUM_ITEMS) {
        /* try to pop. If the buffer is empty, spin-retry */
        if (spsc_pop(&rb, &value) != 0) {
            /* Buffer empty, spin. the producer will push an item soon */
            continue;
        }

        /*
         * Verify ordering.
         * In a correct SPSC implementation, items come out in FIFO order.
         * If the memory barriers are wrong, we might see: out-of-order
         * values (reordered stores), stale/garbage values (missing acquire
         * on consumer side), duplicate values (missing release on producer side)
         */
        if (value != expected) {
            fprintf(stderr, "[Consumer] ERROR: expected %lu, got %lu\n",
                    (unsigned long)expected, (unsigned long)value);
            abort();
        }

        expected++;
    }

    printf("[Consumer] Done. Received and verified %d items in order.\n", NUM_ITEMS);
    return NULL;
}

int main(void) {
    printf("SPSC Ring Buffer Demo\n");
    printf("  Capacity:     %d slots (%d usable)\n",
           RING_CAPACITY, RING_CAPACITY - 1);
    printf("  Element size: %zu bytes (uint64_t)\n", sizeof(uint64_t));
    printf("  Items to transfer: %d\n\n", NUM_ITEMS);

    spsc_init(&rb, ring_storage, RING_CAPACITY, sizeof(uint64_t));

    /*
     * NOTE: spsc_init() must complete BEFORE either thread starts.
     * pthread_create() includes an implicit memory barrier (it calls
     * clone() which is a syscall), so the init writes are visible to
     * both threads
     */
    pthread_t producer_thread, consumer_thread;

    int rc = pthread_create(&producer_thread, NULL, producer_func, NULL);
    if (rc != 0) {
        fprintf(stderr, "Failed to create producer thread: %d\n", rc);
        return 1;
    }

    rc = pthread_create(&consumer_thread, NULL, consumer_func, NULL);
    if (rc != 0) {
        fprintf(stderr, "Failed to create consumer thread: %d\n", rc);
        return 1;
    }

    pthread_join(producer_thread, NULL);
    pthread_join(consumer_thread, NULL);

    printf("\nAll items transferred and verified successfully!\n");
    return 0;
}

