/// native_pool.c — Lifecycle and dispatch primitives for the native
/// thread/conn pool.

#include "native_pool.h"
#include "native_db.h"
#include "native_pool_internal.h"

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <libpq-fe.h>

// ─────────────────────────────────────────────────────────────────
// Internal helpers
// ─────────────────────────────────────────────────────────────────

// Builds an absolute CLOCK_REALTIME deadline `now + delta_ms`.
static void deadline_from_ms(struct timespec* ts, int64_t delta_ms) {
    clock_gettime(CLOCK_REALTIME, ts);
    ts->tv_sec  += delta_ms / 1000;
    ts->tv_nsec += (delta_ms % 1000) * 1000000L;
    if (ts->tv_nsec >= 1000000000L) {
        ts->tv_sec  += 1;
        ts->tv_nsec -= 1000000000L;
    }
}

// Heap-duplicates a C string. Returns NULL if `s` is NULL or on OOM.
static char* dup_string(const char* s) {
    if (s == NULL) return NULL;
    size_t n = strlen(s) + 1;
    char* out = (char*)malloc(n);
    if (out == NULL) return NULL;
    memcpy(out, s, n);
    return out;
}

// Frees a heap vector of strings, skipping NULL entries. Unwinds a
// partially filled vector on allocation failure.
static void free_sql_vec(char** vec, int32_t count) {
    if (vec == NULL) return;
    for (int32_t i = 0; i < count; i++) free(vec[i]);
    free(vec);
}

// Frees the slot payload (sql array + each entry + Extended Protocol
// params if any). Safe on NULL fields. Exposed via
// `native_pool_internal.h` so the worker can release the payload
// after dispatching to libpq.
void native_pool_free_slot_payload(native_conn_t* conn) {
    if (conn->sql != NULL) {
        for (int32_t i = 0; i < conn->sql_count; i++) {
            free(conn->sql[i]);
        }
        free(conn->sql);
        conn->sql = NULL;
    }
    conn->sql_count = 0;
    conn->is_pipeline = 0;

    // ABI MINOR 1 — Extended Protocol payload.
    if (conn->param_values != NULL) {
        for (int32_t i = 0; i < conn->n_params; i++) {
            free(conn->param_values[i]);
        }
        free(conn->param_values);
        conn->param_values = NULL;
    }
    free(conn->param_types);    conn->param_types = NULL;
    free(conn->param_lengths);  conn->param_lengths = NULL;
    free(conn->param_formats);  conn->param_formats = NULL;
    conn->n_params = 0;
    conn->is_params = 0;
    conn->is_multi_read = 0;
    conn->is_cached = 0;
    conn->n_prefix = 0;
    conn->result_format = 0;

    conn->port_id = 0;
    conn->timeout_ms = 0;
}

// ── Multi-read result chain (ABI MINOR 2) ──
//
// The chain lives on native_conn_t and is deliberately independent of
// the slot payload: the worker fills it during `execute_multi_read`
// and then clears the slot (via native_pool_free_slot_payload) BEFORE
// posting OK, but the chain must survive that clear so the Dart side
// can drain it after the notification.

void native_pool_free_result_chain(native_conn_t* conn) {
    pg_result_node_t* node = conn->chain_head;
    while (node != NULL) {
        pg_result_node_t* next = node->next;
        if (node->result != NULL) PQclear(node->result);
        free(node);
        node = next;
    }
    conn->chain_head = NULL;
    conn->chain_tail = NULL;
}

int native_pool_chain_append(native_conn_t* conn, PGresult* result) {
    pg_result_node_t* node =
        (pg_result_node_t*)malloc(sizeof(pg_result_node_t));
    if (node == NULL) return 0;
    node->result = result;
    node->next = NULL;
    if (conn->chain_tail == NULL) {
        conn->chain_head = node;
        conn->chain_tail = node;
    } else {
        conn->chain_tail->next = node;
        conn->chain_tail = node;
    }
    return 1;
}

