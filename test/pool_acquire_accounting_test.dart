/// Regression tests for the acquire/release accounting of
/// [PostgresConnectionPool] and for `close()` with borrowed connections.
///
/// The Dart gate (`_inUse`) must hand a released unit straight to the waiter
/// it wakes. Before the fix, `_release` returned the unit to the counter first
/// and the woken waiter took it again a microtask later; a newcomer running in
/// that window took the native slot, the waiter then failed its non-blocking
/// probe after having incremented `_inUse`, and one unit of capacity was lost
/// for good (and the isolate stalled for `acquireTimeout`).
///
/// Requires the dev Postgres; skips if the native lib or server is missing.
library;

import 'dart:async';
import 'dart:ffi' as ffi;

import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:slingshot_postgres/src/bindings/postgres_binding.dart';
import 'package:slingshot_postgres/src/native/postgres_lib_loader.dart';
import 'package:slingshot_postgres/src/native/postgres_native_pool.dart';
import 'package:slingshot_postgres/src/postgres/postgres_query_executor.dart';
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
    required int maxSize,
    String? reset = 'DISCARD ALL',
    Duration acquireTimeout = const Duration(seconds: 3),
  }) async {
    final pool = PostgresConnectionPool.withBinding(
        b,
        PoolConfig(
            connInfo: _connInfo,
            minSize: 1,
            maxSize: maxSize,
            acquireTimeout: acquireTimeout,
            sessionResetQuery: reset));
    try {
      await pool.start();
    } on NativePoolStartupException {
      markTestSkipped('Postgres not reachable — start PostgreSQL at localhost:5432');
      return null;
    }
    return pool;
  }

  group('hand-off of the Dart gate unit', () {
    test(
        'T1: a release that wakes a waiter hands it the slot, even if a '
        'newcomer runs first', () async {
      final pool = await open(
          maxSize: 1,
          reset: null,
          acquireTimeout: const Duration(milliseconds: 300));
      if (pool == null) return;

      final holder = await pool.acquire();
      final waiter = pool.acquire();
      expect(pool.pending, 1);

      final sw = Stopwatch()..start();
      final rel = holder.release();
      late final Future<PooledConnection> newcomer;
      scheduleMicrotask(() => newcomer = pool.acquire());
      await rel;

      final w = await waiter;
      expect(sw.elapsedMilliseconds, lessThan(100),
          reason: 'the native probe must not block the isolate');
      await w.release();
      final n = await newcomer;
      await n.release();

      expect(pool.borrowed, 0);
      expect(pool.idle, 1);
      expect(pool.pending, 0);

      final again = Stopwatch()..start();
      await (await pool.acquire()).release();
      expect(again.elapsedMilliseconds, lessThan(100),
          reason: 'capacity must be intact after the race');
      await pool.close();
    });

    test(
        'T2: default reset, 32 workers on a pool of 2: no native exception, '
        'no exhaustion, capacity intact', () async {
      final problems = <String>[];
      for (var round = 1; round <= 3 && problems.isEmpty; round++) {
        final pool =
            await open(maxSize: 2, acquireTimeout: const Duration(seconds: 2));
        if (pool == null) return;

        var nativeTimeouts = 0, exhausted = 0, other = 0;
        Future<void> worker() async {
          for (var i = 0; i < 100; i++) {
            PooledConnection conn;
            try {
              conn = await pool.acquire();
            } on NativePoolAcquireTimeoutException {
              nativeTimeouts++;
              continue;
            } on PoolExhaustedException {
              exhausted++;
              continue;
            } on Object {
              other++;
              continue;
            }
            try {
              (await PostgresQueryExecutor(b, conn.raw).execute('SELECT 1'))
                  .release();
            } finally {
              await conn.release();
            }
          }
        }

        await Future.wait([for (var w = 0; w < 32; w++) worker()]);

        if (nativeTimeouts + exhausted + other > 0) {
          problems.add('round $round: nativeTimeouts=$nativeTimeouts '
              'exhausted=$exhausted other=$other');
        }
        if (pool.borrowed != 0 || pool.idle != 2 || pool.pending != 0) {
          problems.add('round $round: borrowed=${pool.borrowed} '
              'idle=${pool.idle} pending=${pool.pending}');
        }
        // Capacity probe: both units must be holdable at once.
        var held = 0;
        final probe = <PooledConnection>[];
        try {
          for (var i = 0; i < 2; i++) {
            probe.add(await pool.acquire());
            held++;
          }
        } on Object catch (e) {
          problems.add('round $round: capacity probe held $held/2 ($e)');
        } finally {
          for (final c in probe) {
            await c.release();
          }
        }
        await pool.close();
      }
      expect(problems, isEmpty);
    });

    test('T3: a waiter that times out does not lose a unit', () async {
      final pool = await open(
          maxSize: 1, acquireTimeout: const Duration(milliseconds: 200));
      if (pool == null) return;

      final holder = await pool.acquire();
      await expectLater(pool.acquire(), throwsA(isA<PoolExhaustedException>()));
      expect(pool.pending, 0);

      await holder.release();
      expect(pool.borrowed, 0);
      expect(pool.idle, 1);
      await (await pool.acquire()).release();
      await pool.close();
    });
  });

  group('close() with waiters and borrowed connections', () {
    test('T5: close fails the waiters and waits for the borrowed connection',
        () async {
      final pool = await open(maxSize: 1);
      if (pool == null) return;

      final holder = await pool.acquire();
      final w1 =
          pool.acquire().then<Object>((c) => c, onError: (Object e) => e);
      final w2 =
          pool.acquire().then<Object>((c) => c, onError: (Object e) => e);
      expect(pool.pending, 2);

      var closed = false;
      final closing = pool.close().then((_) => closed = true);
      expect(await w1, isA<StateError>());
      expect(await w2, isA<StateError>());
      expect(pool.pending, 0);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(closed, isFalse,
          reason: 'close() must wait for the borrowed connection');

      await holder.release();
      await closing;
      expect(pool.isClosed, isTrue);
      expect(pool.nativePool, isNull);
      expect(pool.borrowed, 0);
    });

    test(
        'T6: close times out while a borrow is outstanding, destroy stays armed',
        () async {
      final pool = await open(maxSize: 1);
      if (pool == null) return;

      final held = await pool.acquire();
      await expectLater(pool.close(timeout: const Duration(milliseconds: 200)),
          throwsA(isA<TimeoutException>()));
      expect(pool.nativePool, isNotNull,
          reason: 'pool_destroy must not run while a borrow is outstanding');

      await held.release();
      await pool.close();
      expect(pool.nativePool, isNull);
      expect(pool.borrowed, 0);
    });

    test(
        'T7: close() landing anywhere between the hand-off and the waiter '
        'waking never surfaces a native error and never leaks', () async {
      for (var hops = 0; hops <= 6; hops++) {
        final pool = await open(
            maxSize: 1,
            reset: null,
            acquireTimeout: const Duration(seconds: 2));
        if (pool == null) return;

        final holder = await pool.acquire();
        final outcome =
            pool.acquire().then<Object>((c) => c, onError: (Object e) => e);

        final closing = Completer<void>();
        void after(int k, void Function() f) {
          if (k == 0) {
            f();
          } else {
            scheduleMicrotask(() => after(k - 1, f));
          }
        }

        final rel = holder.release();
        after(hops, () => pool.close().then(closing.complete));
        await rel;

        final result = await outcome;
        if (result is PooledConnection) {
          await result.release();
        } else {
          expect(result, isA<StateError>(), reason: 'hops=$hops');
          expect('$result', contains('Pool is closed'),
              reason: 'hops=$hops: $result');
        }
        await closing.future;
        expect(pool.borrowed, 0, reason: 'hops=$hops');
        expect(pool.nativePool, isNull, reason: 'hops=$hops');
      }
    });
  });
}
