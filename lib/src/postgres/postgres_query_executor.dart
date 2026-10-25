/// The Postgres executor contract and its libpq-backed implementation.
///
/// Sends one SQL statement, waits for the Native Port notification,
/// decodes the first [PGresult] into a [PostgresResultSet], and drains any
/// additional results libpq queued (avoids "another command in
/// progress" on connection reuse — same fix as `worker.dart`).
library;

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:isolate';

import 'package:slingshot/slingshot.dart';
import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import '../bindings/postgres_binding.dart';
import '../decoder/postgres_result_row.dart';
import '../native/postgres_native_pool.dart' show WorkerPortCode;
import 'param.dart';
import 'query_phase_diagnostics.dart';
import 'session_reset.dart';

/// Executes SQL against an underlying Postgres connection and returns the
/// decoded [PostgresResultSet]. Implementations are expected to be bound to a
/// single connection for the duration of a transaction.
///
/// Lives here, not in `domain/`, because the signature is Postgres-shaped:
/// [Param] and [binaryResult] describe the Extended Query Protocol, which
/// no other driver in this repository speaks. The contract shared across
/// drivers is the transaction lifecycle (`UnitOfWork`), not the query.
abstract interface class PostgresQueryExecutorContract {
  /// Executes [sql]. Returns the decoded result set (empty for statements
  /// like `BEGIN` / `COMMIT` that produce no rows).
  ///
  /// When [params] is empty (default) the simple query protocol is used —
  /// same low-overhead path as before ABI MINOR 1. When [params] is
  /// non-empty, the Extended Query Protocol (libpq `PQsendQueryParams`)
  /// is used: values travel separately from the SQL text, so SQL
  /// injection through bound parameters is structurally impossible.
  /// Use `$1`, `$2`, … placeholders in [sql].
  ///
  /// [binaryResult] requests rows in binary wire format (4-byte BE ints,
  /// IEEE 754 BE floats, etc.) — typically ~20% fewer bytes on wire and
  /// no text→typed conversion. Only honored when the Extended Protocol
  /// is used (`params.isEmpty == false`, or pass an explicit empty list
  /// alongside `binaryResult: true` to force the extended path).
  ///
  /// Throws [QueryFailedException] if libpq refuses to send the query or
  /// the connection enters an error state during dispatch.
  Future<PostgresResultSet> execute(
    String sql, {
    List<Param> params,
    bool binaryResult,
  });
}

class PostgresQueryExecutor implements PostgresQueryExecutorContract {
  final PostgresBinding _binding;
  final ffi.Pointer<ffi.Void> _conn;
  final Duration? _timeout;

  /// Single decision point for every worker port code (ABI MINOR 3).
  ///
  /// Returns normally **only** for [WorkerPortCode.ok]; every other
  /// value throws. That is the whole point.
  ///
  /// Before this existed, the five call sites all read
  /// `if (portCode == 2) { throw } ` and then fell straight through to
  /// `_drainResults`, with no `else` and no default — so **any** code
  /// other than 2 was treated as success. A `.dylib` newer than this
  /// package posting a code it had never heard of would have made Dart
  /// drain results off a dead connection, in silence. The ABI MINOR
  /// bump does not protect that direction: the shared policy accepts
  /// `linked MINOR >= expected MINOR` without a word
  /// (`slingshot/lib/src/native/abi_check_protocol.dart`).
  /// The guard has to be code, not version.
  ///
  /// The old sites also force-unwrapped `_timeout!` on the abort path,
  /// which produced a `TypeError` instead of a domain exception
  /// whenever no timeout was configured — the default.
  void _checkPortCode(int portCode, String sql, String abortedDetail) {
    if (portCode == WorkerPortCode.ok) return;

    if (portCode == WorkerPortCode.connLost) {
      _connectionLost = true;
      throw ConnectionLostException(sql: sql);
    }

    if (portCode == WorkerPortCode.aborted) {
      final t = _timeout;
      if (t != null) throw QueryTimeoutException(sql, t);
      throw QueryFailedException(sql, abortedDetail);
    }

    // Unknown code: fail loudly rather than drain a connection whose
    // state this package cannot reason about.
    throw QueryFailedException(
      sql,
      'native worker posted unknown port code $portCode; this Dart package '
      'understands 1 (ok), 2 (aborted) and 3 (connection lost). The linked '
      'native library is newer than the package — rebuild '
      'packages/slingshot_postgres/native/ or update the package',
    );
  }

