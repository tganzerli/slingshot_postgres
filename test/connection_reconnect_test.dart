/// Connection-loss detection and slot reconnection — ABI MINOR 3.
///
/// The fourth gap of the Postgres driver was not "call `PQreset`": there
/// was no detection, no invalidation and no recreation. `PQstatus` ran
/// exactly once per slot, at bootstrap, and a dead conn went back to the
/// free-list to fail forever.
///
/// These tests kill the server side of a live connection with
/// `pg_terminate_backend` and assert the three halves of the contract:
///
///   1. the loss is reported as `WORKER_PORT_CONN_LOST` (3), which is
///      distinct from the timeout code (2) — before MINOR 3 both
///      arrived as 2 and a dead link was indistinguishable from a slow
///      query;
///   2. the slot recovers on its own, so the pool survives a server
///      that blinks;
///   3. a port code this package does not know is **never** treated as
///      success.
///
/// Requires a running local Postgres (localhost:5432, dbname=teste).
library;

import 'dart:ffi' as ffi;
import 'dart:isolate';

import 'package:slingshot/slingshot.dart';
import 'package:slingshot_postgres/src/bindings/postgres_binding.dart';
import 'package:slingshot_postgres/src/native/postgres_lib_loader.dart';
import 'package:slingshot_postgres/src/native/postgres_native_pool.dart';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

const _connInfo =
    'host=localhost port=5432 dbname=teste user=postgres password=123';

PostgresBinding? _loadBinding() {
  try {
    final b = PostgresBinding(loadNativeDb());
    b.initDartApi(ffi.NativeApi.initializeApiDLData);
    return b;
  } on StateError {
    return null;
  }
}

/// Runs [sql] on [conn] and returns the raw worker port code.
Future<int> _submitRaw(
  PostgresBinding binding,
  ffi.Pointer<ffi.Void> conn,
  String sql, {
  int timeoutMs = 0,
}) async {
  final port = ReceivePort();
  final sqlPtr = sql.toNativeUtf8();
  try {
    final status = binding.poolSubmitQuery(
        conn, sqlPtr, port.sendPort.nativePort, timeoutMs);
    if (status != 1) throw StateError('poolSubmitQuery refused dispatch');
    return await port.first as int;
  } finally {
    malloc.free(sqlPtr);
    port.close();
  }
}

/// Drains and discards every pending result on [conn].
///
/// Not optional: the worker posts OK as soon as libpq has a result
/// queued, and leaving it queued makes the NEXT `PQsendQuery` fail with
/// "another command is already in progress" — a genuine abort that has
/// nothing to do with a lost link.
void _drainAll(PostgresBinding binding, ffi.Pointer<ffi.Void> conn) {
  while (true) {
    final r = binding.pollResult(conn);
    if (r == ffi.nullptr) return;
    binding.clearResult(r);
  }
}

/// Reads a single int4 from the first column of the pending result.
int? _drainInt(PostgresBinding binding, ffi.Pointer<ffi.Void> conn) {
  final result = binding.pollResult(conn);
  if (result == ffi.nullptr) return null;
  try {
    if (binding.getRowCount(result) < 1) return null;
    final raw = binding.getRawValue(result, 0, 0);
    final len = binding.getRawLength(result, 0, 0);
    if (raw == ffi.nullptr || len == 0) return null;
    return int.tryParse(String.fromCharCodes(raw.asTypedList(len)));
  } finally {
    binding.clearResult(result);
  }
}

// NOTE: `_drainInt` reads one result; the command is only finished once
// `pollResult` returns null. Always follow it with `_drainAll` before
// submitting again, or the next `PQsendQuery` is refused with "another
// command is already in progress" — which surfaces as a plain abort and
// masks whatever you were actually testing.

