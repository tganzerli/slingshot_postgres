/// native_pool_worker.c — Body of the per-conn worker thread for
/// the pool. One worker is bound to one PGconn for the entire
/// lifetime of the pool. The worker is the ONLY thread that touches
/// `conn->pg` in libpq (satisfies libpq §32.21 thread-safety).
///
/// Reuses the `select() + PQconsumeInput + PQisBusy` pattern from
/// the deprecated `socket_watcher_thread` (now removed in MAJOR 2)
/// but with N=1 socket per worker — eliminates the O(n) fan-out
/// that motivated the refactor.

#include "native_pool.h"
#include "native_pool_internal.h"

#include <errno.h>
#include <stdio.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <time.h>
#include <unistd.h>
#include <libpq-fe.h>

#include "dart/dart_api_dl.h"

// The codes themselves now live in `native_pool.h` as the single
// normative list (ABI MINOR 3). They were spelled out here in prose AND
// there in prose until 2026-09-11, and the two spellings had drifted:
// this file said "the connection state is undefined", the header said
// "treat the conn as suspect and close+reopen".
//
// WORKER_PORT_OK / WORKER_PORT_ABORTED / WORKER_PORT_CONN_LOST come
// from that header via native_pool_internal.h.

// Lower bound for the per-iteration `select()` so that the worker
// observes `shutdown_requested` even on queries dispatched with no
// wall-clock deadline (`timeout_ms == 0`). 1s ≈ a worst-case shutdown
// latency that keeps tests snappy while staying invisible at runtime.
#define WORKER_SHUTDOWN_POLL_MS ((int64_t)1000)

// After a query deadline expires and the worker cancels, how long it keeps
// draining for the server to end the statement before giving the slot up
// for a reset. Shared by every path (cancel_and_drain, the prefixed and the
// cached pipelines).
#define PREFIXED_CANCEL_GRACE_MS ((int64_t)5000)

// ─────────────────────────────────────────────────────────────────
// Time helpers
// ─────────────────────────────────────────────────────────────────

static void compute_deadline(struct timespec* out, int64_t timeout_ms) {
    clock_gettime(CLOCK_REALTIME, out);
    out->tv_sec  += timeout_ms / 1000;
    out->tv_nsec += (timeout_ms % 1000) * 1000000L;
    if (out->tv_nsec >= 1000000000L) {
        out->tv_sec  += 1;
        out->tv_nsec -= 1000000000L;
    }
}

// Returns the number of milliseconds remaining until `deadline`.
// May be negative (deadline already passed).
static int64_t ms_until(const struct timespec* deadline) {
    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    int64_t s_diff  = (int64_t)(deadline->tv_sec - now.tv_sec);
    int64_t ns_diff = (int64_t)(deadline->tv_nsec - now.tv_nsec);
    return s_diff * 1000 + ns_diff / 1000000;
}

// Fills `tv` with the next select() timeout. If `has_deadline` is 0
// the timeout is WORKER_SHUTDOWN_POLL_MS so the worker still wakes
// up to check `shutdown_requested`. Returns 0 if the deadline has
// already expired (caller should treat as timeout).
static int next_select_tv(struct timeval* tv,
                          int has_deadline,
                          const struct timespec* deadline) {
    int64_t budget_ms;
    if (has_deadline) {
        budget_ms = ms_until(deadline);
        if (budget_ms <= 0) return 0;
        if (budget_ms > WORKER_SHUTDOWN_POLL_MS) {
            budget_ms = WORKER_SHUTDOWN_POLL_MS;
        }
    } else {
        budget_ms = WORKER_SHUTDOWN_POLL_MS;
    }
    tv->tv_sec  = (long)(budget_ms / 1000);
    tv->tv_usec = (long)((budget_ms % 1000) * 1000);
    return 1;
}

// Best-effort PQcancel via libpq's thread-safe interface.
static void issue_cancel(PGconn* pg) {
    PGcancel* cancel = PQgetCancel(pg);
    if (cancel != NULL) {
        char errbuf[256];
        PQcancel(cancel, errbuf, sizeof(errbuf));
        PQfreeCancel(cancel);
    }
}

// ─────────────────────────────────────────────────────────────────
// Outgoing-buffer flush
// ─────────────────────────────────────────────────────────────────
//
// Drains the non-blocking conn's send buffer the libpq way. On
// PQflush()==1 the buffer is not yet empty; instead of spinning we
// wait (select) for the socket to become writable. We also watch for
// read-readiness: the server may be sending (e.g. a NOTICE) and libpq
// §"Asynchronous Command Processing" tells us to PQconsumeInput first,
// otherwise the write side can wedge when the peer's buffers fill.
//
// The wait honors the same query deadline and shutdown discipline as
// the result-drain loops below, reusing next_select_tv()/issue_cancel().
// Returns WORKER_PORT_OK once the buffer is fully sent, or
// WORKER_PORT_ABORTED on timeout / shutdown / socket error. For
// timeout and shutdown issue_cancel() has already fired; any
// path-specific cleanup (result chain, pipeline mode) is the caller's
// responsibility.
static int64_t flush_outgoing(native_conn_t* conn,
                              PGconn* pg,
                              int sock,
                              int has_deadline,
                              const struct timespec* deadline) {
    while (1) {
        int f = PQflush(pg);
        if (f == 0) return WORKER_PORT_OK;       // fully sent
        if (f < 0)  return WORKER_PORT_ABORTED;  // write error

        // f == 1: buffer not yet drained — wait, don't spin.
        if (atomic_load(&conn->shutdown_requested)) {
            issue_cancel(pg);
            return WORKER_PORT_ABORTED;
        }

        fd_set rfds, wfds;
        FD_ZERO(&rfds); FD_SET(sock, &rfds);
        FD_ZERO(&wfds); FD_SET(sock, &wfds);

        struct timeval tv;
        if (!next_select_tv(&tv, has_deadline, deadline)) {
            // Wall-clock deadline expired while sending.
            issue_cancel(pg);
            return WORKER_PORT_ABORTED;
        }

        int rc = select(sock + 1, &rfds, &wfds, NULL, &tv);
        if (rc < 0) {
            if (errno == EINTR) continue;
            return WORKER_PORT_ABORTED;
        }
        if (rc == 0) {
            // Shutdown-poll tick or deadline — re-check both at top.
            continue;
        }
        if (FD_ISSET(sock, &rfds)) {
            // Consume server-side bytes so the peer keeps draining our
            // writes; also keeps libpq's input buffer coherent.
            if (PQconsumeInput(pg) == 0) return WORKER_PORT_ABORTED;
        }
        // Writable (or just consumed) — loop and re-try PQflush.
    }
}