  /// Set once a [ConnectionLostException] has been raised on this
  /// executor. Read by [PostgresUnitOfWork] so a poisoned transaction
  /// stops trying to speak to a socket that is gone.
  bool get connectionLost => _connectionLost;
  bool _connectionLost = false;

  /// Optional per-query phase sink. When null (the default and only
  /// production path), no `Stopwatch` is allocated and the hot path pays
  /// nothing but a field read + null-check. Wired only by the
  /// benchmark harness.
  final QueryPhaseSink? _phaseSink;

  /// When true, the next dispatch fuses a `BEGIN;`
  /// prefix into the transaction's first statement, saving the dedicated
  /// BEGIN round-trip. Armed by `PostgresUnitOfWork.begin()` through the
  /// [deferredBegin] constructor flag and consumed exactly once — on the
  /// first `execute`/`executeMultiRead`/`executePipeline` call. On the
  /// Extended path (params/binary) it rides the same pipeline as the
  /// statement (ABI MINOR 5, [_executeExtended] with a prefix); with a
  /// library older than MINOR 5 it degrades to a standalone BEGIN.
  bool _pendingBegin;

  /// Forces the pre-MINOR-5 standalone BEGIN on the Extended path even
  /// when the linked library offers the fused submit. Tests only: it
  /// exercises the fallback taken with an older library.
  @visibleForTesting
  static bool debugForceStandaloneBegin = false;

  /// Deferred pool session reset (2026-10-10): whether this executor
  /// still has to look up the connection in [DeferredSessionReset]. The
  /// lookup happens on the first dispatch, not at construction, so an
  /// executor that never sends anything leaves the reset pending for the
  /// next one. `false` from the start for the pool's own executors
  /// ([applyDeferredReset]): a reset fused into the release-time
  /// `ROLLBACK` would commit the borrower's open transaction.
  bool _resetUnchecked;

  /// Forces the standalone reset on the Extended path even when the
  /// linked library offers the N-prefix submit (ABI MINOR 6). Tests only:
  /// it exercises the fallback taken with an older library.
  @visibleForTesting
  static bool debugForceStandaloneReset = false;

  PostgresQueryExecutor(this._binding, this._conn,
      {Duration? timeout,
      QueryPhaseSink? phaseSink,
      bool deferredBegin = false,
      bool applyDeferredReset = true})
      : _timeout = timeout,
        _phaseSink = phaseSink,
        _pendingBegin = deferredBegin,
        _resetUnchecked = applyDeferredReset;

  /// Takes the connection's pending session reset, once per executor.
  bool _takeReset() {
    if (!_resetUnchecked) return false;
    _resetUnchecked = false;
    return DeferredSessionReset.take(_conn);
  }

  /// Runs the reset in a round-trip of its own: the fallback for paths
  /// that cannot carry it as a prefix. A failure is swallowed, as the
  /// release-time reset does (`PostgresConnectionPool._resetSession`).
  Future<void> _standaloneReset() async {
    try {
      (await _executeSimple(DeferredSessionReset.standalone)).release();
    } on QueryFailedException {
      // Best effort, like the reset on release.
    }
  }

  /// Recovers from a failed statement inside the fused reset prefix. The
  /// statements after it never ran (the user's included) and the explicit
  /// `BEGIN` of the prefix left the connection in a failed transaction:
  /// roll back, reset standalone, and let the caller re-dispatch.
  Future<void> _recoverFailedReset() async {
    try {
      (await _executeSimple('ROLLBACK')).release();
    } on QueryFailedException {
      // Nothing open after all; the standalone reset still runs.
    }
    await _standaloneReset();
  }

