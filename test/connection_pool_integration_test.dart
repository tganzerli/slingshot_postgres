/// Integration tests for `PostgresConnectionPool` against a real
/// PostgreSQL instance. Requires:
///   PostgreSQL at localhost:5432 (dbname=teste, user postgres, password 123).
/// Skips gracefully if connection fails.
library;

import 'dart:ffi' as ffi;

import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:slingshot_postgres/src/bindings/postgres_binding.dart';
import 'package:slingshot_postgres/src/native/postgres_native_pool.dart';
import 'package:slingshot_postgres/src/native/postgres_lib_loader.dart';
import 'package:test/test.dart';

const _connInfo =
    'host=localhost port=5432 dbname=teste user=postgres password=123';

void main() {
  PostgresBinding? binding;
  try {
    binding = PostgresBinding(loadNativeDb());
  } on StateError {
    binding = null;
  }

  if (binding == null) {
    test('skipped (native library not built)', () {
      markTestSkipped('libnative_db not available');
    });
    return;
  }

  group('PostgresConnectionPool integration', () {
    test('start opens maxSize eagerly, acquire/release round-trips, close cleans up',
        () async {
      // ABI MAJOR 2: pool_create allocates all `maxSize` conns + workers
      // at start; `minSize` is informational only.
      final pool = PostgresConnectionPool.withBinding(binding!, const PoolConfig(
          connInfo: _connInfo,
          minSize: 2,
          maxSize: 5,
          acquireTimeout: Duration(seconds: 2),
        ),
      );

      try {
        await pool.start();
      } on NativePoolStartupException {
        markTestSkipped('Postgres not reachable — start PostgreSQL at localhost:5432');
        return;
      }

      expect(pool.idle, 5, reason: 'all maxSize=5 conns are warm in MAJOR 2');
      expect(pool.borrowed, 0);

      // Acquire one, check counters, release.
      final c1 = await pool.acquire();
      expect(c1.raw, isNot(ffi.nullptr));
      expect(pool.borrowed, 1);
      expect(pool.idle, 4);
      await c1.release();
      expect(pool.borrowed, 0);
      expect(pool.idle, 5);

      // Subsequent acquire returns a valid (non-null) handle. In MAJOR 2
      // the C pool picks the first free slot via linear scan, so the
      // pointer may differ from c1.raw.
      final c2 = await pool.acquire();
      expect(c2.raw, isNot(ffi.nullptr));
      await c2.release();

      await pool.close();
      expect(pool.isClosed, isTrue);
    });

    test('grows up to maxSize under concurrent acquires', () async {
      final pool = PostgresConnectionPool.withBinding(binding!, const PoolConfig(
          connInfo: _connInfo,
          minSize: 1,
          maxSize: 5,
          acquireTimeout: Duration(seconds: 2),
        ),
      );

      try {
        await pool.start();
      } on NativePoolStartupException {
        markTestSkipped('Postgres not reachable — start PostgreSQL at localhost:5432');
        return;
      }

      // Fire 5 acquires concurrently.
      final acquired = await Future.wait(
        List.generate(5, (_) => pool.acquire()),
      );
      expect(pool.borrowed, 5);
      expect(pool.idle, 0);

      // Release all.
      for (final c in acquired) {
        await c.release();
      }
      expect(pool.borrowed, 0);
      expect(pool.idle, 5);

      await pool.close();
    });

    test('acquire timeout fires when pool is exhausted', () async {
      final pool = PostgresConnectionPool.withBinding(binding!, const PoolConfig(
          connInfo: _connInfo,
          minSize: 0,
          maxSize: 1,
          acquireTimeout: Duration(milliseconds: 200),
        ),
      );

      try {
        await pool.start();
      } on NativePoolStartupException {
        markTestSkipped('Postgres not reachable — start PostgreSQL at localhost:5432');
        return;
      }

      final c1 = await pool.acquire();
      // Use expectLater + await so the test blocks until the timeout
      // actually fires (200ms) instead of racing with `release()` below.
      await expectLater(
        pool.acquire(),
        throwsA(isA<PoolExhaustedException>()),
      );
      await c1.release();
      await pool.close();
    });

    test('waiter is unblocked when a connection is released', () async {
      final pool = PostgresConnectionPool.withBinding(binding!, const PoolConfig(
          connInfo: _connInfo,
          minSize: 0,
          maxSize: 1,
          acquireTimeout: Duration(seconds: 2),
        ),
      );

      try {
        await pool.start();
      } on NativePoolStartupException {
        markTestSkipped('Postgres not reachable — start PostgreSQL at localhost:5432');
        return;
      }

      final c1 = await pool.acquire();

      // Second acquire starts queued.
      final c2Future = pool.acquire();
      expect(pool.pending, 1);

      // Release the first; the waiter should receive a free conn from
      // the C pool. In MAJOR 2 the linear scan may not yield the same
      // pointer, so we just check it's a valid handle.
      await c1.release();
      final c2 = await c2Future;
      expect(c2.raw, isNot(ffi.nullptr),
          reason: 'released slot frees a waiter');

      await c2.release();
      await pool.close();
    });
  });
}