// ─────────────────────────────────────────────────────────────────
// Cancel and drain after a deadline (k101)
// ─────────────────────────────────────────────────────────────────
//
// A timed-out statement must cost the statement, not the connection. libpq
// keeps a command in progress until every result of it, the cancel's error
// included, has been consumed; a path that cancelled and returned left
// that behind, every later dispatch on the slot failed, and nothing flagged
// it for reset because PQstatus stayed OK. Called only once the statement
// was fully sent (a deadline hit while waiting for results), it cancels and
// drains every remaining result for up to PREFIXED_CANCEL_GRACE_MS,
// discarding them. A deadline hit while still SENDING never comes here:
// the server would ignore a cancel for a statement it has not finished
// reading, and completing the send would run it after the caller was told
// it timed out. Those paths give the session up instead (see
// worker_classify_failure).
//
// `pipeline_syncs` > 0: the connection is in pipeline mode, where
// PQgetResult returns NULL between statements; drain until that many
// PGRES_PIPELINE_SYNC markers instead.
//
// Returns 1 when libpq is idle again. Otherwise (grace expired, shutdown,
// lost link, a COPY state) it flags the slot CONN_HEALTH_LOST and returns
// 0; worker_classify_failure then reconnects the slot and reports the
// statement as lost, so the caller's transaction is known to be gone.
// `issue_cancel` itself is a blocking PQcancel: with the server
// unreachable it can outlast the grace window.
static int cancel_and_drain(native_conn_t* conn, PGconn* pg, int sock,
                            int pipeline_syncs) {
    struct timespec grace;
    compute_deadline(&grace, PREFIXED_CANCEL_GRACE_MS);
    issue_cancel(pg);
    int syncs = 0;
    while (1) {
        if (atomic_load(&conn->shutdown_requested)) {
            atomic_store(&conn->health, CONN_HEALTH_LOST);
            return 0;
        }
        if (PQisBusy(pg)) {
            fd_set rfds;
            FD_ZERO(&rfds);
            FD_SET(sock, &rfds);
            struct timeval tv;
            if (!next_select_tv(&tv, 1, &grace)) {
                atomic_store(&conn->health, CONN_HEALTH_LOST);
                return 0;
            }
            int rc = select(sock + 1, &rfds, NULL, NULL, &tv);
            if (rc < 0) {
                if (errno == EINTR) continue;
                atomic_store(&conn->health, CONN_HEALTH_LOST);
                return 0;
            }
            if (rc == 0) continue;
            if (PQconsumeInput(pg) == 0) {
                atomic_store(&conn->health, CONN_HEALTH_LOST);
                return 0;
            }
            continue;
        }
        PGresult* r = PQgetResult(pg);
        if (r == NULL) {
            if (pipeline_syncs == 0) return 1;
            continue;  // separator between pipelined statements
        }
        ExecStatusType st = PQresultStatus(r);
        PQclear(r);
        if (st == PGRES_COPY_OUT || st == PGRES_COPY_IN ||
            st == PGRES_COPY_BOTH) {
            // Never ends on its own (see drain_into_chain): reset instead.
            atomic_store(&conn->health, CONN_HEALTH_LOST);
            return 0;
        }
        if (pipeline_syncs > 0 && st == PGRES_PIPELINE_SYNC &&
            ++syncs == pipeline_syncs) {
            return 1;
        }
    }
}

// ─────────────────────────────────────────────────────────────────
// Single-query execution path
// ─────────────────────────────────────────────────────────────────

// Error statuses, the same set as `PgExecStatus.isError` on the Dart
// side (lib/src/bindings/postgres_binding.dart).
static int is_error_status(ExecStatusType st) {
    return st == PGRES_FATAL_ERROR ||
           st == PGRES_BAD_RESPONSE ||
           st == PGRES_PIPELINE_ABORTED;
}

// Drains every PGresult of the dispatched query into the per-conn
// chain, calling `PQgetResult` only while `PQisBusy` is false, so the
// worker never blocks outside `select()` and the wait stays under the
// deadline and the shutdown poll. Returns OK once `PQgetResult`
// yields NULL. On timeout/shutdown/error it cancels when appropriate,
// frees the partial chain and returns ABORTED. A COPY result resets
// the slot and returns CONN_LOST (see the branch below).
//
// `head_and_first_error`: keep only the first result and the first
// error result after it, clearing the rest on arrival. That is all the
// simple path's consumer reads, and it keeps the peak memory at the
// head plus one result instead of the sum of every result. When 0,
// every result is kept (multi-read: the caller wants all of them).
static int64_t drain_into_chain(native_conn_t* conn,
                                PGconn* pg,
                                int sock,
                                int has_deadline,
                                const struct timespec* deadline,
                                int head_and_first_error) {
    int have_head = 0;
    int head_is_error = 0;
    int have_error = 0;
    int link_lost = 0;
    while (1) {
        if (atomic_load(&conn->shutdown_requested)) {
            issue_cancel(pg);
            native_pool_free_result_chain(conn);
            return WORKER_PORT_ABORTED;
        }

        if (!link_lost && PQisBusy(pg)) {
            fd_set rfds;
            FD_ZERO(&rfds);
            FD_SET(sock, &rfds);

            struct timeval tv;
            if (!next_select_tv(&tv, has_deadline, deadline)) {
                // Wall-clock deadline expired: cancel and drain, so the
                // slot is usable again (or flagged for reset).
                native_pool_free_result_chain(conn);
                cancel_and_drain(conn, pg, sock, 0);
                return WORKER_PORT_ABORTED;
            }

            int rc = select(sock + 1, &rfds, NULL, NULL, &tv);
            if (rc < 0) {
                if (errno == EINTR) continue;
                native_pool_free_result_chain(conn);
                atomic_store(&conn->health, CONN_HEALTH_LOST);  // libpq busy
                return WORKER_PORT_ABORTED;
            }
            if (rc == 0) {
                // Shutdown-poll tick or deadline — re-check at top.
                continue;
            }
            if (PQconsumeInput(pg) == 0) {
                if (head_and_first_error && have_head && head_is_error &&
                    PQstatus(pg) == CONNECTION_BAD) {
                    // The link died and the head is the server's own
                    // error (e.g. the FATAL that `pg_terminate_backend`
                    // sends the session it ends): the statement did not
                    // run, so nothing would be repeated. Report the loss
                    // now and reconnect, as the COPY branch below does;
                    // posting OK would hand the caller an ordinary
                    // query error over a dead link, with the slot still
                    // marked healthy.
                    native_pool_free_result_chain(conn);
                    atomic_store(&conn->health, CONN_HEALTH_LOST);
                    native_pool_worker_reset(conn);
                    return WORKER_PORT_CONN_LOST;
                }
                if (head_and_first_error && have_head &&
                    PQstatus(pg) == CONNECTION_BAD) {
                    // The link died after the head was complete (e.g.
                    // `pg_terminate_backend(pg_backend_pid())`, or a
                    // crash before ReadyForQuery). The head's statement
                    // ran, so aborting here would report a lost
                    // connection for work the server did — a caller
                    // retrying an INSERT would run it twice. Keep the
                    // pre-2026-11-04 contract instead: post OK with the
                    // head. libpq has dropped the socket, so the pulls
                    // below return at once: its connection-error result
                    // (kept as the first trailing error), then NULL. The
                    // dead link is reported on the next exchange. Only
                    // on CONNECTION_BAD: a read failure that left the
                    // socket open (out of memory) would make those pulls
                    // block, so it aborts like any other failure.
                    link_lost = 1;
                } else {
                    native_pool_free_result_chain(conn);
                    atomic_store(&conn->health, CONN_HEALTH_LOST);  // libpq busy
                    return WORKER_PORT_ABORTED;
                }
            }
            if (!link_lost) continue;
        }

        // Not busy → safe to pull one result without blocking.
        PGresult* r = PQgetResult(pg);
        if (r == NULL) break;  // every statement drained
        ExecStatusType st = PQresultStatus(r);
        if (st == PGRES_COPY_OUT || st == PGRES_COPY_IN ||
            st == PGRES_COPY_BOTH) {
            // COPY is not supported on these paths. In a COPY state
            // libpq hands back a fresh PGRES_COPY_* result on every
            // `PQgetResult` and never NULL, with `PQisBusy` false, so
            // this loop would spin past the deadline and hold the slot.
            // Reconnect now rather than flag the slot for later:
            // `pool_acquire` picks an unhealthy slot only when no
            // healthy one is free, so a deferred reset could leave the
            // backend in COPY, holding its locks and transaction, for
            // as long as the pool stays idle. The reset discards the
            // session, so report CONN_LOST: this query is gone and its
            // transaction is poisoned (see worker_classify_failure).
            PQclear(r);
            native_pool_free_result_chain(conn);
            atomic_store(&conn->health, CONN_HEALTH_LOST);
            native_pool_worker_reset(conn);
            return WORKER_PORT_CONN_LOST;
        }
        if (head_and_first_error) {
            int keep = !have_head ||
                       (!have_error && is_error_status(st));
            if (!keep) {
                PQclear(r);
                continue;
            }
            if (have_head) {
                have_error = 1;
            } else {
                head_is_error = is_error_status(st);
            }
            have_head = 1;
        }
        if (!native_pool_chain_append(conn, r)) {
            PQclear(r);
            native_pool_free_result_chain(conn);
            atomic_store(&conn->health, CONN_HEALTH_LOST);  // results left behind
            return WORKER_PORT_ABORTED;
        }
        // Loop; PQisBusy re-checked before the next PQgetResult.
    }
    return WORKER_PORT_OK;
}

