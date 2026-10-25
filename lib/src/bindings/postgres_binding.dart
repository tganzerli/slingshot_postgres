/// PostgreSQL FFI binding for `libnative_db`.
///
/// Maps the `extern "C"` symbols declared in `native/include/native_db.h`
/// and `native/include/native_pool.h`. ABI changes here MUST come with a
/// matching decision record and a bump of NATIVE_DB_ABI_VERSION_*.
///
/// ABI MAJOR 2 (2026-05-20):
///   - removed `start_query_async`, `start_pipeline_async`,
///     `cancel_query(PGconn*)`
///   - added pool primitives (`pool_create` / `pool_acquire`/`release` /
///     `pool_submit_query`/`pipeline` / `pool_cancel` / `pool_destroy`)
///   - `poll_result` first param changed from `PGconn*` to `native_conn_t*`
///     (still `Pointer<Void>` Dart-side; symbol name unchanged).
library;

import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

/// libpq `ExecStatusType` values (returned by `get_result_status`,
/// ABI MINOR 2) that this driver reasons about. Numeric values are
/// stable in libpq's public enum. Only the ones the driver inspects
/// are listed.
@internal
abstract final class PgExecStatus {
  /// `PGRES_EMPTY_QUERY` — the string sent was empty.
  static const int emptyQuery = 0;

  /// `PGRES_COMMAND_OK` — a command that returns no rows succeeded.
  static const int commandOk = 1;

  /// `PGRES_TUPLES_OK` — a query returning rows succeeded.
  static const int tuplesOk = 2;

  /// `PGRES_BAD_RESPONSE` — the server's response could not be parsed.
  static const int badResponse = 5;

  /// `PGRES_NONFATAL_ERROR` — a notice/warning (not a failure).
  static const int nonfatalError = 6;

  /// `PGRES_FATAL_ERROR` — the statement failed.
  static const int fatalError = 7;

  /// `PGRES_PIPELINE_SYNC` — end-of-pipeline marker. The ABI MINOR 5
  /// worker consumes it, so it does not normally reach Dart.
  static const int pipelineSync = 10;

  /// `PGRES_PIPELINE_ABORTED` — the statement was skipped because an
  /// earlier one in the same pipeline failed (ABI MINOR 5: the query
  /// after a failed prefix).
  static const int pipelineAborted = 11;

  /// True when [status] denotes a failed result (fatal, unparsable, or
  /// skipped by an aborted pipeline). `nonfatalError` is a warning, not
  /// a failure, so it is excluded.
  static bool isError(int status) =>
      status == fatalError ||
      status == badResponse ||
      status == pipelineAborted;
}

/// libpq `PGTransactionStatusType` values returned by
/// [PostgresBinding.poolConnTransactionStatus] (ABI MINOR 6).
abstract final class PgTransactionStatus {
  /// No transaction open: the connection is idle.
  static const int idle = 0;

  /// A command is in progress.
  static const int active = 1;

  /// Idle inside a valid transaction block.
  static const int inTransaction = 2;

  /// Idle inside a failed transaction block.
  static const int inError = 3;

  /// The connection is bad (or the handle is NULL).
  static const int unknown = 4;
}

// ───────── Native typedefs (kept symbols) ─────────

typedef _InitDartApiNative = ffi.IntPtr Function(ffi.Pointer<ffi.Void>);
typedef _InitDartApiDart = int Function(ffi.Pointer<ffi.Void>);

typedef _ConnectNative = ffi.Pointer<ffi.Void> Function(ffi.Pointer<Utf8>);
typedef _ConnectDart = ffi.Pointer<ffi.Void> Function(ffi.Pointer<Utf8>);

typedef _PollResultNative = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<ffi.Void>);
typedef _PollResultDart = ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>);

typedef _CloseDbNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _CloseDbDart = void Function(ffi.Pointer<ffi.Void>);

// ───────── Pool primitives (ABI MAJOR 2) ─────────

typedef _PoolCreateNative = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<Utf8>, ffi.Int32, ffi.Int32, ffi.Int64);
typedef _PoolCreateDart = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<Utf8>, int, int, int);

