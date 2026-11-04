/// native_pool_internal.h — Private layout of `native_pool_t` /
/// `native_conn_t`, shared between `native_pool.c` and
/// `native_pool_worker.c`. NOT exposed via the public ABI; nothing
/// outside `native/c/src/` should include this file.

#ifndef NATIVE_POOL_INTERNAL_H
#define NATIVE_POOL_INTERNAL_H

#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <libpq-fe.h>

#include "native_pool.h"

/// FIFO node holding one `PGresult*` pre-drained by the worker for the
/// multi-read path (ABI MINOR 2). The worker drains ALL results of a
/// multi-statement submit into this chain BEFORE posting the OK
/// notification, so the Dart side never blocks on `PQgetResult` while
/// polling — the non-blocking invariant of the vertical contract.
typedef struct pg_result_node {
    PGresult* result;
    struct pg_result_node* next;
} pg_result_node_t;

/// Per-connection state. Owns the libpq handle, the worker thread,
/// and a single-slot mailbox the worker drains.
struct native_conn {
    PGconn* pg;                    // libpq handle (owned)
    struct native_pool* pool;      // back-pointer for shutdown reads
    int32_t index;                 // position in pool->conns[]

    // ── Free-list state (protected by pool->mutex) ──
    int32_t in_use;                // 0 = free, 1 = checked out

    // ── Worker mailbox (protected by slot_mutex) ──
    pthread_t worker;
    pthread_mutex_t slot_mutex;
    pthread_cond_t  slot_cond;     // worker waits here; submit signals

    // Slot payload — valid iff slot_filled == 1.
    int slot_filled;
    int is_pipeline;               // 0 = single query, 1 = pipeline
    int is_params;                 // ABI MINOR 1: 1 = use PQsendQueryParams
    int is_multi_read;             // ABI MINOR 2: 1 = multi-statement, chain results
    int32_t n_prefix;              // ABI MINOR 5/6: > 0 = sql[0..n_prefix-1] prefixes
                                   // + sql[n_prefix] params query
    char** sql;                    // heap-allocated copy; sql[0..count-1]
    int32_t sql_count;             // 1 for single query, N for pipeline/multi-read,
                                   // n_prefix + 1 for prefixed (prefixes, query)

    // ABI MINOR 1 — Extended Protocol payload (valid iff is_params == 1).
    // Mutually exclusive with is_pipeline. ABI MINOR 5 adds the one
    // pipelined form with params: `n_prefix > 0`, where the bindings
    // belong to sql[n_prefix] and the sql[0..n_prefix-1] are
    // parameterless prefixes (ABI MINOR 6 lifts the limit of one).
    int32_t n_params;
    int32_t* param_types;          // owned, length n_params (0 = let server infer)
    char** param_values;           // owned, length n_params (each value owned)
    int* param_lengths;            // owned, length n_params (bytes; ignored for text)
    int* param_formats;            // owned, length n_params (0 = text, 1 = binary)
    int result_format;             // 0 = text (default), 1 = binary

    int64_t port_id;
    int64_t timeout_ms;

    // ── Multi-read result chain (ABI MINOR 2) ──
    // Populated by the worker's `execute_multi_read` before it posts OK;
    // drained by `poll_result` on the Dart isolate thread. Only one of
    // the two threads touches it at a time (the worker before the post,
    // Dart after receiving the post), so no dedicated lock is required.
    // Freed on `pool_release`/teardown to survive an abandoned drain.
    pg_result_node_t* chain_head;
    pg_result_node_t* chain_tail;

    // ── Shutdown flag (atomic; read in worker loop) ──
    _Atomic int shutdown_requested;

    // ── Link health (ABI MINOR 3) ──
    // Written by the worker after it classifies a failure, and read by
    // `pool_acquire` under `pool->mutex` to prefer a live slot. Atomic
    // because the two live on different threads and the read is done
    // without `slot_mutex`.
    //
    // Why a preference and not a skip: skipping outright would shrink
    // the pool permanently the first time the server blinks, which is
    // the very case this feature exists for. `pool_acquire` hands out a
    // convalescing slot only when no healthy one is free, and the
    // worker re-attempts the reset before executing on it.
    _Atomic int health;                // CONN_HEALTH_*
};

/// Values of `native_conn.health`.
///   OK       — link believed live.
///   LOST     — `PQstatus == CONNECTION_BAD` was observed and the reset
///              has not (yet) succeeded. The slot still belongs to the
///              pool and is still released normally; it is simply the
///              last choice of `pool_acquire`, and the worker retries
///              the reset before executing anything on it.
#define CONN_HEALTH_OK   0
#define CONN_HEALTH_LOST 1

/// Attempts a non-blocking reconnect of `conn->pg`, driven by the same
/// `select()` discipline the worker already uses for queries, so the
/// shutdown budget promised by `pool_destroy` still holds.
///
/// Returns 1 on success (health reset to OK), 0 otherwise.
/// Defined in `native_pool_worker.c`; only the worker may call it. The
/// worker owns `conn->pg` while an operation is in flight (libpq §32.21);
/// between operations `poll_result` reads it from the caller's thread.
int native_pool_worker_reset(native_conn_t* conn);

/// Pool state. Owns the connection array, the global free-list
/// mutex/condvar, and the default acquire deadline.
struct native_pool {
    char* conninfo;                // owned copy (free in destroy)
    int32_t max_size;
    int64_t default_acquire_timeout_ms;

    struct native_conn* conns;     // contiguous array, length = max_size
    pthread_mutex_t mutex;         // protects in_use scans
    pthread_cond_t  free_cond;     // signaled by release

    _Atomic int shutting_down;     // 1 = pool_destroy in progress
};

/// Worker thread entry point. Defined in `native_pool_worker.c`.
/// The `arg` is the `native_conn_t*` whose `pg` field this worker
/// services.
void* native_pool_worker_main(void* arg);

/// Frees the slot payload (sql[] entries + array) and resets the
/// scalar fields. Caller MUST hold `conn->slot_mutex` OR be the
/// teardown path where the worker is already joined. Safe on an
/// already-empty slot.
void native_pool_free_slot_payload(native_conn_t* conn);

/// Frees every remaining node of the multi-read result chain
/// (`PQclear` on each `PGresult` + `free` on the node) and resets
/// `chain_head`/`chain_tail` to NULL. Called when a drain is
/// abandoned (Dart polled fewer than N), on `pool_release`, and on
/// teardown. Safe on an empty chain. Defined in `native_pool.c`;
/// declared here so the worker can reset a stale chain before a new
/// multi-read.
void native_pool_free_result_chain(native_conn_t* conn);

/// Appends `result` to the connection's multi-read chain (FIFO).
/// Called only by the worker inside `execute_multi_read`, before the
/// OK post. Returns 0 on OOM (the caller aborts the multi-read).
int native_pool_chain_append(native_conn_t* conn, PGresult* result);

#endif /* NATIVE_POOL_INTERNAL_H */
