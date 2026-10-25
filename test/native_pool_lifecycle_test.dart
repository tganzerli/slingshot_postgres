/// Lifecycle tests for the native pool introduced in ABI MAJOR 2.
///
/// Exercises:
///   - `pool_create` allocates exactly `maxSize` conns + workers.
///   - 100 concurrent submits via `Future.wait` complete cleanly
///     (uses `PostgresConnectionPool` so the Dart-side gate prevents
///     the C-side blocking acquire from freezing the event loop).
///   - `pool_destroy` joins every worker and closes every conn.
///
/// Requires a running local Postgres (localhost:5432, dbname=teste).
library;

import 'dart:ffi' as ffi;
import 'dart:isolate';

import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:slingshot_postgres/src/bindings/postgres_binding.dart';
import 'package:slingshot_postgres/src/native/postgres_native_pool.dart';
import 'package:slingshot_postgres/src/native/postgres_lib_loader.dart';
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

NativePool? _spawn(PostgresBinding binding, {required int maxSize}) {
  try {
    return NativePool.create(
      binding: binding,
      conninfo: _connInfo,
      maxSize: maxSize,
      acquireTimeout: const Duration(seconds: 5),
    );
  } on NativePoolStartupException {
    return null;
  }
}

/// Submits `SELECT <i>` on `conn` (a `native_conn_t*` from either
/// `NativePool.acquire` or `PostgresConnectionPool.acquire().raw`)
/// and waits for the worker notification. Returns the integer value
/// drained from `pollResult`, or `null` if the worker aborted
/// (timeout / dispatch error).
Future<int?> _runSelect(
    PostgresBinding binding, dynamic conn, int i) async {
  final ffi.Pointer<ffi.Void> connPtr =
      conn is NativeConn ? conn.ptr : conn.raw as ffi.Pointer<ffi.Void>;
  final port = ReceivePort();
  final sqlPtr = 'SELECT $i::int4'.toNativeUtf8();
  int code;
  try {
    final status =
        binding.poolSubmitQuery(connPtr, sqlPtr, port.sendPort.nativePort, 0);
    if (status != 1) {
      throw StateError('poolSubmitQuery refused dispatch');
    }
    code = await port.first as int;
  } finally {
    malloc.free(sqlPtr);
    port.close();
  }
  if (code != 1) return null;

  final result = binding.pollResult(connPtr);
  if (result == ffi.nullptr) return null;
  try {
    final rows = binding.getRowCount(result);
    if (rows < 1) return null;
    final raw = binding.getRawValue(result, 0, 0);
    final len = binding.getRawLength(result, 0, 0);
    if (raw == ffi.nullptr || len == 0) return null;
    final text = String.fromCharCodes(raw.asTypedList(len));
    return int.parse(text);
  } finally {
    binding.clearResult(result);
    while (binding.pollResult(connPtr) != ffi.nullptr) {}
  }
}

void main() {
  group('NativePool lifecycle', () {
    final binding = _loadBinding();
    if (binding == null) {
      test('skipped (native library not built)', () {
        markTestSkipped('libnative_db not available');
      });
      return;
    }

    test('create with maxSize=4 opens 4 conns + 4 workers; destroy joins them',
        () async {
      final pool = _spawn(binding, maxSize: 4);
      if (pool == null) {
        markTestSkipped('Postgres not reachable');
        return;
      }

      // Acquire all 4 — non-blocking, MUST all succeed instantly because
      // pool_create allocated them eagerly.
      final conns = <NativeConn>[];
      for (var i = 0; i < 4; i++) {
        conns.add(pool.acquire(timeout: Duration.zero));
      }
      // Probe with a zero-duration acquire: every slot should now be
      // checked out, so the C-pool returns nullptr and the wrapper
      // throws a timeout exception.
      expect(
        () => pool.acquire(timeout: Duration.zero),
        throwsA(isA<NativePoolAcquireTimeoutException>()),
      );

      for (final c in conns) {
        c.release();
      }

      pool.destroy();
      expect(pool.isDestroyed, isTrue);
    });

    test('100 concurrent submits via Future.wait all complete', () async {
      // Use `PostgresConnectionPool` (Dart-side gate) rather than
      // `NativePool.acquire` directly — the latter is a SYNCHRONOUS
      // blocking C call, and >maxSize concurrent acquires from a
      // single isolate would deadlock the event loop.
      final pool = PostgresConnectionPool.withBinding(binding, const PoolConfig(
          connInfo: _connInfo,
          minSize: 4,
          maxSize: 4,
          acquireTimeout: Duration(seconds: 30),
        ),
      );
      try {
        await pool.start();
      } on NativePoolStartupException {
        markTestSkipped('Postgres not reachable');
        return;
      }

      final futures = List.generate(100, (i) async {
        final leased = await pool.acquire();
        try {
          return await _runSelect(binding, leased, i);
        } finally {
          await leased.release();
        }
      });
      final values = await Future.wait(futures);
      expect(values.where((v) => v == null), isEmpty,
          reason: 'no submit may abort under normal load');
      expect(values.cast<int>()..sort(), List.generate(100, (i) => i));

      // Counters must net out to zero — no leaked acquires.
      expect(pool.borrowed, 0);
      expect(pool.pending, 0);

      await pool.close();
    });

    test('destroy is idempotent and survives outstanding acquires', () async {
      final pool = _spawn(binding, maxSize: 2);
      if (pool == null) {
        markTestSkipped('Postgres not reachable');
        return;
      }

      // Acquire but intentionally do NOT release before destroy.
      // pool_destroy honours shutdown + PQcancel, joins workers, and
      // PQfinish's every PGconn. Calling `conn.release()` afterwards
      // would touch a freed `native_pool_t*` — production rule is
      // "release before destroy" — so we just let the wrapper leak.
      pool.acquire();
      pool.destroy();
      pool.destroy(); // idempotent — second call is a no-op.
      expect(pool.isDestroyed, isTrue);
    });
  });
}