  @override
  Future<PostgresResultSet> execute(
    String sql, {
    List<Param> params = const [],
    bool binaryResult = false,
  }) async {
    final reset = _takeReset();
    // Fast path: zero params + text result → Simple Query Protocol
    // (no marshalling, no PQexecParams overhead). Identical to the
    // pre-ABI-MINOR-1 behaviour for backward compatibility.
    // A multi-statement [sql] runs here as one implicit transaction when
    // no BEGIN is open; an error in any statement throws, and on success
    // the first statement's result is the one returned.
    if (params.isEmpty && !binaryResult) {
      if (reset || _pendingBegin) {
        final begin = _pendingBegin;
        _pendingBegin = false;
        return _executeFusedSimple(sql, reset: reset, begin: begin);
      }
      return _executeSimple(sql);
    }
    // The deferred session reset rides the Extended statement as N
    // pipeline prefixes (ABI MINOR 6); an older library sends it first.
    if (reset) {
      if (_binding.poolSubmitQueryParamsPrefixedN == null ||
          debugForceStandaloneReset) {
        await _standaloneReset();
      } else {
        final begin = _pendingBegin;
        _pendingBegin = false;
        return _executeExtended(sql, params, binaryResult,
            reset: true, begin: begin);
      }
    }
    // The Extended path can't carry a multi-statement `BEGIN;` prefix.
    // ABI MINOR 5 sends the deferred BEGIN in the same pipeline instead;
    // an older library falls back to a standalone (Simple) BEGIN first —
    // one round-trip more, same semantics.
    if (_pendingBegin) {
      _pendingBegin = false;
      if (_binding.poolSubmitQueryParamsPrefixed == null ||
          debugForceStandaloneBegin) {
        return _beginThenExtended(sql, params, binaryResult);
      }
      return _executeExtended(sql, params, binaryResult, begin: true);
    }
    return _executeExtended(sql, params, binaryResult);
  }

  Future<PostgresResultSet> _beginThenExtended(
      String sql, List<Param> params, bool binaryResult) async {
    (await _executeSimple('BEGIN')).release();
    return _executeExtended(sql, params, binaryResult);
  }

  /// Dispatches `BEGIN; <sql>` as a single Simple-Protocol
  /// multi-statement, reusing the ABI MINOR 2 `pool_submit_multi_read`
  /// primitive (no new ABI). The head PGresult is the BEGIN's —
  /// validated (`COMMAND_OK`) and discarded; the first statement's
  /// result then flows through the standard [_drainResults] path, which
  /// already surfaces a real server error message and drains the
  /// connection clean. Saves one round-trip per transaction.
  ///
  /// With a pending session reset ([reset]), the reset prefix
  /// ([DeferredSessionReset.prefix]) goes first in the same string.
  Future<PostgresResultSet> _executeFusedSimple(String sql,
      {required bool reset, required bool begin}) async {
    final parts = [
      if (reset) ...DeferredSessionReset.prefix,
      if (begin) 'BEGIN',
      sql,
    ];
    final native = malloc<ffi.Pointer<Utf8>>(parts.length);
    final allocated = <ffi.Pointer<Utf8>>[];
    final port = ReceivePort();
    final timeoutMs = _timeout?.inMilliseconds ?? 0;
    int portCode;
    try {
      for (var i = 0; i < parts.length; i++) {
        final p = parts[i].toNativeUtf8();
        allocated.add(p);
        native[i] = p;
      }
      final status = _binding.poolSubmitMultiRead(
          _conn, native, parts.length, port.sendPort.nativePort, timeoutMs);
      if (status != 1) {
        throw QueryFailedException(
            sql, 'libpq refused to send query (fused prefix)');
      }
      portCode = await port.first as int;
    } finally {
      for (final p in allocated) {
        malloc.free(p);
      }
      malloc.free(native);
      port.close();
    }
    _checkPortCode(
        portCode, sql, 'fused prefix aborted (connection error or shutdown)');
    if (!_consumePrefixResults(reset: reset, begin: begin)) {
      await _recoverFailedReset();
      _pendingBegin = begin;
      return execute(sql);
    }
    // Next result is the first statement's — reuse the head-decode +
    // drain path (handles error-with-message + connection cleanup).
    return _drainResults(sql, binary: false);
  }

  /// Pulls and validates the results of a fused prefix: the session
  /// reset's ([reset]), then the deferred BEGIN's ([begin]). Returns
  /// `false` when a reset statement failed — the rest of the chain is
  /// drained and the caller recovers and re-dispatches; a failed BEGIN
  /// throws, as before.
  bool _consumePrefixResults({required bool reset, required bool begin}) {
    if (reset) {
      for (var i = 0; i < DeferredSessionReset.prefix.length; i++) {
        final r = _binding.pollResult(_conn);
        if (r == ffi.nullptr) {
          // The Simple protocol stops at the first error; a short chain
          // without one would be a protocol surprise — treat it alike.
          return false;
        }
        final st = _binding.getResultStatus(r);
        _binding.clearResult(r);
        if (PgExecStatus.isError(st)) {
          _drainRemaining();
          return false;
        }
      }
    }
    if (begin) _consumeFusedBeginResult();
    return true;
  }

