#ifndef ZARC_ALLOCATOR_H
#define ZARC_ALLOCATOR_H

#include <stddef.h>

/*
 * The only way memory crosses a language boundary in zarc.
 *
 * alloc_fn(size, alignment) -> fresh block or NULL.
 * realloc_fn(ptr, old, new, alignment) -> new ptr or NULL. On NULL the
 *   original block stays valid. ptr may be NULL (acts like alloc).
 * free_fn(ptr, size, alignment) -> releases block. ptr may be NULL.
 *
 * All pointers must be thread-safe. Embedder serializes if not.
 */
typedef struct zarc_allocator {
    void *(*alloc_fn)(void *ctx, size_t size, size_t alignment);
    void *(*realloc_fn)(void *ctx, void *ptr, size_t old_size, size_t new_size, size_t alignment);
    void  (*free_fn)(void *ctx, void *ptr, size_t size, size_t alignment);
    void *ctx;
} zarc_allocator;

#endif