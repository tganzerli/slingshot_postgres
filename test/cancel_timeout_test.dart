/// Tests for query cancellation + timeout — migrated to ABI MAJOR 2
/// (`pool_submit_query` + `pool_cancel(native_conn_t*)`) per retro B2/B3.
///
/// The original MAJOR 1 tests exercised the FFI surface via raw
/// `connect_db` + `start_query_async`. In MAJOR 2 the only way to
/// obtain a `native_conn_t*` is via `pool_acquire`, so every test
/// here stands up a 1-conn `NativePool` and goes through it.
library;

import 'dart:ffi' as ffi;
import 'dart:isolate';

import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:slingshot_postgres/src/bindings/postgres_binding.dart';
import 'package:slingshot_postgres/src/native/postgres_native_pool.dart';
import 'package:slingshot_postgres/src/native/postgres_lib_loader.dart';
import 'package:slingshot_postgres/src/postgres/postgres_query_executor.dart';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

const _connInfo =
    'host=localhost port=5432 dbname=teste user=postgres password=123';

bool _canLoadNative() {
  try {
    loadNativeDb();
    return true;
  } on StateError {
    return false;
  }
}

PostgresBinding _binding() {
  final b = PostgresBinding(loadNativeDb());
  b.initDartApi(ffi.NativeApi.initializeApiDLData);
  return b;
}

NativePool? _spawnPool(PostgresBinding binding) {
  try {
    return NativePool.create(
      binding: binding,
      conninfo: _connInfo,
      maxSize: 1,
      acquireTimeout: const Duration(seconds: 5),
    );
  } on NativePoolStartupException {
    return null;
  }
}

void main() {
  if (!_canLoadNative()) {
    test('skipped (native library not built)', () {
      markTestSkipped('libnative_db not available');
    });
    return;
  }

  group('ABI MAJOR 2 — query cancellation + timeout', () {
    test('timeout=0 preserves original behavior (happy path)', () async {
      final binding = _binding();
      final pool = _spawnPool(binding);
      if (pool == null) {
        markTestSkipped('Postgres not reachable');
        return;
      }
      final conn = pool.acquire();
      final port = ReceivePort();
      final sql = 'SELECT 1'.toNativeUtf8();

      final status = binding.poolSubmitQuery(
          conn.ptr, sql, port.sendPort.nativePort, 0); // 0 = no timeout
      expect(status, 1);
      final code = await port.first as int;
      expect(code, 1, reason: 'should receive success code');
      malloc.free(sql);
      port.close();

      // Drain everything libpq buffered for this conn.
      final r = binding.pollResult(conn.ptr);
      if (r != ffi.nullptr) binding.clearResult(r);
      while (binding.pollResult(conn.ptr) != ffi.nullptr) {}

      conn.release();
      pool.destroy();
    });

    test('timeout fires on pg_sleep(10) with 1s timeout', () async {
      final binding = _binding();
      final pool = _spawnPool(binding);
      if (pool == null) {
        markTestSkipped('Postgres not reachable');
        return;
      }
      final conn = pool.acquire();
      final port = ReceivePort();
      final sql = 'SELECT pg_sleep(10)'.toNativeUtf8();

      final stopwatch = Stopwatch()..start();
      final status = binding.poolSubmitQuery(
          conn.ptr, sql, port.sendPort.nativePort, 1000); // 1s timeout
      expect(status, 1);

      final code = await port.first as int;
      stopwatch.stop();

      expect(code, 2, reason: 'should receive timeout code 2');
      // Allow generous slack for scheduling; should be << 5s (10s sleep).
      expect(stopwatch.elapsedMilliseconds, lessThan(3000),
          reason: 'timeout should fire well before the 10s sleep');
      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(900),
          reason: 'timeout should not fire before ~1s');

      malloc.free(sql);
      port.close();
      conn.release();
      pool.destroy();
    });

    test('poolCancel on idle connection is a no-op (no crash)', () async {
      final binding = _binding();
      final pool = _spawnPool(binding);
      if (pool == null) {
        markTestSkipped('Postgres not reachable');
        return;
      }
      final conn = pool.acquire();

      // Idle: never sent a query. Should not crash.
      binding.poolCancel(conn.ptr);
      binding.poolCancel(conn.ptr); // idempotent

      conn.release();
      pool.destroy();
    });

    test('poolCancel during pg_sleep resolves with error result', () async {
      final binding = _binding();
      final pool = _spawnPool(binding);
      if (pool == null) {
        markTestSkipped('Postgres not reachable');
        return;
      }
      final conn = pool.acquire();
      final port = ReceivePort();
      final sql = 'SELECT pg_sleep(10)'.toNativeUtf8();

      final status = binding.poolSubmitQuery(
          conn.ptr, sql, port.sendPort.nativePort, 0); // no native timeout
      expect(status, 1);

      // After ~300ms, cancel from main isolate.
      Future<void>.delayed(const Duration(milliseconds: 300), () {
        binding.poolCancel(conn.ptr);
      });

      final stopwatch = Stopwatch()..start();
      final code = await port.first as int;
      stopwatch.stop();

      expect(code, 1,
          reason: 'cancellation arrives as a result (error PGresult)');
      expect(stopwatch.elapsedMilliseconds, lessThan(2000),
          reason: 'cancel should resolve far before 10s pg_sleep');

      // Drain + verify error PGresult is what we expect.
      final r = binding.pollResult(conn.ptr);
      expect(r, isNot(ffi.nullptr));
      // The result's rowCount on the error is 0; we just drain.
      if (r != ffi.nullptr) binding.clearResult(r);
      while (binding.pollResult(conn.ptr) != ffi.nullptr) {}

      malloc.free(sql);
      port.close();
      conn.release();
      pool.destroy();
    });
  });

  group('QueryTimeoutException via PostgresQueryExecutor', () {
    test('execute() with timeout throws QueryTimeoutException', () async {
      final binding = _binding();
      final pool = PostgresConnectionPool.withBinding(binding, const PoolConfig(connInfo: _connInfo, minSize: 1, maxSize: 1),
      );
      await pool.start();

      final leased = await pool.acquire();
      final exec = PostgresQueryExecutor(binding, leased.raw,
          timeout: const Duration(milliseconds: 800));

      await expectLater(
        exec.execute('SELECT pg_sleep(10)'),
        throwsA(isA<QueryTimeoutException>()),
      );

      // After timeout, the connection is in an undefined state so close +
      // reopen the pool to clean up.
      await leased.release();
      await pool.close();
    });
  });
}