// Initializes a single native_conn_t entry. Opens the PGconn, sets
// up mutex/condvar and starts the worker thread. Returns 0 on
// success, -1 on failure (partial state cleaned up before return).
static int init_conn(native_conn_t* conn,
                     struct native_pool* pool,
                     int32_t index,
                     const char* conninfo,
                     char* err_buf,
                     int32_t err_len) {
    conn->pool = pool;
    conn->index = index;
    conn->in_use = 0;
    conn->slot_filled = 0;
    conn->is_pipeline = 0;
    conn->is_params = 0;
    conn->is_multi_read = 0;
    conn->is_cached = 0;
    conn->n_prefix = 0;
    conn->sql = NULL;
    conn->sql_count = 0;
    conn->n_params = 0;
    conn->param_types = NULL;
    conn->param_values = NULL;
    conn->param_lengths = NULL;
    conn->param_formats = NULL;
    conn->result_format = 0;
    conn->port_id = 0;
    conn->timeout_ms = 0;
    conn->chain_head = NULL;
    conn->chain_tail = NULL;
    atomic_init(&conn->shutdown_requested, 0);
    atomic_init(&conn->health, CONN_HEALTH_OK);
    stmt_cache_init(&conn->stmts);

    conn->pg = PQconnectdb(conninfo);
    if (PQstatus(conn->pg) != CONNECTION_OK) {
        // ABI MINOR 4: the libpq message goes to the caller's buffer when
        // there is one (pool_create_with_error), to stderr otherwise.
        if (err_buf != NULL && err_len > 0) {
            snprintf(err_buf, (size_t)err_len, "%s", PQerrorMessage(conn->pg));
        } else {
            fprintf(stderr, "pool_create: PQconnectdb failed (conn %d): %s\n",
                    index, PQerrorMessage(conn->pg));
        }
        PQfinish(conn->pg);
        conn->pg = NULL;
        return -1;
    }
    PQsetnonblocking(conn->pg, 1);

    if (pthread_mutex_init(&conn->slot_mutex, NULL) != 0) {
        PQfinish(conn->pg);
        conn->pg = NULL;
        return -1;
    }
    if (pthread_cond_init(&conn->slot_cond, NULL) != 0) {
        pthread_mutex_destroy(&conn->slot_mutex);
        PQfinish(conn->pg);
        conn->pg = NULL;
        return -1;
    }

    if (pthread_create(&conn->worker, NULL,
                       native_pool_worker_main, conn) != 0) {
        pthread_cond_destroy(&conn->slot_cond);
        pthread_mutex_destroy(&conn->slot_mutex);
        PQfinish(conn->pg);
        conn->pg = NULL;
        return -1;
    }

    return 0;
}

// Joins the worker and frees per-conn resources. The caller must
// have set conn->shutdown_requested = 1 and signaled slot_cond.
static void teardown_conn(native_conn_t* conn) {
    if (conn->pg == NULL) return;  // never initialised — nothing to do
    pthread_join(conn->worker, NULL);
    native_pool_free_slot_payload(conn);
    native_pool_free_result_chain(conn);
    stmt_cache_free(&conn->stmts);
    pthread_cond_destroy(&conn->slot_cond);
    pthread_mutex_destroy(&conn->slot_mutex);
    PQfinish(conn->pg);
    conn->pg = NULL;
}

// ─────────────────────────────────────────────────────────────────
// Public API — pool lifecycle
// ─────────────────────────────────────────────────────────────────

native_pool_t* pool_create(const char* conninfo,
                           int32_t min_size,
                           int32_t max_size,
                           int64_t acquire_timeout_ms) {
    return pool_create_with_error(conninfo, min_size, max_size,
                                  acquire_timeout_ms, NULL, 0);
}