// The worker drains every result before posting OK, as the multi-read
// path does. It used to post as soon as the FIRST result was complete
// (`!PQisBusy`); with a multi-statement string whose later output
// overflowed the server's send buffer, the head arrived early and the
// Dart side waited for the rest in a blocking `PQgetResult` on the
// isolate's thread, outside the query deadline.
static int64_t execute_single(native_conn_t* conn,
                              const char* sql,
                              int64_t timeout_ms) {
    PGconn* pg = conn->pg;
    int sock = PQsocket(pg);
    if (sock < 0) return WORKER_PORT_ABORTED;

    // Defensive, as in execute_multi_read: a conn reused without
    // release must not hand stale results to this query.
    native_pool_free_result_chain(conn);

    if (PQsendQuery(pg, sql) != 1) {
        // libpq did not accept the dispatch (bad state, malformed
        // SQL at the protocol layer, etc.). Surface as ABORTED so
        // the Dart side closes + reopens.
        return WORKER_PORT_ABORTED;
    }

    // Deadline is computed BEFORE the flush so a blocked send counts
    // against the query timeout (see flush_outgoing).
    int has_deadline = (timeout_ms > 0);
    struct timespec deadline;
    if (has_deadline) compute_deadline(&deadline, timeout_ms);

    // Non-blocking conn: drain the send buffer without spinning.
    if (flush_outgoing(conn, pg, sock, has_deadline, &deadline)
            != WORKER_PORT_OK) {
        // Not fully sent: give the session up rather than finish the send
        // (the statement would run after the timeout). k101.
        atomic_store(&conn->health, CONN_HEALTH_LOST);
        return WORKER_PORT_ABORTED;
    }

    // Results sit in the chain; Dart dequeues them via `poll_result`
    // after the int64=1 notification.
    return drain_into_chain(conn, pg, sock, has_deadline, &deadline, 1);
}

// ─────────────────────────────────────────────────────────────────
// Pipeline execution path
// ─────────────────────────────────────────────────────────────────
//
// v1 contract: the worker drains ALL `query_count + 1` PGresults
// (the +1 is the sync sentinel) and discards them via `PQclear`.
// The Dart side receives a single int64=1 acknowledgement. Row
// data is not surfaced — same limitation as the legacy
// `start_pipeline_async` in MAJOR 1. Useful for batched DML
// where command tags are the only relevant output.

static int64_t execute_pipeline(native_conn_t* conn,
                                char** queries,
                                int32_t query_count,
                                int64_t timeout_ms) {
    PGconn* pg = conn->pg;
    int sock = PQsocket(pg);
    if (sock < 0) return WORKER_PORT_ABORTED;

    if (PQenterPipelineMode(pg) == 0) return WORKER_PORT_ABORTED;

    for (int32_t i = 0; i < query_count; i++) {
        // Pipeline mode requires the extended protocol —
        // PQsendQueryParams with 0 params behaves like a
        // parameterless query under the extended protocol.
        if (PQsendQueryParams(pg, queries[i],
                              0,        // nParams
                              NULL,     // paramTypes
                              NULL,     // paramValues
                              NULL,     // paramLengths
                              NULL,     // paramFormats
                              0         // resultFormat (text)
                              ) != 1) {
            PQexitPipelineMode(pg);
            return WORKER_PORT_ABORTED;
        }
    }

    if (PQpipelineSync(pg) == 0) {
        PQexitPipelineMode(pg);
        return WORKER_PORT_ABORTED;
    }

    int has_deadline = (timeout_ms > 0);
    struct timespec deadline;
    if (has_deadline) compute_deadline(&deadline, timeout_ms);

    // Spin-free flush. Not fully sent: give the session up rather than
    // finish the send (k101); the reset also leaves pipeline mode.
    if (flush_outgoing(conn, pg, sock, has_deadline, &deadline)
            != WORKER_PORT_OK) {
        atomic_store(&conn->health, CONN_HEALTH_LOST);
        PQexitPipelineMode(pg);
        return WORKER_PORT_ABORTED;
    }

    int32_t remaining = query_count + 1;  // queries + sync sentinel
    int64_t status = WORKER_PORT_OK;

    while (remaining > 0) {
        if (atomic_load(&conn->shutdown_requested)) {
            issue_cancel(pg);
            atomic_store(&conn->health, CONN_HEALTH_LOST);
            status = WORKER_PORT_ABORTED;
            break;
        }

        if (PQisBusy(pg)) {
            fd_set rfds;
            FD_ZERO(&rfds);
            FD_SET(sock, &rfds);

            struct timeval tv;
            if (!next_select_tv(&tv, has_deadline, &deadline)) {
                // Drain to the Sync so the conn can leave pipeline mode
                // and take the ROLLBACK below (k101).
                cancel_and_drain(conn, pg, sock, 1);
                status = WORKER_PORT_ABORTED;
                break;
            }

            int rc = select(sock + 1, &rfds, NULL, NULL, &tv);
            if (rc < 0) {
                if (errno == EINTR) continue;
                atomic_store(&conn->health, CONN_HEALTH_LOST);  // libpq busy
                status = WORKER_PORT_ABORTED;
                break;
            }
            if (rc == 0) {
                // Shutdown-poll wake-up — loop re-checks state.
                continue;
            }
            if (PQconsumeInput(pg) == 0) {
                atomic_store(&conn->health, CONN_HEALTH_LOST);  // libpq busy
                status = WORKER_PORT_ABORTED;
                break;
            }
            continue;
        }

        // Not busy → drain one result. In pipeline mode PQgetResult
        // returns a sequence ending in PGRES_PIPELINE_SYNC, with
        // NULL separators between queries. Count only non-NULL.
        PGresult* r = PQgetResult(pg);
        if (r != NULL) {
            PQclear(r);
            remaining--;
        }
        // NULL = separator; outer loop re-checks PQisBusy.
    }

    PQexitPipelineMode(pg);

    // A mid-pipeline error leaves the transaction aborted (INERROR) —
    // the pipeline's own COMMIT became PGRES_PIPELINE_ABORTED and never
    // ran. Force a synchronous ROLLBACK so the next acquire of this conn
    // finds a clean state. A HEALTHY open transaction (INTRANS) is
    // intentionally left alone: it belongs to the caller (an external
    // withTransaction composing an executePipeline batch) and its COMMIT
    // arrives on a later submit. Matches the MySQL/SQLite batch contract:
    // the caller owns the surrounding transaction.
    PGTransactionStatusType ts = PQtransactionStatus(pg);
    if (ts == PQTRANS_INERROR) {
        PGresult* rb = PQexec(pg, "ROLLBACK");
        if (rb != NULL) PQclear(rb);
    }

    return status;
}

// ─────────────────────────────────────────────────────────────────
// Single-query with params — ABI MINOR 1 path
// ─────────────────────────────────────────────────────────────────
//
// Mirrors `execute_single` but uses `PQsendQueryParams` so the SQL
// and the parameter values travel separately (Extended Query
// Protocol). The select()/PQconsumeInput()/PQisBusy() drain loop
// is identical — libpq's notify-when-result-ready semantics do not
// depend on which Send* primitive dispatched the query.

