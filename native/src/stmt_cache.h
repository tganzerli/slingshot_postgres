/// stmt_cache.h — Per-connection LRU of server-side prepared statements
/// (ABI MINOR 7). Private to the library: not part of the public ABI and
/// not listed in exports.txt.
///
/// One cache lives inside each `native_conn` and is touched ONLY by that
/// connection's worker thread, so it needs no lock. It mirrors the
/// statements the worker prepared on the current server session: every
/// entry was confirmed by a `PGRES_COMMAND_OK` Prepare, and the whole
/// cache is dropped whenever the session is (see
/// `native_pool_worker_reset`).
///
/// Key: the SQL text plus the parameter type OIDs, because a prepared
/// statement fixes the parameter types at Prepare time. Value: the
/// statement name, `_ss<n>`, where `n` is a per-connection 64-bit counter
/// that never repeats, not even across reconnects.
///
/// Evicted names are not forgotten: they go to a bounded "pending close"
/// queue that the worker flushes on a later job (Close or DEALLOCATE),
/// so the session does not keep statements without bound.

#ifndef STMT_CACHE_H
#define STMT_CACHE_H

#include <stdint.h>

/// `_ss` + up to 20 decimal digits + NUL.
#define STMT_NAME_LEN 24

typedef struct stmt_entry {
    uint64_t hash;
    char* sql;                      // owned copy (key)
    int32_t n_params;               // key
    int32_t* types;                 // owned copy, length n_params (key)
    char name[STMT_NAME_LEN];
    struct stmt_entry* prev;        // LRU list: head = most recently used
    struct stmt_entry* next;
    struct stmt_entry* hnext;       // hash bucket chain
} stmt_entry_t;

typedef struct stmt_cache {
    stmt_entry_t** buckets;         // power-of-two count, >= 2 * capacity
    int32_t n_buckets;
    stmt_entry_t* head;
    stmt_entry_t* tail;
    int32_t count;
    int32_t capacity;               // 0 = disabled
    uint64_t next_id;               // never reset

    char (*pending)[STMT_NAME_LEN]; // names awaiting Close/DEALLOCATE (FIFO)
    int32_t n_pending;
    int32_t pending_cap;
} stmt_cache_t;

/// Zero-initialises `c` (capacity 0, nothing allocated).
void stmt_cache_init(stmt_cache_t* c);

/// Frees every entry, the buckets and the pending queue.
void stmt_cache_free(stmt_cache_t* c);

/// The server session is gone (reconnect): drops every entry and every
/// pending name without closing anything. Keeps the capacity and the
/// name counter.
void stmt_cache_clear(stmt_cache_t* c);

/// Applies a new capacity. Shrinking evicts least-recently-used entries
/// into the pending queue; 0 evicts everything. Returns 1 on success,
/// 0 on allocation failure (the cache is then left disabled and empty,
/// its names queued for close).
int stmt_cache_set_capacity(stmt_cache_t* c, int32_t capacity);

/// Looks the key up; on a hit moves the entry to the front and returns
/// it, otherwise NULL.
stmt_entry_t* stmt_cache_lookup(stmt_cache_t* c, const char* sql,
                                int32_t n_params, const int32_t* types);

/// Writes the next unused statement name into `out`.
void stmt_cache_next_name(stmt_cache_t* c, char out[STMT_NAME_LEN]);

/// Inserts a confirmed statement at the front, evicting the LRU entry
/// into the pending queue when full. Returns 1 on success; 0 when the
/// cache is disabled or on allocation failure, in which case `name` is
/// queued for close so the server statement is not leaked.
int stmt_cache_insert(stmt_cache_t* c, const char* sql, int32_t n_params,
                      const int32_t* types, const char* name);

/// Removes `e` (a stale entry). With `queue_close`, its name is queued for
/// close (the statement is still on the server); without, it is dropped
/// (the server reported it missing, so nothing is left to close).
void stmt_cache_remove(stmt_cache_t* c, stmt_entry_t* e, int queue_close);

/// Whether `e` is still an entry of `c` (it may have been removed since it
/// was looked up).
int stmt_cache_contains(const stmt_cache_t* c, const stmt_entry_t* e);

/// Queues `name` for close. When the queue is full the oldest name is
/// dropped: that statement stays on the server until the session ends.
void stmt_cache_queue_close(stmt_cache_t* c, const char* name);

/// Empties the pending queue (after the worker queued every name on the
/// wire).
void stmt_cache_pending_clear(stmt_cache_t* c);

#endif /* STMT_CACHE_H */