native_pool_t* pool_create_with_error(const char* conninfo,
                           int32_t min_size,
                           int32_t max_size,
                           int64_t acquire_timeout_ms,
                           char* err_buf,
                           int32_t err_len) {
    (void)min_size;  // reserved for future warm-up policy
    if (err_buf != NULL && err_len > 0) err_buf[0] = '\0';

    if (conninfo == NULL || max_size < 1) {
        if (err_buf != NULL && err_len > 0) {
            snprintf(err_buf, (size_t)err_len, "invalid arguments");
        } else {
            fprintf(stderr, "pool_create: invalid arguments\n");
        }
        return NULL;
    }

    native_pool_t* pool = (native_pool_t*)calloc(1, sizeof(*pool));
    if (pool == NULL) return NULL;

    pool->conninfo = dup_string(conninfo);
    pool->max_size = max_size;
    pool->default_acquire_timeout_ms = acquire_timeout_ms;
    atomic_init(&pool->shutting_down, 0);
    atomic_init(&pool->stmt_capacity, 0);

    if (pool->conninfo == NULL ||
        pthread_mutex_init(&pool->mutex, NULL) != 0) {
        free(pool->conninfo);
        free(pool);
        return NULL;
    }
    if (pthread_cond_init(&pool->free_cond, NULL) != 0) {
        pthread_mutex_destroy(&pool->mutex);
        free(pool->conninfo);
        free(pool);
        return NULL;
    }

    pool->conns = (native_conn_t*)calloc((size_t)max_size, sizeof(*pool->conns));
    if (pool->conns == NULL) {
        pthread_cond_destroy(&pool->free_cond);
        pthread_mutex_destroy(&pool->mutex);
        free(pool->conninfo);
        free(pool);
        return NULL;
    }

    // Bring up each conn + worker. On the first failure, roll back
    // all previously-initialised conns and return NULL.
    for (int32_t i = 0; i < max_size; i++) {
        if (init_conn(&pool->conns[i], pool, i, conninfo, err_buf, err_len) != 0) {
            for (int32_t j = 0; j < i; j++) {
                atomic_store(&pool->conns[j].shutdown_requested, 1);
                pthread_mutex_lock(&pool->conns[j].slot_mutex);
                pthread_cond_signal(&pool->conns[j].slot_cond);
                pthread_mutex_unlock(&pool->conns[j].slot_mutex);
                teardown_conn(&pool->conns[j]);
            }
            free(pool->conns);
            pthread_cond_destroy(&pool->free_cond);
            pthread_mutex_destroy(&pool->mutex);
            free(pool->conninfo);
            free(pool);
            return NULL;
        }
    }

    return pool;
}

void pool_destroy(native_pool_t* pool) {
    if (pool == NULL) return;

    atomic_store(&pool->shutting_down, 1);

    // Signal every worker so it observes the shutdown flag, and
    // send a libpq cancel to short-circuit any in-flight query that
    // would otherwise wait for the worker's 1s shutdown-poll tick.
    for (int32_t i = 0; i < pool->max_size; i++) {
        native_conn_t* c = &pool->conns[i];
        atomic_store(&c->shutdown_requested, 1);
        pool_cancel(c);
        pthread_mutex_lock(&c->slot_mutex);
        pthread_cond_signal(&c->slot_cond);
        pthread_mutex_unlock(&c->slot_mutex);
    }

    // Join + close each conn. pthread_join may block if a worker is
    // mid-query; that is bounded by the query's `timeout_ms` plus the
    // shutdown check in the worker's select() loop.
    for (int32_t i = 0; i < pool->max_size; i++) {
        teardown_conn(&pool->conns[i]);
    }

    // Wake any threads still blocked on free_cond (should be none —
    // Dart side must release before destroy, but defensive cleanup).
    pthread_mutex_lock(&pool->mutex);
    pthread_cond_broadcast(&pool->free_cond);
    pthread_mutex_unlock(&pool->mutex);

    free(pool->conns);
    pthread_cond_destroy(&pool->free_cond);
    pthread_mutex_destroy(&pool->mutex);
    free(pool->conninfo);
    free(pool);
}

// ─────────────────────────────────────────────────────────────────
// Public API — acquire / release
// ─────────────────────────────────────────────────────────────────