// ABI MINOR 4: pool_create + a caller-owned buffer for the startup error.
typedef _PoolCreateWithErrorNative = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<Utf8>,
    ffi.Int32,
    ffi.Int32,
    ffi.Int64,
    ffi.Pointer<Utf8>,
    ffi.Int32);
typedef _PoolCreateWithErrorDart = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<Utf8>, int, int, int, ffi.Pointer<Utf8>, int);

typedef _PoolAcquireNative = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<ffi.Void>, ffi.Int64);
typedef _PoolAcquireDart = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<ffi.Void>, int);

typedef _PoolReleaseNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>);
typedef _PoolReleaseDart = void Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>);

typedef _PoolSubmitQueryNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>, ffi.Int64, ffi.Int64);
typedef _PoolSubmitQueryDart = int Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<Utf8>, int, int);

typedef _PoolSubmitPipelineNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.Pointer<Utf8>>, ffi.Int32, ffi.Int64, ffi.Int64);
typedef _PoolSubmitPipelineDart = int Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Pointer<Utf8>>, int, int, int);

// ── ABI MINOR 1 (2026-05-23): Extended Query Protocol ──
//
// `paramValues` is `Pointer<Pointer<Uint8>>` (raw byte buffers) rather than
// `Pointer<Pointer<Utf8>>` because in binary format each value is a raw
// byte sequence whose length is `paramLengths[i]` (not NUL-terminated).
// Text values reuse the same array shape with a trailing NUL appended at
// marshalling time.
typedef _PoolSubmitQueryParamsNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, // conn
    ffi.Pointer<Utf8>, // sql
    ffi.Int32, // n_params
    ffi.Pointer<ffi.Int32>, // param_types (OIDs; 0 = let server infer)
    ffi.Pointer<ffi.Pointer<ffi.Uint8>>, // param_values
    ffi.Pointer<ffi.Int32>, // param_lengths
    ffi.Pointer<ffi.Int32>, // param_formats (0=text, 1=binary)
    ffi.Int32, // result_format (0=text, 1=binary)
    ffi.Int64, // port_id
    ffi.Int64); // timeout_ms
typedef _PoolSubmitQueryParamsDart = int Function(
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<Utf8>,
    int,
    ffi.Pointer<ffi.Int32>,
    ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
    ffi.Pointer<ffi.Int32>,
    ffi.Pointer<ffi.Int32>,
    int,
    int,
    int);

// ── ABI MINOR 5 (2026-10-09): prefixed Extended query ──
//
// `pool_submit_query_params` with a parameterless prefix statement sent
// in the same pipeline, under one Sync.
typedef _PoolSubmitQueryParamsPrefixedNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, // conn
    ffi.Pointer<Utf8>, // prefix_sql
    ffi.Pointer<Utf8>, // sql
    ffi.Int32, // n_params
    ffi.Pointer<ffi.Int32>, // param_types
    ffi.Pointer<ffi.Pointer<ffi.Uint8>>, // param_values
    ffi.Pointer<ffi.Int32>, // param_lengths
    ffi.Pointer<ffi.Int32>, // param_formats
    ffi.Int32, // result_format
    ffi.Int64, // port_id
    ffi.Int64); // timeout_ms
typedef _PoolSubmitQueryParamsPrefixedDart = int Function(
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<Utf8>,
    ffi.Pointer<Utf8>,
    int,
    ffi.Pointer<ffi.Int32>,
    ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
    ffi.Pointer<ffi.Int32>,
    ffi.Pointer<ffi.Int32>,
    int,
    int,
    int);

// ── ABI MINOR 6 (2026-10-10): N prefixes + transaction status ──
//
// MINOR 5's prefixed query with N parameterless prefixes (the deferred
// session reset), and libpq's local transaction state of a conn.
typedef _PoolSubmitQueryParamsPrefixedNNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, // conn
    ffi.Pointer<ffi.Pointer<Utf8>>, // prefix_sqls
    ffi.Int32, // n_prefix
    ffi.Pointer<Utf8>, // sql
    ffi.Int32, // n_params
    ffi.Pointer<ffi.Int32>, // param_types
    ffi.Pointer<ffi.Pointer<ffi.Uint8>>, // param_values
    ffi.Pointer<ffi.Int32>, // param_lengths
    ffi.Pointer<ffi.Int32>, // param_formats
    ffi.Int32, // result_format
    ffi.Int64, // port_id
    ffi.Int64); // timeout_ms