static int64_t execute_single_params(native_conn_t* conn,
                                     const char* sql,
                                     int32_t n_params,
                                     const int32_t* param_types,
                                     const char* const* param_values,
                                     const int* param_lengths,
                                     const int* param_formats,
                                     int result_format,
                                     int64_t timeout_ms) {
    PGconn* pg = conn->pg;
    int sock = PQsocket(pg);
    if (sock < 0) return WORKER_PORT_ABORTED;

    // libpq accepts NULL for `paramTypes` when n_params == 0 (server
    // inference). For n_params > 0 we always provide the array (zeros
    // also mean inference), so we can pass it through directly.
    Oid* types_oid = NULL;
    if (n_params > 0 && param_types != NULL) {
        // Cast int32_t* → Oid* (Oid is unsigned int in libpq; same
        // width as int32_t on every supported platform).
        types_oid = (Oid*)param_types;
    }

    if (PQsendQueryParams(pg,
                          sql,
                          n_params,
                          types_oid,
                          param_values,
                          param_lengths,
                          param_formats,
                          result_format) != 1) {
        return WORKER_PORT_ABORTED;
    }

    int has_deadline = (timeout_ms > 0);
    struct timespec deadline;
    if (has_deadline) compute_deadline(&deadline, timeout_ms);

    // Spin-free flush (deadline computed above so it counts the send).
    if (flush_outgoing(conn, pg, sock, has_deadline, &deadline)
            != WORKER_PORT_OK) {
        atomic_store(&conn->health, CONN_HEALTH_LOST);  // not fully sent (k101)
        return WORKER_PORT_ABORTED;
    }

    while (1) {
        if (atomic_load(&conn->shutdown_requested)) {
            issue_cancel(pg);
            return WORKER_PORT_ABORTED;
        }

        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(sock, &rfds);

        struct timeval tv;
        if (!next_select_tv(&tv, has_deadline, &deadline)) {
            // Cancel and drain, so the slot is usable again (k101).
            cancel_and_drain(conn, pg, sock, 0);
            return WORKER_PORT_ABORTED;
        }

        int rc = select(sock + 1, &rfds, NULL, NULL, &tv);
        if (rc < 0) {
            if (errno == EINTR) continue;
            atomic_store(&conn->health, CONN_HEALTH_LOST);  // libpq busy
            return WORKER_PORT_ABORTED;
        }
        if (rc == 0) continue;
        if (PQconsumeInput(pg) == 0) {
            atomic_store(&conn->health, CONN_HEALTH_LOST);  // libpq busy
            return WORKER_PORT_ABORTED;
        }
        if (!PQisBusy(pg)) {
            return WORKER_PORT_OK;
        }
    }
}

// ─────────────────────────────────────────────────────────────────
// Multi-read execution path — ABI MINOR 2 (2026-07-28)
// ─────────────────────────────────────────────────────────────────
//
// Runs N read statements in ONE round-trip via the Simple Query
// Protocol (statements joined with `;`, one `PQsendQuery`) and
// PRESERVES every result set, unlike `execute_pipeline` which
// discards them. All results are drained into the per-conn chain
// (native_pool_chain_append) BEFORE the worker posts OK, so the Dart
// side never touches a blocking `PQgetResult` — it just dequeues the
// already-materialised chain via `poll_result`.
//
// Error semantics: a mid-statement error makes the server abort the
// implicit transaction; the error PGresult is appended to the chain
// (it carries the real server message) and the Dart side decides how
// to surface it. Timeout/shutdown/dispatch errors free the partial
// chain and return ABORTED.

static char* join_with_semicolons(char** queries, int32_t count) {
    size_t total = 1;  // trailing NUL
    for (int32_t i = 0; i < count; i++) {
        total += strlen(queries[i]);
        if (i > 0) total += 1;  // ';' separator
    }
    char* joined = (char*)malloc(total);
    if (joined == NULL) return NULL;
    char* p = joined;
    for (int32_t i = 0; i < count; i++) {
        if (i > 0) *p++ = ';';
        size_t len = strlen(queries[i]);
        memcpy(p, queries[i], len);
        p += len;
    }
    *p = '\0';
    return joined;
}

static int64_t execute_multi_read(native_conn_t* conn,
                                  char** queries,
                                  int32_t count,
                                  int64_t timeout_ms) {
    PGconn* pg = conn->pg;
    int sock = PQsocket(pg);
    if (sock < 0) return WORKER_PORT_ABORTED;

    // Defensive: drop any chain left over from an abandoned prior
    // multi-read (pool_release also does this, but a conn reused
    // without release must not accumulate stale results).
    native_pool_free_result_chain(conn);

    char* joined = join_with_semicolons(queries, count);
    if (joined == NULL) return WORKER_PORT_ABORTED;

    int rc_send = PQsendQuery(pg, joined);
    free(joined);
    if (rc_send != 1) return WORKER_PORT_ABORTED;

    int has_deadline = (timeout_ms > 0);
    struct timespec deadline;
    if (has_deadline) compute_deadline(&deadline, timeout_ms);

    // Spin-free flush; free the partial chain on abort, as drain_into_chain
    // does. Not fully sent: give the session up (k101).
    if (flush_outgoing(conn, pg, sock, has_deadline, &deadline)
            != WORKER_PORT_OK) {
        native_pool_free_result_chain(conn);
        atomic_store(&conn->health, CONN_HEALTH_LOST);
        return WORKER_PORT_ABORTED;
    }

    return drain_into_chain(conn, pg, sock, has_deadline, &deadline, 0);
}

// ─────────────────────────────────────────────────────────────────
// Prefixed Extended query — ABI MINOR 5 path (N prefixes: MINOR 6)
// ─────────────────────────────────────────────────────────────────
//
// The `n_prefix` prefixes (no params, one statement each) and `sql`
// (with params) go out in libpq pipeline mode under ONE Sync: one
// round-trip where a deferred BEGIN (MINOR 5) or a deferred session
// reset (MINOR 6) used to cost its own. Results are moved into the per-conn chain, as in
// `execute_multi_read`, because the worker must leave pipeline mode
// before posting and can only do so once every result up to
// PGRES_PIPELINE_SYNC has been consumed. The Sync marker itself is
// cleared here, so the caller sees each prefix's result in order, then
// the query's.
//
// On deadline expiry the worker cancels and keeps draining to the Sync
// for up to PREFIXED_CANCEL_GRACE_MS: a conn left in pipeline mode
// would refuse the caller's ROLLBACK. If the Sync never arrives the
// slot is flagged for reset. No ROLLBACK here, unlike
// `execute_pipeline`: the transaction the prefix opened belongs to the
// caller, as with the fused BEGIN of the simple path. The grace window is
// PREFIXED_CANCEL_GRACE_MS (defined above, shared by every path).

