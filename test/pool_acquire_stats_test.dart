/// Tests for [PostgresConnectionPool.takeAcquireStats]: the acquire wait
/// accumulators that reach callers who never see the [PooledConnection],
/// such as `withTransaction` and [PostgresUnitOfWork].
///
/// Requires the dev Postgres; skips if the native lib or server is missing.
library;

import 'dart:async';
import 'dart:ffi' as ffi;

import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:slingshot_postgres/src/bindings/postgres_binding.dart';
import 'package:slingshot_postgres/src/native/postgres_lib_loader.dart';
import 'package:slingshot_postgres/src/native/postgres_native_pool.dart';
import 'package:test/test.dart';

const _connInfo =
    'host=localhost port=5432 dbname=teste user=postgres password=123';

void main() {
  PostgresBinding? binding;
  try {
    binding = PostgresBinding(loadNativeDb());
    binding.initDartApi(ffi.NativeApi.initializeApiDLData);
  } on StateError {
    binding = null;
  }
  if (binding == null) {
    test('skipped (native library not built)', () {
      markTestSkipped('libnative_db not available');
    });
    return;
  }
  final b = binding;

  Future<PostgresConnectionPool?> open({
    required bool instrumented,
    int maxSize = 2,
    Duration acquireTimeout = const Duration(seconds: 3),
  }) async {
    final pool = PostgresConnectionPool.withBinding(
        b,
        PoolConfig(
            connInfo: _connInfo,
            minSize: 1,
            maxSize: maxSize,
            acquireTimeout: acquireTimeout,
            instrumentationEnabled: instrumented,
            sessionResetQuery: null));
    try {
      await pool.start();
    } on NativePoolStartupException {
      markTestSkipped(
          'Postgres not reachable — start PostgreSQL at localhost:5432');
      return null;
    }
    return pool;
  }

  Future<void> selectOne(PostgresQueryExecutorContract exec) async =>
      (await exec.execute('SELECT 1')).release();

  void expectZero(PoolAcquireStats s) {
    expect(s.acquires, 0);
    expect(s.waitTotalUs, 0);
    expect(s.waitMaxUs, 0);
    expect(s.queueDepthMax, 0);
    expect(s.timeouts, 0);
    expect(s.waitMeanUs, 0);
  }

  test('instrumentation off: the read comes back all zero', () async {
    final pool = await open(instrumented: false);
    if (pool == null) return;
    for (var i = 0; i < 3; i++) {
      await withTransaction(pool, selectOne);
    }
    expectZero(pool.takeAcquireStats());
    await pool.close();
  });

  test(
      'instrumentation on: withTransaction and PostgresUnitOfWork are '
      'counted, and the read resets', () async {
    final pool = await open(instrumented: true);
    if (pool == null) return;
    for (var i = 0; i < 3; i++) {
      await withTransaction(pool, selectOne);
    }
    for (var i = 0; i < 2; i++) {
      final uow = PostgresUnitOfWork(pool);
      await uow.begin();
      await selectOne(uow.executor);
      await uow.commit();
    }
    final s = pool.takeAcquireStats();
    expect(s.acquires, 5);
    expect(s.waitTotalUs, greaterThanOrEqualTo(s.waitMaxUs));
    expect(s.waitMaxUs, greaterThanOrEqualTo(0));
    expect(s.queueDepthMax, 0);
    expect(s.timeouts, 0);
    expectZero(pool.takeAcquireStats());
    await pool.close();
  });

  test('contention: queue depth on arrival and wait are accumulated', () async {
    final pool = await open(instrumented: true, maxSize: 1);
    if (pool == null) return;
    final holder = await pool.acquire();
    final waiters = [for (var i = 0; i < 3; i++) pool.acquire()];
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await holder.release();
    for (final w in waiters) {
      await (await w).release();
    }
    final s = pool.takeAcquireStats();
    expect(s.acquires, 4);
    expect(s.queueDepthMax, 2); // the third waiter found two ahead of it
    expect(s.waitMaxUs, greaterThanOrEqualTo(10000));
    expect(s.waitTotalUs, greaterThanOrEqualTo(s.waitMaxUs));
    expect(s.timeouts, 0);
    await pool.close();
  });

  test('a timed-out acquire counts only as a timeout', () async {
    final pool = await open(
        instrumented: true,
        maxSize: 1,
        acquireTimeout: const Duration(milliseconds: 50));
    if (pool == null) return;
    final holder = await pool.acquire();
    await expectLater(pool.acquire(), throwsA(isA<PoolExhaustedException>()));
    await holder.release();
    final s = pool.takeAcquireStats();
    expect(s.timeouts, 1);
    expect(s.acquires, 1); // the holder only
    expect(s.queueDepthMax, 0);
    await pool.close();
  });

  test('the read works after close', () async {
    final pool = await open(instrumented: true);
    if (pool == null) return;
    await withTransaction(pool, selectOne);
    await pool.close();
    expect(pool.takeAcquireStats().acquires, 1);
  });
}