  /// Pulls and validates the leading BEGIN [PGresult] of a fused
  /// dispatch. A BEGIN error (rare — `begin()` guards against nesting)
  /// is surfaced with the real server message after draining the chain.
  void _consumeFusedBeginResult() {
    final beginR = _binding.pollResult(_conn);
    if (beginR == ffi.nullptr) return;
    final st = _binding.getResultStatus(beginR);
    if (PgExecStatus.isError(st)) {
      final msg = _binding.getErrorMessage(beginR).toDartString();
      _binding.clearResult(beginR);
      _drainRemaining();
      throw QueryFailedException('BEGIN', msg.isEmpty ? 'BEGIN failed' : msg);
    }
    _binding.clearResult(beginR);
  }

  Future<PostgresResultSet> _executeSimple(String sql) async {
    final sink = _phaseSink;
    final sw = sink == null ? null : (Stopwatch()..start());
    final port = ReceivePort();
    final sqlPtr = sql.toNativeUtf8();
    final timeoutMs = _timeout?.inMilliseconds ?? 0;
    int portCode;
    var submitUs = 0, waitUs = 0;
    try {
      final status = _binding.poolSubmitQuery(
          _conn, sqlPtr, port.sendPort.nativePort, timeoutMs);
      if (status != 1) {
        throw QueryFailedException(sql, 'libpq refused to send query');
      }
      if (sw != null) {
        submitUs = sw.elapsedMicroseconds;
        sw.reset();
      }
      portCode = await port.first as int;
      if (sw != null) {
        waitUs = sw.elapsedMicroseconds;
        sw.reset();
      }
    } finally {
      malloc.free(sqlPtr);
      port.close();
    }
    _checkPortCode(portCode, sql, 'query aborted (dispatch error or shutdown)');
    // `sw` keeps running through _drainResults → elapsed == decode phase.
    final rs = _drainResults(sql, binary: false);
    if (sink != null) {
      sink(QueryPhases(
        submitUs: submitUs,
        waitUs: waitUs,
        decodeUs: sw!.elapsedMicroseconds,
        rowCount: rs.rowCount,
        colCount: rs.colCount,
      ));
    }
    return rs;
  }