native_conn_t* pool_acquire(native_pool_t* pool, int64_t timeout_ms) {
    if (pool == NULL) return NULL;
    if (atomic_load(&pool->shutting_down)) return NULL;

    // Resolve effective timeout.
    //   timeout_ms == 0  → use pool default. If default is also 0,
    //                      treat as non-blocking probe.
    //   timeout_ms  < 0  → wait forever.
    //   timeout_ms  > 0  → wait up to that many ms.
    int64_t effective_ms = timeout_ms;
    if (effective_ms == 0) effective_ms = pool->default_acquire_timeout_ms;

    struct timespec deadline;
    int use_deadline = (effective_ms > 0);
    if (use_deadline) deadline_from_ms(&deadline, effective_ms);

    pthread_mutex_lock(&pool->mutex);

    while (1) {
        if (atomic_load(&pool->shutting_down)) {
            pthread_mutex_unlock(&pool->mutex);
            return NULL;
        }

        // Linear scan for a free conn. O(N); N ≤ a few dozen.
        //
        // ABI MINOR 3 — two passes, not one. A slot whose link was
        // observed dead (`CONN_HEALTH_LOST`) is the LAST choice, never
        // an excluded one:
        //
        //   * Excluding it outright would shrink the pool permanently
        //     the first time the server blinks. Momentary
        //     unavailability is precisely the case this feature exists
        //     for, so a design that survives one outage and then runs
        //     with fewer conns forever fails the actual requirement.
        //   * Preferring a healthy slot keeps the cost of a blink off
        //     the latency of callers that have a live conn available.
        //
        // The convalescing slot is not handed out raw: the worker
        // re-attempts `native_pool_worker_reset` before executing
        // anything on it, and posts WORKER_PORT_CONN_LOST without
        // running the query if the link is still down.
        int32_t fallback = -1;
        for (int32_t i = 0; i < pool->max_size; i++) {
            if (pool->conns[i].in_use != 0) continue;
            if (atomic_load(&pool->conns[i].health) == CONN_HEALTH_OK) {
                pool->conns[i].in_use = 1;
                pthread_mutex_unlock(&pool->mutex);
                return &pool->conns[i];
            }
            if (fallback < 0) fallback = i;
        }
        if (fallback >= 0) {
            pool->conns[fallback].in_use = 1;
            pthread_mutex_unlock(&pool->mutex);
            return &pool->conns[fallback];
        }

        // Nothing free. Block until release signals us, or timeout.
        if (effective_ms == 0) {
            pthread_mutex_unlock(&pool->mutex);
            return NULL;  // non-blocking probe
        }

        int rc;
        if (use_deadline) {
            rc = pthread_cond_timedwait(&pool->free_cond,
                                        &pool->mutex, &deadline);
        } else {
            rc = pthread_cond_wait(&pool->free_cond, &pool->mutex);
        }
        if (rc == ETIMEDOUT) {
            pthread_mutex_unlock(&pool->mutex);
            return NULL;
        }
        // Spurious wakeup or signal — loop and rescan.
    }
}

void pool_release(native_pool_t* pool, native_conn_t* conn) {
    if (pool == NULL || conn == NULL) return;

    // Free any multi-read results the Dart side did not drain (e.g. it
    // stopped early on an error PGresult). The worker is idle by the
    // time a conn is released, so touching the chain here is race-free.
    native_pool_free_result_chain(conn);

    // ABI MINOR 3: a slot with `CONN_HEALTH_LOST` IS returned to the
    // free-list. Withholding it would leak a slot per outage and shrink
    // the pool to nothing under a server that restarts; `pool_acquire`
    // deprioritises it instead, and the worker retries the reset. The
    // health flag is deliberately NOT cleared here — only a successful
    // `native_pool_worker_reset` clears it, from the worker thread that
    // owns `conn->pg`.

    pthread_mutex_lock(&pool->mutex);
    conn->in_use = 0;
    pthread_cond_signal(&pool->free_cond);
    pthread_mutex_unlock(&pool->mutex);
}

// ─────────────────────────────────────────────────────────────────
// Public API — submit (single query + pipeline)
// ─────────────────────────────────────────────────────────────────

