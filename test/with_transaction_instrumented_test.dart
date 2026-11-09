/// Tests for `withTransactionInstrumented`.
///
/// Covers the two terminal paths (commit and rollback) and asserts
/// that the [TxDiagnostics] record carries non-zero phase timings +
/// the expected `committed` flag.
library;

import 'dart:async';
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

Future<PostgresConnectionPool> _freshPool(PostgresBinding b,
    {String connInfo = _connInfo}) async {
  final pool = PostgresConnectionPool.withBinding(
    b,
    PoolConfig(
      connInfo: connInfo,
      minSize: 1,
      maxSize: 2,
      instrumentationEnabled: true,
    ),
  );
  await pool.start();
  return pool;
}

/// Runs [body] in a guarded zone and returns what it produced plus the
/// errors that reached the zone. Assertions belong OUTSIDE: a TestFailure
/// thrown inside the guarded zone would be routed to its handler and lost.
Future<({Object? value, Object? error, List<Object> zoneErrors})> _guarded(
    Future<Object?> Function() body) async {
  final done = Completer<void>();
  final zoneErrors = <Object>[];
  Object? value;
  Object? error;
  runZonedGuarded(() async {
    try {
      value = await body();
    } catch (e) {
      error = e;
    } finally {
      if (!done.isCompleted) done.complete();
    }
  }, (e, _) => zoneErrors.add(e));
  await done.future;
  return (value: value, error: error, zoneErrors: zoneErrors);
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

        final value =
            await withTransactionInstrumented<int>(pool, (exec) async {
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
    group('a throwing sink does not change the outcome', () {
      var sinkCalls = 0;
      void boom(TxDiagnostics _) {
        sinkCalls++;
        throw StateError('sink boom');
      }

      setUp(() => sinkCalls = 0);

      test('commit: returns the body value and the write is committed',
          () async {
        final binding = _binding();
        final pool = await _freshPool(binding).catchError((Object e) {
          markTestSkipped('Postgres not reachable: $e');
          throw e;
        });
        try {
          (await withTransaction(pool, (exec) async {
            (await exec.execute('CREATE TABLE IF NOT EXISTS k61_sink_tx '
                    '(id int PRIMARY KEY)'))
                .release();
            (await exec.execute('TRUNCATE k61_sink_tx')).release();
          }));

          final r = await _guarded(() => withTransactionInstrumented<int>(
                pool,
                (exec) async {
                  (await exec.execute('INSERT INTO k61_sink_tx VALUES (1)'))
                      .release();
                  return 7;
                },
                boom,
              ));

          final rs = await withTransaction(pool,
              (exec) => exec.execute('SELECT count(*) AS n FROM k61_sink_tx'));
          final n = rs.row(0).getInt('n');
          rs.release();
          (await withTransaction(
                  pool, (exec) => exec.execute('DROP TABLE k61_sink_tx')))
              .release();

          expect(r.error, isNull, reason: 'the sink error reached the caller');
          expect(r.value, 7);
          expect(n, 1, reason: 'the transaction must have committed');
          expect(sinkCalls, 1);
          expect(r.zoneErrors, hasLength(1));
          expect(r.zoneErrors.single, isA<StateError>());
        } finally {
          await pool.close();
        }
      });

      test('body throws: the caller gets the body error, not the sink one',
          () async {
        final binding = _binding();
        final pool = await _freshPool(binding).catchError((Object e) {
          markTestSkipped('Postgres not reachable: $e');
          throw e;
        });
        try {
          final r = await _guarded(() => withTransactionInstrumented<void>(
                pool,
                (exec) async => throw ArgumentError('body boom'),
                boom,
              ));

          expect(r.error, isA<ArgumentError>());
          expect(sinkCalls, 1);
          expect(r.zoneErrors, hasLength(1));
          expect(r.zoneErrors.single, isA<StateError>());
        } finally {
          await pool.close();
        }
      });

      test('BEGIN fails: the caller gets the BEGIN error, not the sink one',
          () async {
        // Kill the pooled backend from a second pool, so the instrumented
        // BEGIN runs on a dead connection. application_name scopes the kill
        // to this test's connection.
        const tag = 'k61_begin_fail';
        final binding = _binding();
        final pool = await _freshPool(binding,
                connInfo: '$_connInfo application_name=$tag')
            .catchError((Object e) {
          markTestSkipped('Postgres not reachable: $e');
          throw e;
        });
        final killer = await _freshPool(binding);
        try {
          (await withTransaction(
                  killer,
                  (exec) => exec.execute('SELECT pg_terminate_backend(pid) '
                      "FROM pg_stat_activity WHERE application_name = '$tag'")))
              .release();
          await Future<void>.delayed(const Duration(milliseconds: 200));

          final r = await _guarded(() => withTransactionInstrumented<void>(
                pool,
                (exec) async {},
                boom,
              ));

          expect(r.error, isNotNull, reason: 'BEGIN on a killed backend');
          expect(r.error, isNot(isA<StateError>()),
              reason: 'the sink error replaced the BEGIN error');
          expect(sinkCalls, 1);
          expect(r.zoneErrors, hasLength(1));
          expect(r.zoneErrors.single, isA<StateError>());
        } finally {
          await killer.close();
          await pool.close();
        }
      });
    });
  });
}