static int64_t execute_prefixed_params(native_conn_t* conn,
                                       char* const* prefixes,
                                       int32_t n_prefix,
                                       const char* sql,
                                       int32_t n_params,
                                       const int32_t* param_types,
                                       const char* const* param_values,
                                       const int* param_lengths,
                                       const int* param_formats,
                                       int result_format,
                                       int64_t timeout_ms) {
    PGconn* pg = conn->pg;
    int sock = PQsocket(pg);
    if (sock < 0) return WORKER_PORT_ABORTED;

    native_pool_free_result_chain(conn);

    Oid* types_oid = NULL;
    if (n_params > 0 && param_types != NULL) {
        types_oid = (Oid*)param_types;  // same width, see execute_single_params
    }

    if (PQenterPipelineMode(pg) == 0) return WORKER_PORT_ABORTED;

    if (PQsendQueryParams(pg, prefixes[0], 0, NULL, NULL, NULL, NULL, 0)
            != 1) {
        PQexitPipelineMode(pg);  // nothing queued yet
        return WORKER_PORT_ABORTED;
    }
    // From here something is queued: always Sync and drain, so the conn
    // leaves pipeline mode clean even if a later statement failed to queue.
    int64_t status = WORKER_PORT_OK;
    for (int32_t i = 1; i < n_prefix && status == WORKER_PORT_OK; i++) {
        if (PQsendQueryParams(pg, prefixes[i], 0, NULL, NULL, NULL, NULL, 0)
                != 1) {
            status = WORKER_PORT_ABORTED;
        }
    }
    if (status == WORKER_PORT_OK
        && PQsendQueryParams(pg, sql, n_params, types_oid, param_values,
                             param_lengths, param_formats, result_format)
               != 1) {
        status = WORKER_PORT_ABORTED;
    }
    if (PQpipelineSync(pg) == 0) {
        PQexitPipelineMode(pg);
        atomic_store(&conn->health, CONN_HEALTH_LOST);
        return WORKER_PORT_ABORTED;
    }

    int has_deadline = (timeout_ms > 0);
    struct timespec deadline;
    if (has_deadline) compute_deadline(&deadline, timeout_ms);

    // Not fully sent: give the session up rather than finish the send,
    // which would run the statements after the caller was told they timed
    // out (a cancel is ignored while the server is still reading). k101.
    if (flush_outgoing(conn, pg, sock, has_deadline, &deadline)
            != WORKER_PORT_OK) {
        PQexitPipelineMode(pg);
        atomic_store(&conn->health, CONN_HEALTH_LOST);
        native_pool_free_result_chain(conn);
        return WORKER_PORT_ABORTED;
    }

    int cancelled = (status != WORKER_PORT_OK);
    int synced = 0;
    while (!synced) {
        if (atomic_load(&conn->shutdown_requested)) {
            issue_cancel(pg);
            status = WORKER_PORT_ABORTED;
            break;
        }

        if (PQisBusy(pg)) {
            fd_set rfds;
            FD_ZERO(&rfds);
            FD_SET(sock, &rfds);

            struct timeval tv;
            if (!next_select_tv(&tv, has_deadline, &deadline)) {
                if (cancelled) break;  // grace expired without the Sync
                issue_cancel(pg);
                cancelled = 1;
                status = WORKER_PORT_ABORTED;
                has_deadline = 1;
                compute_deadline(&deadline, PREFIXED_CANCEL_GRACE_MS);
                continue;
            }

            int rc = select(sock + 1, &rfds, NULL, NULL, &tv);
            if (rc < 0) {
                if (errno == EINTR) continue;
                status = WORKER_PORT_ABORTED;
                break;
            }
            if (rc == 0) continue;  // shutdown-poll tick or deadline
            if (PQconsumeInput(pg) == 0) {
                status = WORKER_PORT_ABORTED;
                break;
            }
            continue;
        }

        // Not busy → one result. NULL separates the queued statements.
        PGresult* r = PQgetResult(pg);
        if (r == NULL) continue;
        if (PQresultStatus(r) == PGRES_PIPELINE_SYNC) {
            PQclear(r);
            synced = 1;
        } else if (status != WORKER_PORT_OK
                   || !native_pool_chain_append(conn, r)) {
            PQclear(r);
            status = WORKER_PORT_ABORTED;
        }
    }

    if (!synced || PQexitPipelineMode(pg) == 0) {
        // Still in pipeline mode: unusable for the next simple query.
        // Flag the slot so the next acquire resets the link first.
        PQexitPipelineMode(pg);
        atomic_store(&conn->health, CONN_HEALTH_LOST);
        status = WORKER_PORT_ABORTED;
    }
    if (status != WORKER_PORT_OK) native_pool_free_result_chain(conn);
    return status;
}

// ─────────────────────────────────────────────────────────────────
// Cached Extended query — ABI MINOR 7 path
// ─────────────────────────────────────────────────────────────────
//
// The query runs as a named prepared statement kept in the
// connection's LRU (`conn->stmts`, stmt_cache.h), always in libpq
// pipeline mode, so a timeout cancels and drains to the Sync on a hit as
// on a miss (the wire carries the same Bind/Execute/Sync as a bare
// `PQsendQueryPrepared`):
//
//   [segment 1, only when names await close]  Close ... Sync
//                                     (fallback: DEALLOCATE Sync, per name)
//   [segment 2]  prefixes ... [Prepare on a miss] QueryPrepared  Sync
//
// An error inside a segment aborts the rest of THAT segment only, so a
// failed DEALLOCATE (the statement was already gone) never touches the
// query. Without `Close`, names evicted while the connection sits in a
// transaction are deallocated first, under a savepoint
// (`flush_closes_in_transaction`). The caller sees the same chain as `execute_prefixed_params`:
// one result per prefix, then the query's (or the Prepare's error when
// the Prepare failed). Timeout handling is that path's too.

enum { K_DISCARD = 0, K_CHAIN = 1, K_PREPARE = 2, K_QUERY = 3 };

// `PQsendClosePrepared` exists from libpq 17. Defining
// SLINGSHOT_NO_CLOSE_PREPARED at build time forces the DEALLOCATE fallback
// on a newer libpq, so tests can cover it on any build host.
#if defined(LIBPQ_HAS_CLOSE_PREPARED) && !defined(SLINGSHOT_NO_CLOSE_PREPARED)
#define STMT_USE_CLOSE 1
#else
#define STMT_USE_CLOSE 0
#endif

// 26000: invalid_sql_statement_name (the statement is gone).
static int is_missing_statement(const char* state) {
    return state != NULL && strcmp(state, "26000") == 0;
}

// 0A000 is the generic feature_not_supported; only the one raised by the
// plan cache's revalidation ("cached plan must not change result type",
// after a schema change) means the statement went stale. The source
// function is matched instead of the message, which is localised.
static int is_stale_plan(PGresult* r, const char* state) {
    if (state == NULL || strcmp(state, "0A000") != 0) return 0;
    const char* fn = PQresultErrorField(r, PG_DIAG_SOURCE_FUNCTION);
    return fn != NULL && strcmp(fn, "RevalidateCachedQuery") == 0;
}

// Whether names queued for close can go out in segment 1 now. A Close of
// a missing name is not an error in the protocol, so with libpq >= 17 the
// only state to avoid is an aborted transaction (the server would reject
// it). `DEALLOCATE` of a missing name IS an error, so the fallback sends
// it in segment 1 only on an idle connection, each in its own implicit
// transaction (its own Sync); inside the caller's transaction it goes
// through `flush_closes_in_transaction` instead.
static int pending_close_allowed(PGconn* pg) {
    PGTransactionStatusType ts = PQtransactionStatus(pg);
#if STMT_USE_CLOSE
    return ts == PQTRANS_IDLE || ts == PQTRANS_INTRANS;
#else
    return ts == PQTRANS_IDLE;
#endif
}

#if !STMT_USE_CLOSE
// Runs `sql` (Simple protocol, may hold several statements) and discards
// its results, with the worker's discipline: non-blocking, under a
// deadline of its own of `timeout_ms` (0 = none; each round-trip of a
// cached job gets the full timeout, as the retry does) and the shutdown
// poll. On expiry it cancels and keeps draining for up to
// PREFIXED_CANCEL_GRACE_MS; if the results never end, the slot is flagged
// for reset. Returns 1 when every result was drained without a cancel,
// 0 otherwise (cancelled, shutdown, lost link).
static int exec_bounded(native_conn_t* conn, const char* sql,
                        int64_t timeout_ms) {
    PGconn* pg = conn->pg;
    int sock = PQsocket(pg);
    if (sock < 0 || PQsendQuery(pg, sql) != 1) return 0;

    int has_deadline = (timeout_ms > 0);
    struct timespec deadline;
    if (has_deadline) compute_deadline(&deadline, timeout_ms);
    int cancelled = 0;
    if (flush_outgoing(conn, pg, sock, has_deadline, &deadline)
            != WORKER_PORT_OK) {
        // Not fully sent: give the session up (see execute_prefixed_params).
        atomic_store(&conn->health, CONN_HEALTH_LOST);
        return 0;
    }
    while (1) {
        if (atomic_load(&conn->shutdown_requested)) {
            issue_cancel(pg);
            atomic_store(&conn->health, CONN_HEALTH_LOST);
            return 0;
        }
        if (PQisBusy(pg)) {
            fd_set rfds;
            FD_ZERO(&rfds);
            FD_SET(sock, &rfds);
            struct timeval tv;
            if (!next_select_tv(&tv, has_deadline, &deadline)) {
                if (cancelled) {  // grace expired: results never ended
                    atomic_store(&conn->health, CONN_HEALTH_LOST);
                    return 0;
                }
                issue_cancel(pg);
                cancelled = 1;
                has_deadline = 1;
                compute_deadline(&deadline, PREFIXED_CANCEL_GRACE_MS);
                continue;
            }
            int rc = select(sock + 1, &rfds, NULL, NULL, &tv);
            if (rc < 0) {
                if (errno == EINTR) continue;
                atomic_store(&conn->health, CONN_HEALTH_LOST);
                return 0;
            }
            if (rc == 0) continue;
            if (PQconsumeInput(pg) == 0) {
                atomic_store(&conn->health, CONN_HEALTH_LOST);
                return 0;
            }
            continue;
        }
        PGresult* r = PQgetResult(pg);
        if (r == NULL) return !cancelled;
        PQclear(r);
    }
}