  /// Extended Query Protocol path (ABI MINOR 1, 2026-05-23).
  /// Sends [sql] with bound [params] via `pool_submit_query_params`.
  /// The native side dup-copies every buffer before returning, so we
  /// release the marshalled FFI memory immediately after dispatch.
  ///
  /// ABI MINOR 5: with [begin] (the deferred `BEGIN`), dispatches via
  /// `pool_submit_query_params_prefixed` — prefix and statement in one
  /// round-trip. The prefix's result heads the chain and is validated by
  /// [_consumeFusedBeginResult]; a failed prefix throws there and the
  /// statement (skipped server-side) never ran.
  ///
  /// ABI MINOR 6: with [reset], the session reset prefix
  /// ([DeferredSessionReset.prefix], then `BEGIN` if [begin]) goes as N
  /// prefixes via `pool_submit_query_params_prefixed_n`.
  Future<PostgresResultSet> _executeExtended(
      String sql, List<Param> params, bool binaryResult,
      {bool reset = false, bool begin = false}) async {
    final sink = _phaseSink;
    final sw = sink == null ? null : (Stopwatch()..start());
    final port = ReceivePort();
    final sqlPtr = sql.toNativeUtf8();
    final prefixPtr = begin && !reset ? 'BEGIN'.toNativeUtf8() : null;
    final prefixes = reset
        ? [...DeferredSessionReset.prefix, if (begin) 'BEGIN']
        : const <String>[];
    final prefixVec = reset ? malloc<ffi.Pointer<Utf8>>(prefixes.length) : null;
    final prefixAllocated = <ffi.Pointer<Utf8>>[];
    // `marshalled` is assigned inside the try so a throw from
    // `marshalParams` (e.g. range-check on Param.int2) still hits
    // the finally that releases sqlPtr + port without dereferencing
    // an uninitialised handle.
    MarshalledParams? marshalled;
    final timeoutMs = _timeout?.inMilliseconds ?? 0;
    int portCode;
    var submitUs = 0, waitUs = 0;
    try {
      marshalled = marshalParams(params);
      if (prefixVec != null) {
        for (var i = 0; i < prefixes.length; i++) {
          final p = prefixes[i].toNativeUtf8();
          prefixAllocated.add(p);
          prefixVec[i] = p;
        }
      }
      final status = prefixVec != null
          ? _binding.poolSubmitQueryParamsPrefixedN!(
              _conn,
              prefixVec,
              prefixes.length,
              sqlPtr,
              marshalled.count,
              marshalled.types,
              marshalled.values,
              marshalled.lengths,
              marshalled.formats,
              binaryResult ? 1 : 0,
              port.sendPort.nativePort,
              timeoutMs,
            )
          : prefixPtr == null
              ? _binding.poolSubmitQueryParams(
                  _conn,
                  sqlPtr,
                  marshalled.count,
                  marshalled.types,
                  marshalled.values,
                  marshalled.lengths,
                  marshalled.formats,
                  binaryResult ? 1 : 0,
                  port.sendPort.nativePort,
                  timeoutMs,
                )
              : _binding.poolSubmitQueryParamsPrefixed!(
                  _conn,
                  prefixPtr,
                  sqlPtr,
                  marshalled.count,
                  marshalled.types,
                  marshalled.values,
                  marshalled.lengths,
                  marshalled.formats,
                  binaryResult ? 1 : 0,
                  port.sendPort.nativePort,
                  timeoutMs,
                );
      if (status != 1) {
        throw QueryFailedException(sql, 'libpq refused to send query (params)');
      }
      if (sw != null) {
        // Extended-path submit also covers `marshalParams`.
        submitUs = sw.elapsedMicroseconds;
        sw.reset();
      }
      portCode = await port.first as int;
      if (sw != null) {
        waitUs = sw.elapsedMicroseconds;
        sw.reset();
      }
    } finally {
      // The C side dup-copied; safe to free our buffers as soon as
      // dispatch returned (even before the worker finishes).
      malloc.free(sqlPtr);
      if (prefixPtr != null) malloc.free(prefixPtr);
      for (final p in prefixAllocated) {
        malloc.free(p);
      }
      if (prefixVec != null) malloc.free(prefixVec);
      if (marshalled != null) freeMarshalledParams(marshalled);
      port.close();
    }
    _checkPortCode(portCode, sql,
        'parameterised query aborted (dispatch error or shutdown)');
    if ((reset || begin) &&
        !_consumePrefixResults(reset: reset, begin: begin)) {
      await _recoverFailedReset();
      _pendingBegin = begin;
      return execute(sql, params: params, binaryResult: binaryResult);
    }
    final rs = _drainResults(sql, binary: binaryResult);
    if (sink != null) {
      sink(QueryPhases(
        submitUs: submitUs,
        waitUs: waitUs,
        decodeUs: sw!.elapsedMicroseconds,
        rowCount: rs.rowCount,
        colCount: rs.colCount,
      ));
    }
    return rs;
  }

  /// Pulls the head [PGresult] off the conn, builds a [PostgresResultSet] from
  /// it, and drains any trailing results (multi-statement queries) to
  /// keep the conn idle for the next dispatch. Mirrors the worker
  /// loop's drain-or-leak pattern.
  ///
  /// ABI MINOR 2: the head result's status is inspected — a SQL error
  /// (e.g. `SELECT * FROM missing_table`) previously surfaced as an
  /// empty [PostgresResultSet]; it now throws [QueryFailedException] carrying
  /// the real server message. The connection is drained clean before
  /// throwing so the next dispatch starts fresh.
  ///
  /// The trailing results are inspected too (2026-10-12): an error past
  /// the first statement of a multi-statement string used to be cleared
  /// unseen — see [_drainTrailing].
  PostgresResultSet _drainResults(String sql, {required bool binary}) {
    final result = _binding.pollResult(_conn);
    if (result == ffi.nullptr) {
      return PostgresResultSet.empty();
    }
    final status = _binding.getResultStatus(result);
    if (PgExecStatus.isError(status)) {
      final msg = _binding.getErrorMessage(result).toDartString();
      _binding.clearResult(result);
      _drainRemaining();
      throw QueryFailedException(sql, msg.isEmpty ? 'query failed' : msg);
    }
    final rs = PostgresResultSet.fromResult(_binding, result, binary: binary);
    final trailingError = _drainTrailing();
    if (trailingError != null) {
      rs.release();
      throw QueryFailedException(sql, trailingError);
    }
    return rs;
  }

