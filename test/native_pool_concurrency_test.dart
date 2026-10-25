/// Concurrency stress test for the native pool (ABI MAJOR 2).
///
/// Pushes a 10 000-query load through a pool of 8 conns × 8 workers
/// and asserts:
///   - every query completes (`status = OK`, single-row result).
///   - the pool's Dart-side `_inUse` counter returns to 0 (no
///     leaked acquires).
///   - the C side joins all workers on destroy (no hang).
///
/// Throughput is observed (not asserted) — the empirical baseline
/// of ~1 500 TPS on the developed driver at 1×4 conns means a
/// 10k load completes in roughly ~3–7s. The test gives itself 60s
/// before timing out.
///
/// Requires a running local Postgres.
@Timeout(Duration(minutes: 1))
library;

import 'dart:async';
import 'dart:ffi' as ffi;

import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:slingshot_postgres/src/bindings/postgres_binding.dart';
import 'package:slingshot_postgres/src/native/postgres_native_pool.dart';
import 'package:slingshot_postgres/src/native/postgres_lib_loader.dart';
import 'package:slingshot_postgres/src/postgres/postgres_query_executor.dart';
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

void main() {
  group('NativePool concurrency', () {
    final binding = _loadBinding();
    if (binding == null) {
      test('skipped (native library not built)', () {
        markTestSkipped('libnative_db not available');
      });
      return;
    }

    test('10 000 queries through 8-conn pool — all complete; no leaks',
        () async {
      const queryCount = 10000;
      const poolSize = 8;

      final pool = PostgresConnectionPool.withBinding(binding, const PoolConfig(
          connInfo: _connInfo,
          minSize: poolSize,
          maxSize: poolSize,
          acquireTimeout: Duration(seconds: 5),
        ),
      );

      try {
        await pool.start();
      } on NativePoolStartupException {
        markTestSkipped('Postgres not reachable');
        return;
      }

      final stopwatch = Stopwatch()..start();
      final futures = List.generate(queryCount, (i) async {
        final leased = await pool.acquire();
        try {
          final exec = PostgresQueryExecutor(binding, leased.raw);
          final rs = await exec.execute('SELECT $i::int4 AS n');
          expect(rs.rowCount, 1);
          rs.release();
        } finally {
          await leased.release();
        }
      });
      await Future.wait(futures);
      stopwatch.stop();

      // Sanity check on pool counters — every acquire must have been
      // paired with a release.
      expect(pool.borrowed, 0);
      expect(pool.idle, poolSize);
      expect(pool.pending, 0);

      // Surface a rough TPS number for ad-hoc inspection. Not asserted
      // — too sensitive to local machine load.
      final tps = queryCount / (stopwatch.elapsedMilliseconds / 1000);
      printOnFailure(
          '10k queries in ${stopwatch.elapsedMilliseconds} ms '
          '(~${tps.toStringAsFixed(0)} TPS)');

      await pool.close();
      expect(pool.isClosed, isTrue);
    });
  });
}