// Shared body for both submit variants. `queries` is borrowed; the
// strings are copied into heap-owned storage.
static int submit_locked(native_conn_t* conn,
                         int is_pipeline,
                         int is_multi_read,
                         const char* const* queries,
                         int32_t count,
                         int64_t port_id,
                         int64_t timeout_ms) {
    if (conn == NULL || queries == NULL || count <= 0) return 0;

    pthread_mutex_lock(&conn->slot_mutex);

    if (conn->slot_filled || atomic_load(&conn->shutdown_requested)) {
        pthread_mutex_unlock(&conn->slot_mutex);
        return 0;
    }

    // Allocate the sql vector up-front. Roll back on any malloc fail.
    char** sql_copies = (char**)calloc((size_t)count, sizeof(char*));
    if (sql_copies == NULL) {
        pthread_mutex_unlock(&conn->slot_mutex);
        return 0;
    }
    for (int32_t i = 0; i < count; i++) {
        sql_copies[i] = dup_string(queries[i]);
        if (sql_copies[i] == NULL) {
            for (int32_t j = 0; j < i; j++) free(sql_copies[j]);
            free(sql_copies);
            pthread_mutex_unlock(&conn->slot_mutex);
            return 0;
        }
    }

    conn->slot_filled = 1;
    conn->is_pipeline = is_pipeline;
    conn->is_multi_read = is_multi_read;
    conn->sql = sql_copies;
    conn->sql_count = count;
    conn->port_id = port_id;
    conn->timeout_ms = timeout_ms;

    pthread_cond_signal(&conn->slot_cond);
    pthread_mutex_unlock(&conn->slot_mutex);
    return 1;
}

int pool_submit_query(native_conn_t* conn,
                      const char* sql,
                      int64_t port_id,
                      int64_t timeout_ms) {
    const char* one[1] = { sql };
    return submit_locked(conn, 0, 0, one, 1, port_id, timeout_ms);
}

int pool_submit_pipeline(native_conn_t* conn,
                         const char* const* queries,
                         int32_t query_count,
                         int64_t port_id,
                         int64_t timeout_ms) {
    return submit_locked(conn, 1, 0, queries, query_count, port_id, timeout_ms);
}

int pool_submit_multi_read(native_conn_t* conn,
                           const char* const* queries,
                           int32_t query_count,
                           int64_t port_id,
                           int64_t timeout_ms) {
    return submit_locked(conn, 0, 1, queries, query_count, port_id, timeout_ms);
}

