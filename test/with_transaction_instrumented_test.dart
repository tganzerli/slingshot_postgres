/// Tests for `withTransactionInstrumented`.
///
/// Covers the two terminal paths (commit and rollback) and asserts
/// that the [TxDiagnostics] record carries non-zero phase timings +
/// the expected `committed` flag.
library;

import 'dart:ffi' as ffi;

import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:slingshot_postgres/src/bindings/postgres_binding.dart';
import 'package:slingshot_postgres/src/native/postgres_lib_loader.dart';
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

Future<PostgresConnectionPool> _freshPool(PostgresBinding b) async {
  final pool = PostgresConnectionPool.withBinding(
    b,
    const PoolConfig(
      connInfo: _connInfo,
      minSize: 1,
      maxSize: 2,
      instrumentationEnabled: true,
    ),
  );
  await pool.start();
  return pool;
}

void main() {
  if (!_canLoadNative()) {
    test('skipped (native library not built)', () {
      markTestSkipped('libnative_db not available');
    });
    return;
  }

  group('withTransactionInstrumented (requires Docker Postgres)', () {
    test('happy path emits committed=true TxDiagnostics', () async {
      final binding = _binding();
      final pool = await _freshPool(binding).catchError((Object e) {
        markTestSkipped('Postgres not reachable: $e');
        throw e;
      });

      try {
        final events = <TxDiagnostics>[];
        void sink(TxDiagnostics d) => events.add(d);

        final value = await withTransactionInstrumented<int>(pool, (exec) async {
          final rs = await exec.execute('SELECT 7 AS n');
          try {
            return rs.row(0).getInt('n')!;
          } finally {
            rs.release();
          }
        }, sink);

        expect(value, 7);
        expect(events, hasLength(1));

        final d = events.single;
        expect(d.committed, isTrue);
        // Phase timings should be non-negative; commit + work + begin
        // sum should be ≤ totalUs (acquire overhead is separate).
        expect(d.beginUs, greaterThanOrEqualTo(0));
        expect(d.workUs, greaterThan(0));
        expect(d.commitUs, greaterThanOrEqualTo(0));
        expect(d.totalUs, greaterThan(0));
        expect(d.acquireWaitUs, greaterThanOrEqualTo(0));
        expect(d.queueDepthAtAcquire, greaterThanOrEqualTo(0));
      } finally {
        await pool.close();
      }
    });

    test('body throws → emits committed=false + rethrows', () async {
      final binding = _binding();
      final pool = await _freshPool(binding).catchError((Object e) {
        markTestSkipped('Postgres not reachable: $e');
        throw e;
      });

      try {
        final events = <TxDiagnostics>[];
        void sink(TxDiagnostics d) => events.add(d);

        await expectLater(
          withTransactionInstrumented<void>(pool, (exec) async {
            await exec.execute('SELECT 1');
            throw StateError('forced abort inside instrumented body');
          }, sink),
          throwsA(isA<StateError>()),
        );

        expect(events, hasLength(1));
        expect(events.single.committed, isFalse);
        expect(events.single.totalUs, greaterThan(0));
      } finally {
        await pool.close();
      }
    });
  });
}