// Fallback only: deallocates the queued names inside the caller's open
// transaction without risking it. The names in the queue were all
// confirmed prepared (a statement found missing is never queued), so a
// failure means someone deallocated it by hand; the savepoint turns that
// into a no-op instead of an aborted transaction. A round-trip of its
// own, bounded by the job's timeout: it runs only when statements were
// evicted inside a transaction, which a cache sized to the working set
// makes rare. On failure the names after the culprit stay on the server
// until the session ends. Returns 0 when the round-trip itself failed
// (timeout, lost link); the job then aborts.
static int flush_closes_in_transaction(native_conn_t* conn,
                                       int64_t timeout_ms) {
    stmt_cache_t* c = &conn->stmts;
    PGconn* pg = conn->pg;
    size_t cap = 64 + (size_t)c->n_pending * (STMT_NAME_LEN + 16);
    char* sql = (char*)malloc(cap);
    if (sql == NULL) return 1;  // retried on a later job
    size_t len = (size_t)snprintf(sql, cap, "SAVEPOINT _ss_close;");
    for (int32_t i = 0; i < c->n_pending; i++) {
        len += (size_t)snprintf(sql + len, cap - len, "DEALLOCATE \"%s\";",
                                c->pending[i]);
    }
    snprintf(sql + len, cap - len, "RELEASE SAVEPOINT _ss_close");
    stmt_cache_pending_clear(c);
    int ok = exec_bounded(conn, sql, timeout_ms);
    free(sql);
    if (!ok) return 0;
    if (PQtransactionStatus(pg) == PQTRANS_INERROR) {
        return exec_bounded(conn,
                            "ROLLBACK TO SAVEPOINT _ss_close; "
                            "RELEASE SAVEPOINT _ss_close",
                            timeout_ms);
    }
    return 1;
}
#endif

static int send_close(PGconn* pg, const char* name) {
#if STMT_USE_CLOSE
    return PQsendClosePrepared(pg, name);
#else
    char sql[STMT_NAME_LEN + 16];
    snprintf(sql, sizeof(sql), "DEALLOCATE \"%s\"", name);
    return PQsendQueryParams(pg, sql, 0, NULL, NULL, NULL, NULL, 0);
#endif
}

// Drops the last node of the result chain (the query's result before a
// retry). The chain holds at most the prefixes plus one, so the walk is
// short.
static void chain_drop_tail(native_conn_t* conn) {
    pg_result_node_t* node = conn->chain_head;
    if (node == NULL) return;
    if (node->next == NULL) {
        native_pool_free_result_chain(conn);
        return;
    }
    while (node->next != conn->chain_tail) node = node->next;
    PQclear(conn->chain_tail->result);
    free(conn->chain_tail);
    node->next = NULL;
    conn->chain_tail = node;
}

// One cached job, laid out as above. `*prepared_ok` is set when the
// server confirmed the Prepare (the caller then caches `name`). With
// `name` NULL (capacity 0, flushing what is left) the query goes unnamed.
static int64_t cached_pipeline(native_conn_t* conn,
                               char* const* prefixes,
                               int32_t n_prefix,
                               int flush_pending,
                               const char* name,
                               int do_prepare,
                               const char* sql,
                               int32_t n_params,
                               const Oid* types_oid,
                               const char* const* param_values,
                               const int* param_lengths,
                               const int* param_formats,
                               int result_format,
                               int64_t timeout_ms,
                               int* prepared_ok) {
    PGconn* pg = conn->pg;
    int sock = PQsocket(pg);
    if (sock < 0) return WORKER_PORT_ABORTED;
    stmt_cache_t* c = &conn->stmts;

    int32_t n_close = flush_pending ? c->n_pending : 0;
    int32_t cap_kinds = n_close + n_prefix + 2;
    unsigned char* kinds = (unsigned char*)malloc((size_t)cap_kinds);
    if (kinds == NULL) return WORKER_PORT_ABORTED;

    if (PQenterPipelineMode(pg) == 0) {
        free(kinds);
        return WORKER_PORT_ABORTED;
    }

    int32_t nk = 0;
    int expected_syncs = 0;
    int64_t status = WORKER_PORT_OK;

    // Segment 1 — close evicted names. With Close, one Sync for all; with
    // the DEALLOCATE fallback (idle connection only), one Sync per name,
    // so one already gone does not abort the others.
    for (int32_t i = 0; i < n_close && status == WORKER_PORT_OK; i++) {
        if (send_close(pg, c->pending[i]) != 1) {
            status = WORKER_PORT_ABORTED;
            break;
        }
        kinds[nk++] = K_DISCARD;
        if (!STMT_USE_CLOSE || i == n_close - 1) {
            if (PQpipelineSync(pg) == 0) {
                PQexitPipelineMode(pg);
                atomic_store(&conn->health, CONN_HEALTH_LOST);
                free(kinds);
                return WORKER_PORT_ABORTED;
            }
            expected_syncs++;
        }
    }
    if (status != WORKER_PORT_OK && nk > 0 && STMT_USE_CLOSE) {
        // Close queued before the failed one still need their Sync.
        if (PQpipelineSync(pg) == 0) {
            PQexitPipelineMode(pg);
            atomic_store(&conn->health, CONN_HEALTH_LOST);
            free(kinds);
            return WORKER_PORT_ABORTED;
        }
        expected_syncs++;
    }
    // Once on the wire (or failed to go), the names are done with: a name
    // whose close did not run stays on the server until the session ends.
    if (n_close > 0) stmt_cache_pending_clear(c);

    // Segment 2 — prefixes, Prepare on a miss, the query.
    int32_t seg2_start = nk;
    for (int32_t i = 0; i < n_prefix && status == WORKER_PORT_OK; i++) {
        if (PQsendQueryParams(pg, prefixes[i], 0, NULL, NULL, NULL, NULL, 0)
                != 1) {
            status = WORKER_PORT_ABORTED;
        } else {
            kinds[nk++] = K_CHAIN;
        }
    }
    if (status == WORKER_PORT_OK && do_prepare && name != NULL) {
        if (PQsendPrepare(pg, name, sql, n_params, types_oid) != 1) {
            status = WORKER_PORT_ABORTED;
        } else {
            kinds[nk++] = K_PREPARE;
        }
    }
    if (status == WORKER_PORT_OK) {
        int sent = (name != NULL)
            ? PQsendQueryPrepared(pg, name, n_params, param_values,
                                  param_lengths, param_formats, result_format)
            : PQsendQueryParams(pg, sql, n_params, types_oid, param_values,
                                param_lengths, param_formats, result_format);
        if (sent != 1) {
            status = WORKER_PORT_ABORTED;
        } else {
            kinds[nk++] = K_QUERY;
        }
    }
    if (nk > seg2_start) {
        if (PQpipelineSync(pg) == 0) {
            PQexitPipelineMode(pg);
            atomic_store(&conn->health, CONN_HEALTH_LOST);
            free(kinds);
            return WORKER_PORT_ABORTED;
        }
        expected_syncs++;
    }
    if (expected_syncs == 0) {
        // Nothing went out at all.
        PQexitPipelineMode(pg);
        free(kinds);
        return WORKER_PORT_ABORTED;
    }

    int has_deadline = (timeout_ms > 0);
    struct timespec deadline;
    if (has_deadline) compute_deadline(&deadline, timeout_ms);

    if (flush_outgoing(conn, pg, sock, has_deadline, &deadline)
            != WORKER_PORT_OK) {
        // Not fully sent: give the session up (see execute_prefixed_params).
        PQexitPipelineMode(pg);
        atomic_store(&conn->health, CONN_HEALTH_LOST);
        free(kinds);
        native_pool_free_result_chain(conn);
        return WORKER_PORT_ABORTED;
    }

    int cancelled = (status != WORKER_PORT_OK);
    int syncs = 0;
    int32_t ki = 0;
    PGresult* prep_err = NULL;
    while (syncs < expected_syncs) {
        if (atomic_load(&conn->shutdown_requested)) {
            issue_cancel(pg);
            status = WORKER_PORT_ABORTED;
            break;
        }

        if (PQisBusy(pg)) {
            fd_set rfds;
            FD_ZERO(&rfds);
            FD_SET(sock, &rfds);

            struct timeval tv;
            if (!next_select_tv(&tv, has_deadline, &deadline)) {
                if (cancelled) break;  // grace expired without the Sync
                issue_cancel(pg);
                cancelled = 1;
                status = WORKER_PORT_ABORTED;
                has_deadline = 1;
                compute_deadline(&deadline, PREFIXED_CANCEL_GRACE_MS);
                continue;
            }

            int rc = select(sock + 1, &rfds, NULL, NULL, &tv);
            if (rc < 0) {
                if (errno == EINTR) continue;
                status = WORKER_PORT_ABORTED;
                break;
            }
            if (rc == 0) continue;
            if (PQconsumeInput(pg) == 0) {
                status = WORKER_PORT_ABORTED;
                break;
            }
            continue;
        }

        PGresult* r = PQgetResult(pg);
        if (r == NULL) continue;  // separator between queued statements
        ExecStatusType st = PQresultStatus(r);
        if (st == PGRES_PIPELINE_SYNC) {
            PQclear(r);
            syncs++;
            continue;
        }
        if (ki >= nk) {  // defensive: more results than statements
            PQclear(r);
            continue;
        }
        int kind = kinds[ki++];
        if (kind == K_PREPARE) {
            // Recorded even on a cancelled job: the statement exists.
            if (st == PGRES_COMMAND_OK) {
                *prepared_ok = 1;
                PQclear(r);
            } else if (st == PGRES_FATAL_ERROR && prep_err == NULL) {
                prep_err = r;  // takes the query's place below
            } else {
                PQclear(r);
            }
            continue;
        }
        if (kind == K_DISCARD || status != WORKER_PORT_OK) {
            PQclear(r);
            continue;
        }
        if (kind == K_QUERY && prep_err != NULL) {
            // The query was aborted by the failed Prepare; the Prepare's
            // error is the one that explains it (syntax, unknown table).
            PQclear(r);
            r = prep_err;
            prep_err = NULL;
        }
        if (!native_pool_chain_append(conn, r)) {
            PQclear(r);
            status = WORKER_PORT_ABORTED;
        }
    }
    if (prep_err != NULL) PQclear(prep_err);
    free(kinds);

    if (syncs < expected_syncs || PQexitPipelineMode(pg) == 0) {
        // Still in pipeline mode: flag the slot for reset, as
        // execute_prefixed_params does.
        PQexitPipelineMode(pg);
        atomic_store(&conn->health, CONN_HEALTH_LOST);
        status = WORKER_PORT_ABORTED;
    }
    if (status != WORKER_PORT_OK) native_pool_free_result_chain(conn);
    return status;
}