void main() {
  final binding = _loadBinding();

  group('WorkerPortCode vocabulary', () {
    test('connLost is 3 and is distinct from aborted', () {
      // The whole point of MINOR 3: before it, a dead link and a slow
      // query were the same value.
      expect(WorkerPortCode.connLost, 3);
      expect(WorkerPortCode.connLost, isNot(WorkerPortCode.aborted));
      expect(WorkerPortCode.connLost, isNot(WorkerPortCode.ok));
    });

    test('isKnown accepts exactly the three defined codes', () {
      expect(WorkerPortCode.isKnown(WorkerPortCode.ok), isTrue);
      expect(WorkerPortCode.isKnown(WorkerPortCode.aborted), isTrue);
      expect(WorkerPortCode.isKnown(WorkerPortCode.connLost), isTrue);
    });

    test('a code from a newer .dylib is NOT known', () {
      // The regression this guards: the five executor sites read
      // `if (portCode == 2) throw` with no else, so code 4 fell
      // through to `_drainResults` on a connection whose state this
      // package cannot reason about.
      for (final unknown in [0, 4, 5, 99, -1]) {
        expect(WorkerPortCode.isKnown(unknown), isFalse,
            reason: 'code $unknown must not be treated as success');
      }
    });
  });

  group('ConnectionLostException', () {
    test('says the statement was not retried when the slot recovered', () {
      const e = ConnectionLostException(sql: 'INSERT INTO t VALUES (1)',
          reconnected: true);
      expect(e.toString(), contains('NOT retried'));
      expect(e.toString(), contains('INSERT INTO t VALUES (1)'));
    });

    test('says the slot will be retried when it has not recovered yet', () {
      const e = ConnectionLostException(sql: 'SELECT 1');
      expect(e.reconnected, isFalse);
      expect(e.toString(), contains('next acquire'));
    });
  });

  group('native reconnect', () {
    late NativePool pool;

    setUp(() {
      if (binding == null) return;
      pool = NativePool.create(
        binding: binding,
        conninfo: _connInfo,
        maxSize: 1,
        acquireTimeout: const Duration(seconds: 5),
      );
    });

    tearDown(() {
      if (binding == null) return;
      pool.destroy();
    });

    test('a lost link is reported as connLost, and the slot recovers',
        () async {
      final conn = pool.acquire(timeout: const Duration(seconds: 5));

      // The full measured sequence, asserted step by step. The timing
      // is the interesting part and it is NOT what one would guess:
      // `pg_terminate_backend(pg_backend_pid())` returns its row
      // normally, and the link only shows up dead on the NEXT exchange.
      expect(await _submitRaw(binding!, conn.ptr, 'SELECT 1::int4'),
          WorkerPortCode.ok);
      expect(_drainInt(binding, conn.ptr), 1);
      _drainAll(binding, conn.ptr);

      expect(
        await _submitRaw(binding, conn.ptr,
            'SELECT pg_terminate_backend(pg_backend_pid())'),
        WorkerPortCode.ok,
        reason: 'the kill statement itself still answers',
      );
      _drainAll(binding, conn.ptr);

      expect(
        await _submitRaw(binding, conn.ptr, 'SELECT 2::int4'),
        WorkerPortCode.connLost,
        reason: 'a dead link must not be reported as a timeout (code 2)',
      );
      _drainAll(binding, conn.ptr);

      // Same slot, no release/acquire in between: the worker
      // reconnected it while classifying the failure.
      expect(
        await _submitRaw(binding, conn.ptr, 'SELECT 3::int4'),
        WorkerPortCode.ok,
        reason: 'the slot must be usable again without any caller action',
      );
      expect(_drainInt(binding, conn.ptr), 3);

      conn.release();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('the slot recovers by itself, so the pool survives a blink',
        () async {
      final conn = pool.acquire(timeout: const Duration(seconds: 5));
      await _submitRaw(binding!, conn.ptr,
          'SELECT pg_terminate_backend(pg_backend_pid())');
      _drainAll(binding, conn.ptr);
      // Surface the loss, so the worker classifies and reconnects.
      await _submitRaw(binding, conn.ptr, 'SELECT 2::int4');
      conn.release();

      // The pool has exactly one slot, so this MUST be the same one. If
      // a lost slot were withheld instead of reconnected, this would
      // throw NativePoolAcquireTimeoutException and the test would fail.
      final again = pool.acquire(timeout: const Duration(seconds: 5));

      final code = await _submitRaw(binding, again.ptr, 'SELECT 42::int4');
      expect(code, WorkerPortCode.ok,
          reason: 'the slot must have been reconnected');
      expect(_drainInt(binding, again.ptr), 42);

      again.release();
    }, timeout: const Timeout(Duration(seconds: 30)));
  }, skip: binding == null ? 'native library not built' : null);
}
