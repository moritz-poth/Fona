// Acquire/release access to a long, for the lock-free single-producer/single-consumer PCM ring
// (Swift's Synchronization module needs macOS 15; Fona targets 14).
#ifndef FONA_ATOMICS_H
#define FONA_ATOMICS_H
static inline long fona_load_acquire(const long *p) { return __atomic_load_n(p, __ATOMIC_ACQUIRE); }
static inline void fona_store_release(long *p, long v) { __atomic_store_n(p, v, __ATOMIC_RELEASE); }
#endif