typedef _PoolSubmitQueryParamsPrefixedNDart = int Function(
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.Pointer<Utf8>>,
    int,
    ffi.Pointer<Utf8>,
    int,
    ffi.Pointer<ffi.Int32>,
    ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
    ffi.Pointer<ffi.Int32>,
    ffi.Pointer<ffi.Int32>,
    int,
    int,
    int);
typedef _PoolConnTransactionStatusNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>);
typedef _PoolConnTransactionStatusDart = int Function(ffi.Pointer<ffi.Void>);

// ── ABI MINOR 2 (2026-07-28): multi-read ──
//
// `pool_submit_multi_read` mirrors `pool_submit_pipeline`'s shape (an
// array of NUL-terminated statement strings) but the worker preserves
// every result set in a per-conn chain instead of discarding them.
typedef _PoolSubmitMultiReadNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.Pointer<Utf8>>, ffi.Int32, ffi.Int64, ffi.Int64);
typedef _PoolSubmitMultiReadDart = int Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Pointer<Utf8>>, int, int, int);

typedef _PoolCancelNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _PoolCancelDart = void Function(ffi.Pointer<ffi.Void>);

typedef _PoolDestroyNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _PoolDestroyDart = void Function(ffi.Pointer<ffi.Void>);

// ───────── Result inspection ─────────

typedef _GetRowCountNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _GetRowCountDart = int Function(ffi.Pointer<ffi.Void>);

typedef _GetColCountNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _GetColCountDart = int Function(ffi.Pointer<ffi.Void>);

typedef _GetFieldNameNative = ffi.Pointer<Utf8> Function(
    ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _GetFieldNameDart = ffi.Pointer<Utf8> Function(
    ffi.Pointer<ffi.Void>, int);

typedef _GetRawValueNative = ffi.Pointer<ffi.Uint8> Function(
    ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Int32);
typedef _GetRawValueDart = ffi.Pointer<ffi.Uint8> Function(
    ffi.Pointer<ffi.Void>, int, int);

typedef _GetRawLengthNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Int32);
typedef _GetRawLengthDart = int Function(ffi.Pointer<ffi.Void>, int, int);