// ABI MINOR 1 — Extended Query Protocol single-statement dispatch.
// Mirrors `submit_locked` shape but ferries the params payload in
// addition to the SQL string. On any allocation failure mid-way we
// roll back everything allocated so far and return 0 — the caller
// can treat that identically to "slot occupied".
//
// ABI MINOR 5/6: shared by `pool_submit_query_params` (n_prefix 0),
// `pool_submit_query_params_prefixed` (n_prefix 1) and
// `pool_submit_query_params_prefixed_n`, which store the prefixes as
// sql[0..n_prefix-1] and the query as sql[n_prefix].
static int submit_params_locked(native_conn_t* conn,
                                int cached,
                                const char* const* prefix_sqls,
                                int32_t n_prefix,
                                const char* sql,
                                int32_t n_params,
                                const int32_t* param_types,
                                const char* const* param_values,
                                const int* param_lengths,
                                const int* param_formats,
                                int result_format,
                                int64_t port_id,
                                int64_t timeout_ms) {
    if (conn == NULL || sql == NULL) return 0;
    if (n_params < 0 || n_prefix < 0) return 0;
    if (n_prefix > 0 && prefix_sqls == NULL) return 0;
    for (int32_t i = 0; i < n_prefix; i++) {
        if (prefix_sqls[i] == NULL) return 0;
    }
    if (n_params > 0 && (param_values == NULL || param_lengths == NULL
                         || param_formats == NULL)) {
        // Caller must supply value/length/format arrays whenever
        // n_params > 0; types may be NULL (server inference).
        return 0;
    }

    pthread_mutex_lock(&conn->slot_mutex);

    if (conn->slot_filled || atomic_load(&conn->shutdown_requested)) {
        pthread_mutex_unlock(&conn->slot_mutex);
        return 0;
    }

    // Dup the prefixes and the SQL: sql_vec = {prefix_0, ..., query}.
    // free_sql_vec releases every non-NULL entry, so a partial dup
    // unwinds with the same call.
    int32_t sql_count = n_prefix + 1;
    char** sql_vec = (char**)calloc((size_t)sql_count, sizeof(char*));
    int dup_ok = (sql_vec != NULL);
    for (int32_t i = 0; dup_ok && i < n_prefix; i++) {
        sql_vec[i] = dup_string(prefix_sqls[i]);
        dup_ok = (sql_vec[i] != NULL);
    }
    if (dup_ok) {
        sql_vec[n_prefix] = dup_string(sql);
        dup_ok = (sql_vec[n_prefix] != NULL);
    }
    if (!dup_ok) {
        free_sql_vec(sql_vec, sql_count);
        pthread_mutex_unlock(&conn->slot_mutex);
        return 0;
    }

    // Dup the params. We dup each value buffer so the Dart side can
    // free its FFI-allocated buffers immediately after the call
    // returns, mirroring how `dup_string(sql)` decouples lifetimes.
    int32_t* types_copy   = NULL;
    char**   values_copy  = NULL;
    int*     lengths_copy = NULL;
    int*     formats_copy = NULL;

    if (n_params > 0) {
        // Types: array of Oids, NULL is acceptable (server inference);
        // but we always allocate so worker sees a stable pointer.
        types_copy = (int32_t*)calloc((size_t)n_params, sizeof(int32_t));
        lengths_copy = (int*)calloc((size_t)n_params, sizeof(int));
        formats_copy = (int*)calloc((size_t)n_params, sizeof(int));
        values_copy = (char**)calloc((size_t)n_params, sizeof(char*));
        if (types_copy == NULL || lengths_copy == NULL
            || formats_copy == NULL || values_copy == NULL) {
            free(types_copy); free(lengths_copy);
            free(formats_copy); free(values_copy);
            free_sql_vec(sql_vec, sql_count);
            pthread_mutex_unlock(&conn->slot_mutex);
            return 0;
        }
        if (param_types != NULL) {
            memcpy(types_copy, param_types,
                   (size_t)n_params * sizeof(int32_t));
        }
        memcpy(lengths_copy, param_lengths,
               (size_t)n_params * sizeof(int));
        memcpy(formats_copy, param_formats,
               (size_t)n_params * sizeof(int));

        // Each value buffer needs to be duped at the appropriate
        // length. Text params come as NUL-terminated UTF-8 (length
        // ignored by libpq for text); binary params come with
        // explicit `param_lengths[i]`. NULL value (SQL NULL) stays
        // NULL in the copy.
        for (int32_t i = 0; i < n_params; i++) {
            if (param_values[i] == NULL) {
                values_copy[i] = NULL;
                continue;
            }
            size_t blen = (formats_copy[i] == 0)
                ? strlen(param_values[i]) + 1     // text: NUL-terminated
                : (size_t)lengths_copy[i];        // binary: explicit
            char* buf = (char*)malloc(blen);
            if (buf == NULL) {
                for (int32_t j = 0; j < i; j++) free(values_copy[j]);
                free(values_copy); free(formats_copy);
                free(lengths_copy); free(types_copy);
                free_sql_vec(sql_vec, sql_count);
                pthread_mutex_unlock(&conn->slot_mutex);
                return 0;
            }
            memcpy(buf, param_values[i], blen);
            values_copy[i] = buf;
        }
    }

    // Commit to the slot.
    conn->slot_filled    = 1;
    conn->is_pipeline    = 0;
    conn->is_params      = 1;
    conn->is_cached      = cached;
    conn->n_prefix       = n_prefix;
    conn->sql            = sql_vec;
    conn->sql_count      = sql_count;
    conn->n_params       = n_params;
    conn->param_types    = types_copy;
    conn->param_values   = values_copy;
    conn->param_lengths  = lengths_copy;
    conn->param_formats  = formats_copy;
    conn->result_format  = result_format;
    conn->port_id        = port_id;
    conn->timeout_ms     = timeout_ms;

    pthread_cond_signal(&conn->slot_cond);
    pthread_mutex_unlock(&conn->slot_mutex);
    return 1;
}

int pool_submit_query_params(native_conn_t* conn,
                             const char* sql,
                             int32_t n_params,
                             const int32_t* param_types,
                             const char* const* param_values,
                             const int* param_lengths,
                             const int* param_formats,
                             int result_format,
                             int64_t port_id,
                             int64_t timeout_ms) {
    return submit_params_locked(conn, 0, NULL, 0, sql, n_params, param_types,
                                param_values, param_lengths, param_formats,
                                result_format, port_id, timeout_ms);
}