  /// Drains the results after the head, as [_drainRemaining] does, and
  /// returns the server message of the first error among them, or `null`.
  /// A multi-statement string in the Simple protocol yields one result
  /// per statement run and stops at the first failing one, so an error
  /// past the first statement is the last result — previously cleared
  /// unseen, leaving the caller with a success (outside a transaction,
  /// the implicit one had been rolled back).
  String? _drainTrailing() {
    String? error;
    while (true) {
      final r = _binding.pollResult(_conn);
      if (r == ffi.nullptr) break;
      if (error == null && PgExecStatus.isError(_binding.getResultStatus(r))) {
        final msg = _binding.getErrorMessage(r).toDartString();
        error = msg.isEmpty ? 'query failed' : msg;
      }
      _binding.clearResult(r);
    }
    return error;
  }

  /// Clears every remaining `PGresult` on the conn so it is idle for
  /// the next dispatch. Safe to call when nothing is pending.
  void _drainRemaining() {
    while (true) {
      final extra = _binding.pollResult(_conn);
      if (extra == ffi.nullptr) break;
      _binding.clearResult(extra);
    }
  }

  /// Runs [reads] in a SINGLE network round-trip (ABI MINOR 2),
  /// returning the N result sets in statement order. Amortises the
  /// ~8 µs async-machine cost plus one network RTT over N reads — the
  /// Postgres materialisation of the same lever already shipped for
  /// MySQL/SQLite.
  ///
  /// The statements run in the Simple Query Protocol as one
  /// multi-statement string, so they share a single implicit
  /// transaction: an error in statement K rolls back the earlier
  /// statements of this call and the server skips K+1..N (the returned
  /// list would otherwise be short — instead this throws).
  ///
  /// On an error result, every [PostgresResultSet] already collected is
  /// released and a [QueryFailedException] is thrown naming the culprit
  /// statement and carrying the real server message. On timeout /
  /// connection abort, throws [QueryTimeoutException] (when a timeout is
  /// configured) or [QueryFailedException].
  ///
  /// The caller owns each returned [PostgresResultSet] and must `release()` it.
  ///
  /// SECURITY: [reads] must be program-synthesized, never external
  /// input — values travel as SQL text. For untrusted values use
  /// [execute] with `params` (Extended Query Protocol), one per call.
  Future<List<PostgresResultSet>> executeMultiRead(List<String> reads) async {
    final reset = _takeReset();
    if (reads.isEmpty) {
      if (reset) await _standaloneReset();
      // Degenerate: a deferred BEGIN with no reads still needs to open
      // the transaction so the caller's commit/rollback has a txn to
      // act on. Fall back to a standalone BEGIN.
      if (_pendingBegin) {
        _pendingBegin = false;
        (await _executeSimple('BEGIN')).release();
      }
      return const [];
    }
    // Fuse the deferred BEGIN as the chain's first statement.
    final fused = _pendingBegin;
    _pendingBegin = false;
    final n = reads.length;
    final resetLen = reset ? DeferredSessionReset.prefix.length : 0;
    final total = resetLen + (fused ? n + 1 : n);
    final native = malloc<ffi.Pointer<Utf8>>(total);
    final allocated = <ffi.Pointer<Utf8>>[];
    final port = ReceivePort();
    final timeoutMs = _timeout?.inMilliseconds ?? 0;
    int portCode;
    try {
      var slot = 0;
      for (var i = 0; i < resetLen; i++) {
        final p = DeferredSessionReset.prefix[i].toNativeUtf8();
        allocated.add(p);
        native[slot++] = p;
      }
      if (fused) {
        final b = 'BEGIN'.toNativeUtf8();
        allocated.add(b);
        native[slot++] = b;
      }
      for (var i = 0; i < n; i++) {
        final p = reads[i].toNativeUtf8();
        allocated.add(p);
        native[slot++] = p;
      }
      final status = _binding.poolSubmitMultiRead(
          _conn, native, total, port.sendPort.nativePort, timeoutMs);
      if (status != 1) {
        throw QueryFailedException(reads.first,
            'multi-read dispatch failed (slot busy or libpq error)');
      }
      portCode = await port.first as int;
    } finally {
      for (final p in allocated) {
        malloc.free(p);
      }
      malloc.free(native);
      port.close();
    }
    _checkPortCode(portCode, reads.first,
        'multi-read aborted (connection error or shutdown)');

    // Consume the reset and fused BEGIN results before the statement
    // loop so error indexing below still maps 1:1 to `reads`.
    if (!_consumePrefixResults(reset: reset, begin: fused)) {
      await _recoverFailedReset();
      _pendingBegin = fused;
      return executeMultiRead(reads);
    }

    final out = <PostgresResultSet>[];
    for (var i = 0; i < n; i++) {
      final r = _binding.pollResult(_conn);
      if (r == ffi.nullptr) break; // chain shorter than N (aborted txn)
      final status = _binding.getResultStatus(r);
      if (PgExecStatus.isError(status)) {
        final msg = _binding.getErrorMessage(r).toDartString();
        _binding.clearResult(r);
        _drainRemaining();
        for (final rs in out) {
          rs.release();
        }
        throw QueryFailedException(
            reads[i], msg.isEmpty ? 'query failed' : msg);
      }
      out.add(PostgresResultSet.fromResult(_binding, r, binary: false));
    }
    return out;
  }

