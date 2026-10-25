/// Unit tests for `PostgresConnectionPool` static surface +
/// fail-fast behaviour on unreachable hosts.
///
/// ABI MAJOR 2 (2026-05-20): `pool_create` is eager — it opens all
/// `maxSize` conns up-front, so any unreachable host throws
/// [NativePoolStartupException] regardless of `minSize`. The MAJOR 1
/// "lazy minSize=0" path is gone.
library;

import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:slingshot_postgres/src/bindings/postgres_binding.dart';
import 'package:slingshot_postgres/src/native/postgres_native_pool.dart';
import 'package:slingshot_postgres/src/native/postgres_lib_loader.dart';
import 'package:test/test.dart';

PostgresBinding? _loadBinding() {
  try {
    return PostgresBinding(loadNativeDb());
  } on StateError {
    return null;
  }
}

void main() {
  group('PoolConfig', () {
    test('default values are sensible', () {
      const cfg = PoolConfig(connInfo: 'fake');
      expect(cfg.minSize, 2);
      expect(cfg.maxSize, 10);
      expect(cfg.acquireTimeout, const Duration(seconds: 5));
    });

    test('asserts minSize <= maxSize', () {
      expect(
        () => PoolConfig(connInfo: 'fake', minSize: 5, maxSize: 3),
        throwsA(isA<AssertionError>()),
      );
    });

    test('asserts maxSize > 0', () {
      expect(
        () => PoolConfig(connInfo: 'fake', minSize: 0, maxSize: 0),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('PoolExhaustedException', () {
    test('toString includes the timeout', () {
      final e = PoolExhaustedException(const Duration(seconds: 2));
      expect(e.toString(), contains('2'));
    });
  });

  group('PostgresConnectionPool fail-fast on unreachable host', () {
    final binding = _loadBinding();
    if (binding == null) {
      test('skipped (native library not built)', () {
        markTestSkipped('libnative_db not available');
      });
      return;
    }

    // ABI MAJOR 2: `pool_create` opens every `maxSize` conn eagerly
    // — even with `minSize=0`. An unreachable host therefore surfaces
    // as `NativePoolStartupException` at `start()`.
    const unreachable =
        'host=127.0.0.1 port=1 connect_timeout=1 dbname=x user=x password=x';

    test('start fails with NativePoolStartupException', () async {
      final pool = PostgresConnectionPool.withBinding(binding, const PoolConfig(connInfo: unreachable, minSize: 0, maxSize: 2),
      );
      await expectLater(
        pool.start(),
        throwsA(isA<NativePoolStartupException>()),
      );
    });

    test('start with minSize > 0 also fails (no lazy fallback)', () async {
      final pool = PostgresConnectionPool.withBinding(binding, const PoolConfig(connInfo: unreachable, minSize: 1, maxSize: 2),
      );
      await expectLater(
        pool.start(),
        throwsA(isA<NativePoolStartupException>()),
      );
    });
  });
}