// ABI MINOR 5. See `native_pool.h` for the contract.
int pool_submit_query_params_prefixed(native_conn_t* conn,
                                      const char* prefix_sql,
                                      const char* sql,
                                      int32_t n_params,
                                      const int32_t* param_types,
                                      const char* const* param_values,
                                      const int* param_lengths,
                                      const int* param_formats,
                                      int result_format,
                                      int64_t port_id,
                                      int64_t timeout_ms) {
    if (prefix_sql == NULL) return 0;
    const char* prefixes[1] = {prefix_sql};
    return submit_params_locked(conn, 0, prefixes, 1, sql, n_params, param_types,
                                param_values, param_lengths, param_formats,
                                result_format, port_id, timeout_ms);
}

// ABI MINOR 6. See `native_pool.h` for the contract.
int pool_submit_query_params_prefixed_n(native_conn_t* conn,
                                        const char* const* prefix_sqls,
                                        int32_t n_prefix,
                                        const char* sql,
                                        int32_t n_params,
                                        const int32_t* param_types,
                                        const char* const* param_values,
                                        const int* param_lengths,
                                        const int* param_formats,
                                        int result_format,
                                        int64_t port_id,
                                        int64_t timeout_ms) {
    if (n_prefix < 1) return 0;
    return submit_params_locked(conn, 0, prefix_sqls, n_prefix, sql, n_params,
                                param_types, param_values, param_lengths,
                                param_formats, result_format, port_id,
                                timeout_ms);
}

// ABI MINOR 7. See `native_pool.h` for the contract.
int pool_submit_query_cached(native_conn_t* conn,
                             const char* const* prefix_sqls,
                             int32_t n_prefix,
                             const char* sql,
                             int32_t n_params,
                             const int32_t* param_types,
                             const char* const* param_values,
                             const int* param_lengths,
                             const int* param_formats,
                             int result_format,
                             int64_t port_id,
                             int64_t timeout_ms) {
    return submit_params_locked(conn, 1, prefix_sqls, n_prefix, sql, n_params,
                                param_types, param_values, param_lengths,
                                param_formats, result_format, port_id,
                                timeout_ms);
}

// ABI MINOR 7. See `native_pool.h` for the contract.
void pool_set_statement_cache_capacity(native_pool_t* pool,
                                       int32_t capacity) {
    if (pool == NULL) return;
    if (capacity < 0) capacity = 0;
    atomic_store(&pool->stmt_capacity, capacity);
}

// ABI MINOR 6. See `native_pool.h` for the contract.
int pool_conn_transaction_status(native_conn_t* conn) {
    if (conn == NULL || conn->pg == NULL) return (int)PQTRANS_UNKNOWN;
    return (int)PQtransactionStatus(conn->pg);
}

// ─────────────────────────────────────────────────────────────────
// Public API — cancel + result retrieval
// ─────────────────────────────────────────────────────────────────

void pool_cancel(native_conn_t* conn) {
    if (conn == NULL || conn->pg == NULL) return;
    PGcancel* cancel = PQgetCancel(conn->pg);
    if (cancel != NULL) {
        char errbuf[256];
        PQcancel(cancel, errbuf, sizeof(errbuf));
        PQfreeCancel(cancel);
    }
}

// `poll_result` is declared in `native_db.h` (ABI MAJOR 2 changed
// its first parameter from PGconn* to native_conn_t*). Defined here
// because it needs the private layout.
PGresult* poll_result(native_conn_t* conn) {
    if (conn == NULL || conn->pg == NULL) return NULL;

    // Multi-read (ABI MINOR 2): the worker pre-drained every result
    // into the chain, so dequeue from it first. Only when the chain is
    // empty do we fall through to `PQgetResult` — which for the single
    // path is the original behaviour, and for a fully-drained multi-read
    // returns NULL (the libpq queue was already emptied by the worker).
    if (conn->chain_head != NULL) {
        pg_result_node_t* node = conn->chain_head;
        conn->chain_head = node->next;
        if (conn->chain_head == NULL) conn->chain_tail = NULL;
        PGresult* r = node->result;
        free(node);
        return r;
    }
    return PQgetResult(conn->pg);
}