  /// Executes [queries] in libpq pipeline mode — all N queries sent
  /// in a single network round-trip; the watcher drains all results
  /// + sync point.
  ///
  /// **v1 limitation:** result rows are **not accessible** to the
  /// caller (libpq's PGresult ownership semantics conflict with our
  /// counting strategy in the watcher). Returns `Future<void>`. Best
  /// suited for bulk write patterns (`INSERT`/`UPDATE`/`DELETE`) where
  /// command tags suffice.
  ///
  /// **Composable inside an external transaction (since 2026-07-29):**
  /// a healthy open transaction survives the pipeline, so the pattern
  /// `withTransaction(pool, (exec) => exec.executePipeline(writes))`
  /// persists the writes on the outer `COMMIT`. An aborted transaction
  /// (a mid-pipeline error) is still rolled back natively before the
  /// connection returns to the pool. For a self-contained batch that
  /// owns its own `BEGIN`/`COMMIT`, prefer [withPipelinedTransaction].
  /// If you open a `BEGIN` via a raw pipeline yourself, the matching
  /// `COMMIT`/`ROLLBACK` is your responsibility.
  ///
  /// SELECTs in pipeline are **dispatched** correctly but their rows
  /// are discarded. For interactive query→decide→query patterns, use
  /// sequential `execute()`.
  ///
  /// Added in ABI MAJOR 1 MINOR 1.
  Future<void> executePipeline(List<String> queries) async {
    // A deferred BEGIN is sent standalone here rather than fused as the
    // pipeline's first query. Fusing it is a valid optimization now that
    // the pipeline primitive only rolls back an *aborted* (INERROR)
    // transaction and leaves a healthy open one alone (2026-07-29, see
    // `native_pool_worker.c`), so a fused BEGIN whose COMMIT arrives on a
    // later submit would survive — but that saving is deferred to its own
    // perf change (needs a benchmark). The common transaction shape
    // (reads via `execute` before the write pipeline) already consumes
    // the pending BEGIN on that first Simple read, keeping the saving.
    // A pending session reset goes standalone for the same reason.
    if (_takeReset()) await _standaloneReset();
    if (_pendingBegin) {
      _pendingBegin = false;
      (await _executeSimple('BEGIN')).release();
    }
    if (queries.isEmpty) return;

    final n = queries.length;
    final native = malloc<ffi.Pointer<Utf8>>(n);
    final allocated = <ffi.Pointer<Utf8>>[];
    final port = ReceivePort();
    final timeoutMs = _timeout?.inMilliseconds ?? 0;
    int portCode;
    try {
      for (var i = 0; i < n; i++) {
        final p = queries[i].toNativeUtf8();
        allocated.add(p);
        native[i] = p;
      }
      final status = _binding.poolSubmitPipeline(
          _conn, native, n, port.sendPort.nativePort, timeoutMs);
      if (status != 1) {
        throw QueryFailedException(queries.first, 'pipeline dispatch failed');
      }
      portCode = await port.first as int;
    } finally {
      for (final p in allocated) {
        malloc.free(p);
      }
      malloc.free(native);
      port.close();
    }
    _checkPortCode(portCode, queries.first,
        'pipeline aborted (dispatch error or shutdown)');
    // Watcher already drained N+1 PGresults; nothing for caller to do.
  }
}