typedef _GetFieldTypeNative = ffi.Uint32 Function(
    ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _GetFieldTypeDart = int Function(ffi.Pointer<ffi.Void>, int);

// ── Result status / error (ABI MINOR 2) ──
typedef _GetResultStatusNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _GetResultStatusDart = int Function(ffi.Pointer<ffi.Void>);

typedef _GetErrorMessageNative = ffi.Pointer<Utf8> Function(
    ffi.Pointer<ffi.Void>);
typedef _GetErrorMessageDart = ffi.Pointer<Utf8> Function(
    ffi.Pointer<ffi.Void>);

typedef _ClearResultNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _ClearResultDart = void Function(ffi.Pointer<ffi.Void>);

/// Thin wrapper around a [ffi.DynamicLibrary] exposing all native symbols
/// of `libnative_db`. Construction looks up symbols eagerly so any missing
/// symbol surfaces immediately rather than at first use.
///
/// **Internal class.** Consumers of `slingshot` should not import
/// or instantiate `PostgresBinding` directly — use [PostgresConnectionPool]
/// or any other public entry point, which resolves the binding internally
/// via the per-isolate `SharedBinding` singleton. The class stays in the
/// package source tree because tests and the internal `IsolateWorkerPool`
/// worker still need direct access; the `@internal` annotation triggers
/// an analyzer warning if it leaks into external code.
@internal
class PostgresBinding {
  /// Initializes the Dart Native API by passing
  /// `NativeApi.initializeApiDLData`. Returns 0 on success.
  final int Function(ffi.Pointer<ffi.Void> data) initDartApi;

  /// Opens a raw libpq connection. Returns `nullptr` on failure. Used
  /// directly by tests, PoCs, and internally by `pool_create`. Most
  /// callers should use [poolCreate] instead.
  final ffi.Pointer<ffi.Void> Function(ffi.Pointer<Utf8> conninfo) connect;

  /// Retrieves the next `PGresult` from the connection's libpq queue
  /// after the Native Port notification. Caller owns the returned
  /// pointer and MUST call [clearResult] when done. Returns `nullptr`
  /// when no more results.
  ///
  /// ABI MAJOR 2: first parameter is a `native_conn_t*` (opaque pool
  /// handle) rather than a raw `PGconn*`. Same `Pointer<Void>`
  /// Dart-side; semantics are now "the conn must have been issued by
  /// `poolAcquire`".
  final ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void> conn) pollResult;

  /// Closes a raw `PGconn*` via `PQfinish`. ONLY valid for connections
  /// opened via [connect] outside of a pool. Pool-owned conns are
  /// closed by [poolDestroy].
  final void Function(ffi.Pointer<ffi.Void> conn) closeDb;

  // ── Pool primitives (ABI MAJOR 2) ──

  /// Creates a `native_pool_t*` with `maxSize` connections + workers.
  /// Returns `nullptr` on failure. Caller must release via [poolDestroy].
  final ffi.Pointer<ffi.Void> Function(ffi.Pointer<Utf8> conninfo, int minSize,
      int maxSize, int acquireTimeoutMs) poolCreate;

  /// ABI MINOR 4: [poolCreate] plus a caller-owned buffer that receives the
  /// libpq message of a failed startup (TLS errors included). `null` when
  /// the linked library predates MINOR 4; callers then fall back to
  /// [poolCreate], which prints the reason to stderr.
  final ffi.Pointer<ffi.Void> Function(
      ffi.Pointer<Utf8> conninfo,
      int minSize,
      int maxSize,
      int acquireTimeoutMs,
      ffi.Pointer<Utf8> errBuf,
      int errLen)? poolCreateWithError;

  /// Blocks until a free `native_conn_t*` is available or
  /// `timeoutMs` elapses. Returns `nullptr` on timeout / pool
  /// shutdown.
  ///
  /// `timeoutMs`: 0 = use pool default; >0 = wait that many ms;
  /// <0 = wait indefinitely.
  final ffi.Pointer<ffi.Void> Function(
      ffi.Pointer<ffi.Void> pool, int timeoutMs) poolAcquire;

  /// Returns a `native_conn_t*` to the pool. No-op on nullptr.
  final void Function(ffi.Pointer<ffi.Void> pool, ffi.Pointer<ffi.Void> conn)
      poolRelease;

  /// Submits a single SQL statement to `conn`'s worker thread.
  /// Non-blocking; result delivered on `portId` (int64 = 1 / 2).
  /// Returns 1 on dispatch success, 0 if the slot is busy or
  /// dispatch failed.
  ///
  /// `timeoutMs`: 0 = no wall-clock timeout.
  final int Function(ffi.Pointer<ffi.Void> conn, ffi.Pointer<Utf8> sql,
      int portId, int timeoutMs) poolSubmitQuery;

  /// Submits N statements in libpq pipeline mode. Same delivery
  /// contract as [poolSubmitQuery] (single int64 = 1 / 2 after the
  /// worker drains all results). Returns 1 on dispatch success.
  ///
  /// **v1 limitation:** the worker drains and discards all N+1
  /// results; row data is not surfaced to the Dart side. Suitable
  /// for bulk DML where command tags are the only relevant output.
  final int Function(
      ffi.Pointer<ffi.Void> conn,
      ffi.Pointer<ffi.Pointer<Utf8>> queries,
      int queryCount,
      int portId,
      int timeoutMs) poolSubmitPipeline;

  /// Submits N read statements to run in a single round-trip (Simple
  /// Query Protocol multi-statement) and **preserves** the N result
  /// sets. Same delivery contract as [poolSubmitQuery] (int64 = 1 / 2);
  /// on OK the caller drains via [pollResult] exactly `queryCount`
  /// times, in statement order. A statement that errored surfaces as an
  /// error `PGresult` in the chain — check [getResultStatus] — after
  /// which the implicit transaction aborts and later statements are
  /// skipped (chain may be shorter than N).
  ///
  /// Returns 1 on dispatch success, 0 if the slot is busy, `queryCount
  /// <= 0`, or allocation failed.
  ///
  /// SECURITY: statements travel as SQL text — callers MUST synthesize
  /// them from trusted input only (use [poolSubmitQueryParams] for
  /// untrusted values). Added in ABI MAJOR 2 MINOR 2 (2026-07-28).
  final int Function(
      ffi.Pointer<ffi.Void> conn,
      ffi.Pointer<ffi.Pointer<Utf8>> queries,
      int queryCount,
      int portId,
      int timeoutMs) poolSubmitMultiRead;

  /// Submits a single SQL statement with bound parameters via the
  /// Postgres **Extended Query Protocol** (libpq `PQsendQueryParams`).
  ///
  /// Same delivery contract as [poolSubmitQuery] — non-blocking dispatch,
  /// result/timeout signalled via `portId` (int64 = 1 / 2). Returns 1 on
  /// dispatch success, 0 if the slot is busy, allocation failed, or
  /// `PQsendQueryParams` itself rejected the request.
  ///
  /// Parameters (all caller-owned; the native worker dup-copies before
  /// returning, so the caller is free to release immediately):
  /// - `sql` SQL with `$1`, `$2`, … placeholders.
  /// - `nParams` count of bindings (0 ⇒ extended protocol with no params;
  ///   still honors `resultFormat`).
  /// - `paramTypes` Postgres OIDs, length `nParams`. Pass `0` to let the
  ///   server infer.
  /// - `paramValues` array of byte buffers, length `nParams`. NULL pointer
  ///   for a given slot means SQL NULL.
  /// - `paramLengths` length in bytes for each value. Ignored for text
  ///   format (libpq uses `strlen`); required for binary format.
  /// - `paramFormats` per-value format code (0 = text, 1 = binary).
  /// - `resultFormat` 0 = result rows in text format (compatible with
  ///   the existing text-mode decoder); 1 = binary (caller decodes).
  ///
  /// SECURITY: this is the **recommended** path for any SQL where values
  /// come from outside the program — values travel separately from the
  /// SQL text, so SQL injection through bound parameters is impossible.
  ///
  /// Added in ABI MAJOR 2 MINOR 1 (2026-05-23).
  /// Legacy [poolSubmitQuery] (Simple Protocol) remains valid for zero
  /// params + text result.
  final int Function(
      ffi.Pointer<ffi.Void> conn,
      ffi.Pointer<Utf8> sql,
      int nParams,
      ffi.Pointer<ffi.Int32> paramTypes,
      ffi.Pointer<ffi.Pointer<ffi.Uint8>> paramValues,
      ffi.Pointer<ffi.Int32> paramLengths,
      ffi.Pointer<ffi.Int32> paramFormats,
      int resultFormat,
      int portId,
      int timeoutMs) poolSubmitQueryParams;

  /// ABI MINOR 5: [poolSubmitQueryParams] preceded by [prefixSql] (one
  /// statement, no params) in the same round-trip — libpq pipeline mode,
  /// one Sync. On OK the caller drains via [pollResult]: the prefix's
  /// result first, then the query's. If the prefix fails, the query's
  /// result is [PgExecStatus.pipelineAborted] and it never ran. The
  /// worker does not roll back a transaction the prefix opened.
  ///
  /// `null` when the linked library predates MINOR 5; callers then send
  /// the prefix as a separate round-trip.
  final int Function(
      ffi.Pointer<ffi.Void> conn,
      ffi.Pointer<Utf8> prefixSql,
      ffi.Pointer<Utf8> sql,
      int nParams,
      ffi.Pointer<ffi.Int32> paramTypes,
      ffi.Pointer<ffi.Pointer<ffi.Uint8>> paramValues,
      ffi.Pointer<ffi.Int32> paramLengths,
      ffi.Pointer<ffi.Int32> paramFormats,
      int resultFormat,
      int portId,
      int timeoutMs)? poolSubmitQueryParamsPrefixed;

  /// ABI MINOR 6: [poolSubmitQueryParamsPrefixed] with `nPrefix`
  /// prefixes (each one statement, no params) in the same pipeline and
  /// Sync. The caller drains one result per prefix, in order, then the
  /// query's; the first failure turns every later statement into
  /// [PgExecStatus.pipelineAborted].
  ///
  /// `null` when the linked library predates MINOR 6; callers then send
  /// the prefixes as a separate round-trip.
  final int Function(
      ffi.Pointer<ffi.Void> conn,
      ffi.Pointer<ffi.Pointer<Utf8>> prefixSqls,
      int nPrefix,
      ffi.Pointer<Utf8> sql,
      int nParams,
      ffi.Pointer<ffi.Int32> paramTypes,
      ffi.Pointer<ffi.Pointer<ffi.Uint8>> paramValues,
      ffi.Pointer<ffi.Int32> paramLengths,
      ffi.Pointer<ffi.Int32> paramFormats,
      int resultFormat,
      int portId,
      int timeoutMs)? poolSubmitQueryParamsPrefixedN;

  /// ABI MINOR 6: libpq's `PQtransactionStatus` of `conn`, read locally
  /// (no round-trip). Valid only with no query in flight. See
  /// [PgTransactionStatus]. `null` when the library predates MINOR 6.
  final int Function(ffi.Pointer<ffi.Void> conn)? poolConnTransactionStatus;

  /// Sends a libpq CancelRequest for any in-flight query on `conn`.
  /// Fire-and-forget. Thread-safe. Idempotent on idle.
  ///
  /// ABI MAJOR 2: replaces MAJOR 1 `cancel_query(PGconn*)` with the
  /// pool's opaque handle.
  final void Function(ffi.Pointer<ffi.Void> conn) poolCancel;

  /// Tears down a pool: signals shutdown, joins all workers, closes
  /// every conn, frees the struct. After this returns, `pool` and
  /// every conn derived from it are dangling.
  final void Function(ffi.Pointer<ffi.Void> pool) poolDestroy;

  // ── Result inspection ──

  /// Number of rows in a `PGresult`.
  final int Function(ffi.Pointer<ffi.Void> result) getRowCount;

  /// Number of columns in a `PGresult`.
  final int Function(ffi.Pointer<ffi.Void> result) getColCount;

  /// Column name for [col] in a `PGresult`. Pointer valid until
  /// [clearResult] — DO NOT free.
  final ffi.Pointer<Utf8> Function(ffi.Pointer<ffi.Void> result, int col)
      getFieldName;

  /// Pointer to raw bytes of cell `(row, col)`. `nullptr` when NULL.
  /// Pointer valid until [clearResult] — DO NOT free. Wrap with
  /// `.asTypedList(length)` for zero-copy `Uint8List` access.
  final ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<ffi.Void> result, int row, int col) getRawValue;

  /// Length in bytes of cell `(row, col)`. `0` when NULL.
  final int Function(ffi.Pointer<ffi.Void> result, int row, int col)
      getRawLength;

  /// PostgreSQL type OID for column [col].
  final int Function(ffi.Pointer<ffi.Void> result, int col) getFieldType;

  /// Raw `PQresultStatus` of a `PGresult` (libpq `ExecStatusType` enum
  /// as int). Used to distinguish success from an error result. ABI
  /// MINOR 2. See [PgExecStatus] for the values of interest.
  final int Function(ffi.Pointer<ffi.Void> result) getResultStatus;

  /// Server-side error message of a `PGresult`
  /// (`PQresultErrorMessage`). Pointer valid until [clearResult] — DO
  /// NOT free; empty string (never null) when no error. ABI MINOR 2.
  final ffi.Pointer<Utf8> Function(ffi.Pointer<ffi.Void> result)
      getErrorMessage;

  /// Frees the underlying `PGresult`. After this call all pointers
  /// returned by [getFieldName] / [getRawValue] for the same result
  /// are dangling. Idempotent on `nullptr`.
  final void Function(ffi.Pointer<ffi.Void> result) clearResult;

  PostgresBinding._(
    this.initDartApi,
    this.connect,
    this.pollResult,
    this.closeDb,
    this.poolCreate,
    this.poolAcquire,
    this.poolRelease,
    this.poolSubmitQuery,
    this.poolSubmitPipeline,
    this.poolSubmitMultiRead,
    this.poolSubmitQueryParams,
    this.poolCancel,
    this.poolDestroy,
    this.getRowCount,
    this.getColCount,
    this.getFieldName,
    this.getRawValue,
    this.getRawLength,
    this.getFieldType,
    this.getResultStatus,
    this.getErrorMessage,
    this.clearResult, {
    this.poolCreateWithError,
    this.poolSubmitQueryParamsPrefixed,
    this.poolSubmitQueryParamsPrefixedN,
    this.poolConnTransactionStatus,
  });

  factory PostgresBinding(ffi.DynamicLibrary lib) {
    return PostgresBinding._(
      lib.lookupFunction<_InitDartApiNative, _InitDartApiDart>('InitDartApiDL'),
      lib.lookupFunction<_ConnectNative, _ConnectDart>('connect_db'),
      lib.lookupFunction<_PollResultNative, _PollResultDart>('poll_result'),
      lib.lookupFunction<_CloseDbNative, _CloseDbDart>('close_db'),
      lib.lookupFunction<_PoolCreateNative, _PoolCreateDart>('pool_create'),
      lib.lookupFunction<_PoolAcquireNative, _PoolAcquireDart>('pool_acquire'),
      lib.lookupFunction<_PoolReleaseNative, _PoolReleaseDart>('pool_release'),
      lib.lookupFunction<_PoolSubmitQueryNative, _PoolSubmitQueryDart>(
          'pool_submit_query'),
      lib.lookupFunction<_PoolSubmitPipelineNative, _PoolSubmitPipelineDart>(
          'pool_submit_pipeline'),
      lib.lookupFunction<_PoolSubmitMultiReadNative, _PoolSubmitMultiReadDart>(
          'pool_submit_multi_read'),
      lib.lookupFunction<_PoolSubmitQueryParamsNative,
          _PoolSubmitQueryParamsDart>('pool_submit_query_params'),
      lib.lookupFunction<_PoolCancelNative, _PoolCancelDart>('pool_cancel'),
      lib.lookupFunction<_PoolDestroyNative, _PoolDestroyDart>('pool_destroy'),
      lib.lookupFunction<_GetRowCountNative, _GetRowCountDart>('get_row_count'),
      lib.lookupFunction<_GetColCountNative, _GetColCountDart>('get_col_count'),
      lib.lookupFunction<_GetFieldNameNative, _GetFieldNameDart>(
          'get_field_name'),
      lib.lookupFunction<_GetRawValueNative, _GetRawValueDart>('get_raw_value'),
      lib.lookupFunction<_GetRawLengthNative, _GetRawLengthDart>(
          'get_raw_length'),
      lib.lookupFunction<_GetFieldTypeNative, _GetFieldTypeDart>(
          'get_field_type'),
      lib.lookupFunction<_GetResultStatusNative, _GetResultStatusDart>(
          'get_result_status'),
      lib.lookupFunction<_GetErrorMessageNative, _GetErrorMessageDart>(
          'get_error_message'),
      lib.lookupFunction<_ClearResultNative, _ClearResultDart>('clear_result'),
      // Looked up only if present, so a MINOR 3 library still loads.
      poolCreateWithError: lib.providesSymbol('pool_create_with_error')
          ? lib.lookupFunction<_PoolCreateWithErrorNative,
              _PoolCreateWithErrorDart>('pool_create_with_error')
          : null,
      // Looked up only if present, so a MINOR 4 library still loads.
      poolSubmitQueryParamsPrefixed:
          lib.providesSymbol('pool_submit_query_params_prefixed')
              ? lib.lookupFunction<_PoolSubmitQueryParamsPrefixedNative,
                      _PoolSubmitQueryParamsPrefixedDart>(
                  'pool_submit_query_params_prefixed')
              : null,
      // Looked up only if present, so a MINOR 5 library still loads.
      poolSubmitQueryParamsPrefixedN:
          lib.providesSymbol('pool_submit_query_params_prefixed_n')
              ? lib.lookupFunction<_PoolSubmitQueryParamsPrefixedNNative,
                      _PoolSubmitQueryParamsPrefixedNDart>(
                  'pool_submit_query_params_prefixed_n')
              : null,
      poolConnTransactionStatus: lib
              .providesSymbol('pool_conn_transaction_status')
          ? lib.lookupFunction<_PoolConnTransactionStatusNative,
              _PoolConnTransactionStatusDart>('pool_conn_transaction_status')
          : null,
    );
  }
}