static int64_t execute_cached(native_conn_t* conn,
                              char* const* prefixes,
                              int32_t n_prefix,
                              const char* sql,
                              int32_t n_params,
                              const int32_t* param_types,
                              const char* const* param_values,
                              const int* param_lengths,
                              const int* param_formats,
                              int result_format,
                              int64_t timeout_ms) {
    stmt_cache_t* c = &conn->stmts;
    int32_t cap = atomic_load(&conn->pool->stmt_capacity);
    if (cap != c->capacity) stmt_cache_set_capacity(c, cap);

    if (c->capacity == 0 && c->n_pending == 0) {
        // Cache off and nothing left to close: exactly the uncached paths.
        if (n_prefix > 0) {
            return execute_prefixed_params(conn, prefixes, n_prefix, sql,
                                           n_params, param_types,
                                           param_values, param_lengths,
                                           param_formats, result_format,
                                           timeout_ms);
        }
        return execute_single_params(conn, sql, n_params, param_types,
                                     param_values, param_lengths,
                                     param_formats, result_format,
                                     timeout_ms);
    }

    native_pool_free_result_chain(conn);

    const Oid* types_oid = NULL;
    if (n_params > 0 && param_types != NULL) {
        types_oid = (const Oid*)param_types;  // same width, see execute_single_params
    }

    for (int attempt = 0; ; attempt++) {
        // A retry runs without the prefixes: they already ran, and their
        // results are already in the chain.
        char* const* pfx = (attempt == 0) ? prefixes : NULL;
        int32_t npfx = (attempt == 0) ? n_prefix : 0;

#if !STMT_USE_CLOSE
        if (c->n_pending > 0 &&
            PQtransactionStatus(conn->pg) == PQTRANS_INTRANS) {
            if (!flush_closes_in_transaction(conn, timeout_ms)) {
                native_pool_free_result_chain(conn);
                return WORKER_PORT_ABORTED;
            }
        }
#endif
        stmt_entry_t* e = stmt_cache_lookup(c, sql, n_params, param_types);
        char fresh[STMT_NAME_LEN];
        const char* name = NULL;  // unnamed while the cache is off
        if (e != NULL) {
            name = e->name;
        } else if (c->capacity > 0) {
            stmt_cache_next_name(c, fresh);
            name = fresh;
        }
        int flush = c->n_pending > 0 && pending_close_allowed(conn->pg);

        int prepared_ok = 0;
        int64_t status = cached_pipeline(conn, pfx, npfx, flush, name,
                                         e == NULL, sql, n_params, types_oid,
                                         param_values, param_lengths,
                                         param_formats, result_format,
                                         timeout_ms, &prepared_ok);
        if (prepared_ok) stmt_cache_insert(c, sql, n_params, param_types, fresh);
        if (status != WORKER_PORT_OK) return status;

        // The query's result is the last of the chain.
        PGresult* q = (conn->chain_tail != NULL) ? conn->chain_tail->result
                                                 : NULL;
        const char* state = (q != NULL)
            ? PQresultErrorField(q, PG_DIAG_SQLSTATE) : NULL;
        int retry = 0;
        if (e != NULL && is_missing_statement(state)) {
            stmt_cache_remove(c, e, 0);  // gone: nothing to close
            retry = 1;
        } else if (e != NULL && is_stale_plan(q, state)) {
            stmt_cache_remove(c, e, 1);  // still on the server: close it
            retry = 1;
        } else if (e == NULL && name != NULL && state != NULL &&
                   strcmp(state, "42P05") == 0) {
            retry = 1;  // name taken by the caller's own PREPARE
        }
        // Inside a transaction the error already aborted it: hand it back.
        if (!retry || attempt > 0 ||
            PQtransactionStatus(conn->pg) != PQTRANS_IDLE) {
            return WORKER_PORT_OK;
        }
        chain_drop_tail(conn);
    }
}

// ─────────────────────────────────────────────────────────────────
// Link loss: detection and sliced reconnect (ABI MINOR 3)
// ─────────────────────────────────────────────────────────────────
//
// Why NOT `PQreset`. The blocking variant has no check-point, so it
// would be the only unsliced wait in this worker, and it would break
// the promise `pool_destroy` makes in `native_pool.c` — that the join
// is "bounded by the query's timeout_ms plus the shutdown check in the
// worker's select() loop". `PQresetStart`/`PQresetPoll` expose exactly
// the sliced shape `flush_outgoing` already implements, so the reset
// obeys `shutdown_requested` on the same ~1s granularity as everything
// else here.
//
// Only the worker may call this: it touches `conn->pg`, and this worker
// is the single thread libpq §32.21 allows to do so.

#define WORKER_RESET_BUDGET_MS ((int64_t)5000)

