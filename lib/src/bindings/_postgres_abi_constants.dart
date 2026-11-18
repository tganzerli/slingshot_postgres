/// ABI versions expected by this Dart package.
///
/// MUST match the macros in `native/include/native_db.h`:
///   - NATIVE_DB_ABI_VERSION_MAJOR
///   - NATIVE_DB_ABI_VERSION_MINOR
///
/// Validation policy:
///   - MAJOR mismatch                    -> fatal (StateError)
///   - linked.MINOR >= expected.MINOR    -> OK (forward-compat)
///   - linked.MINOR <  expected.MINOR    -> warning (non-blocking)
///
/// TODO: regenerate from native_db.h via a codegen step. Until then, keep
/// in sync manually whenever the C macros bump.
library;

/// Expected major version (breaking changes).
///
/// 1 → 2 in 2026-05-20: native thread/conn pool. Removed
/// `start_query_async`, `start_pipeline_async`, and
/// `cancel_query(PGconn*)`; added pool primitives (`pool_create`,
/// `pool_acquire`, `pool_release`, `pool_submit_query`,
/// `pool_submit_pipeline`, `pool_cancel`, `pool_destroy`);
/// `poll_result` first param changed from `PGconn*` to
/// `native_conn_t*`.
const int kExpectedAbiMajor = 2;

/// Expected minor version (additive non-breaking changes). Reset on
/// each MAJOR bump.
///
/// 0 → 1 in 2026-05-23: added `pool_submit_query_params` (Extended Query
/// Protocol via libpq `PQsendQueryParams`). Legacy `pool_submit_query`
/// (Simple Protocol) preserved unchanged.
///
/// 1 → 2 in 2026-07-28: added `pool_submit_multi_read` (N read
/// statements in one round-trip, results preserved as a per-conn chain)
/// plus `get_result_status` / `get_error_message` (real server error of
/// a PGresult). Legacy paths preserved unchanged.
///
/// 2 → 3 in 2026-09-11: added `WORKER_PORT_CONN_LOST` (int64 = 3) to
/// the worker port vocabulary — a lost link is now reported distinctly
/// from a timeout, and the worker reconnects the slot with a sliced
/// `PQresetStart`/`PQresetPoll`. No signature changed.
///
/// 3 → 4 in 2026-10-04: added `pool_create_with_error` — `pool_create`
/// plus a caller-owned buffer for the libpq message of a failed startup,
/// so TLS failures reach the Dart exception. `pool_create` unchanged.
///
/// 4 → 5 in 2026-10-09: added `pool_submit_query_params_prefixed` — a
/// parameterless prefix (the deferred `BEGIN`) and one Extended query in
/// libpq pipeline mode under a single Sync, one round-trip.
/// `pool_submit_query_params` unchanged.
///
/// 5 → 6 in 2026-10-10: added `pool_submit_query_params_prefixed_n` (N
/// parameterless prefixes before one Extended query, one Sync) and
/// `pool_conn_transaction_status` (libpq's local transaction state), for
/// the deferred pool session reset. Existing symbols unchanged.
///
/// 6 → 7 in 2026-11-16: added `pool_submit_query_cached` (Extended query
/// through a per-connection LRU of named prepared statements),
/// `pool_set_statement_cache_capacity` and `get_error_sqlstate`. Existing
/// symbols unchanged.
///
/// 7 → 8 in 2026-11-16: added `pool_submit_batch` (N Extended queries with
/// their own params in one pipeline, through the statement cache when asked).
/// Existing symbols unchanged.
const int kExpectedAbiMinor = 8;