int native_pool_worker_reset(native_conn_t* conn) {
    PGconn* pg = conn->pg;
    if (pg == NULL) return 0;

    // ABI MINOR 7: the server session — and every statement prepared on
    // it — is gone from here on, whether or not the reset succeeds.
    stmt_cache_clear(&conn->stmts);

    if (PQresetStart(pg) == 0) {
        // Could not even begin — the conn stays marked LOST and the
        // next acquire of this slot will try again.
        return 0;
    }

    struct timespec deadline;
    compute_deadline(&deadline, WORKER_RESET_BUDGET_MS);

    while (1) {
        if (atomic_load(&conn->shutdown_requested)) return 0;

        PostgresPollingStatusType st = PQresetPoll(pg);
        if (st == PGRES_POLLING_OK) {
            // libpq drops non-blocking mode across a reset; the rest of
            // this file assumes it, so restore it before declaring the
            // slot healthy.
            PQsetnonblocking(pg, 1);
            atomic_store(&conn->health, CONN_HEALTH_OK);
            return 1;
        }
        if (st == PGRES_POLLING_FAILED) return 0;

        int sock = PQsocket(pg);
        if (sock < 0) return 0;

        fd_set rfds, wfds;
        FD_ZERO(&rfds);
        FD_ZERO(&wfds);
        if (st == PGRES_POLLING_READING) FD_SET(sock, &rfds);
        else                             FD_SET(sock, &wfds);

        struct timeval tv;
        if (!next_select_tv(&tv, 1, &deadline)) return 0;  // budget spent

        int rc = select(sock + 1, &rfds, &wfds, NULL, &tv);
        if (rc < 0) {
            if (errno == EINTR) continue;
            return 0;
        }
        // rc == 0 is a shutdown-poll tick or the budget running out;
        // both are re-checked at the top of the loop.
    }
}

// Turns a generic ABORTED into CONN_LOST when the session is gone (the
// link died, or a path gave the session up and flagged the slot), and
// reconnects the slot.
//
// The distinction matters because the two failures need different
// handling and, until MINOR 3, arrived as the same code 2: a timeout
// leaves the session intact and the next query on that conn works; a
// dead link destroys the session, poisons any open transaction, and
// every later query on that conn fails until it is reconnected.
//
// `PQstatus` is the right probe and is cheap: it reads libpq's cached
// status, it does not talk to the server.
static int64_t worker_classify_failure(native_conn_t* conn) {
    if (conn->pg == NULL) return WORKER_PORT_ABORTED;
    if (atomic_load(&conn->shutdown_requested)) {
        // The pool is closing: no point opening a fresh session to throw
        // it away. The slot is torn down after this job.
        return WORKER_PORT_ABORTED;
    }
    if (atomic_load(&conn->health) == CONN_HEALTH_LOST) {
        // A path gave the session up with the link still up (a statement
        // that could not be fully sent or drained, results left behind).
        // Reconnect now and report the statement lost, as for a dead link:
        // reporting a plain abort would let the caller's next statement run
        // on the fresh session, in autocommit, outside the transaction it
        // was written for. k101.
        native_pool_worker_reset(conn);
        return WORKER_PORT_CONN_LOST;
    }
    if (PQstatus(conn->pg) != CONNECTION_BAD) {
        // Ordinary failure of one query — timeout, cancel, shutdown,
        // malformed dispatch. The link is fine.
        return WORKER_PORT_ABORTED;
    }

    atomic_store(&conn->health, CONN_HEALTH_LOST);

    // Best-effort reconnect, so the slot is usable again for the NEXT
    // caller. It does not rescue the query that just died: see the
    // no-retry policy on WORKER_PORT_CONN_LOST in `native_pool.h`.
    native_pool_worker_reset(conn);

    // Reported as lost whether or not the reset succeeded. What the
    // caller must know is that THIS query is gone and its transaction
    // is poisoned — and that is true either way.
    return WORKER_PORT_CONN_LOST;
}

// ─────────────────────────────────────────────────────────────────
// Worker entry point
// ─────────────────────────────────────────────────────────────────

void* native_pool_worker_main(void* arg) {
    native_conn_t* conn = (native_conn_t*)arg;

    while (1) {
        // ── 1. Wait for work or shutdown ──
        pthread_mutex_lock(&conn->slot_mutex);
        while (!conn->slot_filled &&
               !atomic_load(&conn->shutdown_requested)) {
            pthread_cond_wait(&conn->slot_cond, &conn->slot_mutex);
        }
        if (!conn->slot_filled &&
            atomic_load(&conn->shutdown_requested)) {
            pthread_mutex_unlock(&conn->slot_mutex);
            return NULL;
        }

        // Snapshot slot fields. Keep slot_filled=1 so concurrent
        // submits see "occupied" until we finish posting + clear.
        int is_pipeline = conn->is_pipeline;
        int is_params = conn->is_params;
        int is_multi_read = conn->is_multi_read;
        int is_cached = conn->is_cached;
        int32_t n_prefix = conn->n_prefix;
        int32_t sql_count = conn->sql_count;
        int64_t port_id = conn->port_id;
        int64_t timeout_ms = conn->timeout_ms;
        char** sql = conn->sql;
        int32_t n_params = conn->n_params;
        const int32_t* param_types_snap   = conn->param_types;
        const char* const* param_vals_snap =
            (const char* const*)conn->param_values;
        const int* param_lens_snap        = conn->param_lengths;
        const int* param_fmts_snap        = conn->param_formats;
        int result_format = conn->result_format;
        pthread_mutex_unlock(&conn->slot_mutex);

        // ── 2. Execute (one of six paths) ──
        //
        // ABI MINOR 3: a slot handed out while convalescing gets one
        // reset attempt before it runs anything. `pool_acquire` only
        // picks such a slot when no healthy one is free, so this costs
        // nothing on the happy path.
        int64_t status;
        if (atomic_load(&conn->health) != CONN_HEALTH_OK &&
            !native_pool_worker_reset(conn)) {
            status = WORKER_PORT_CONN_LOST;
            goto notify;
        }
        if (is_cached) {
            status = execute_cached(conn, sql, n_prefix, sql[n_prefix],
                                    n_params,
                                    param_types_snap,
                                    param_vals_snap,
                                    param_lens_snap,
                                    param_fmts_snap,
                                    result_format,
                                    timeout_ms);
        } else if (is_params && n_prefix > 0) {
            status = execute_prefixed_params(conn, sql, n_prefix,
                                             sql[n_prefix],
                                             n_params,
                                             param_types_snap,
                                             param_vals_snap,
                                             param_lens_snap,
                                             param_fmts_snap,
                                             result_format,
                                             timeout_ms);
        } else if (is_params) {
            status = execute_single_params(conn, sql[0],
                                           n_params,
                                           param_types_snap,
                                           param_vals_snap,
                                           param_lens_snap,
                                           param_fmts_snap,
                                           result_format,
                                           timeout_ms);
        } else if (is_multi_read) {
            status = execute_multi_read(conn, sql, sql_count, timeout_ms);
        } else if (is_pipeline) {
            status = execute_pipeline(conn, sql, sql_count, timeout_ms);
        } else {
            status = execute_single(conn, sql[0], timeout_ms);
        }

        // ── 2b. Classify the failure (ABI MINOR 3) ──
        // Distinguishing a dead link from a timeout has to happen here,
        // while `conn->pg` is still the worker's to touch.
        if (status == WORKER_PORT_ABORTED) {
            status = worker_classify_failure(conn);
        }

    notify:
        // ── 3. Clear slot FIRST — must precede the Dart-side post.
        //
        // If we posted before clearing, a fast Dart isolate could
        // receive the notification, drain the result, release the
        // conn, and have another async path re-acquire + submit on
        // the same conn — all before this worker grabs `slot_mutex`
        // to clear `slot_filled`. The second `pool_submit_query`
        // would then see `slot_filled == 1` and return 0, surfacing
        // as a spurious "libpq refused to send query" in Dart.
        // Clearing first closes the window: by the time Dart sees
        // the message, the slot is provably free.
        pthread_mutex_lock(&conn->slot_mutex);
        native_pool_free_slot_payload(conn);
        conn->slot_filled = 0;
        pthread_cond_signal(&conn->slot_cond);
        pthread_mutex_unlock(&conn->slot_mutex);

        // ── 4. Notify Dart ──
        Dart_CObject msg;
        msg.type = Dart_CObject_kInt64;
        msg.value.as_int64 = status;
        Dart_PostCObject_DL((Dart_Port)port_id, &msg);
    }
}
