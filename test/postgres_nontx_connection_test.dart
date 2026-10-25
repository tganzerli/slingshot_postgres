/// Correctness tests for the non-transactional fast-path
/// [withPostgresConnection].
///
/// Invariants:
///  * A read returns the right value with no transaction.
///  * A write AUTOCOMMITS (visible on a fresh connection, no explicit commit)
///    — proves there is no open transaction wrapping the body.
///  * N sequential calls reuse the pool without leaking connections.
///  * An exception in the body still releases the connection (pool not
///    exhausted afterwards).
///  * The Extended Query path (params + binaryResult) works in the fast-path.
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

void main() {
  if (!_canLoadNative()) {
    test('skipped (native library not built)', () {
      markTestSkipped('libnative_db not available');
    });
    return;
  }

  final b = _binding();
  late PostgresConnectionPool pool;
  var reachable = true;

  setUp(() async {
    pool = PostgresConnectionPool.withBinding(
      b,
      const PoolConfig(connInfo: _connInfo, minSize: 2, maxSize: 2),
    );
    try {
      await pool.start();
    } catch (_) {
      reachable = false;
      return;
    }
    await withTransaction(pool, (exec) async {
      (await exec.execute('DROP TABLE IF EXISTS pgnc')).release();
      (await exec.execute('CREATE TABLE pgnc (id INT PRIMARY KEY, v INT)'))
          .release();
      (await exec.execute('INSERT INTO pgnc (id, v) VALUES (1, 10), (2, 20)'))
          .release();
    });
  });

  tearDown(() async {
    if (reachable) await pool.close();
  });

  test('read returns the value without a transaction', () async {
    if (!reachable) return markTestSkipped('Postgres not reachable');
    final v = await withPostgresConnection<int>(pool, (exec) async {
      final rs = await exec.execute('SELECT v FROM pgnc WHERE id = 1');
      try {
        return rs.row(0).getInt('v')!;
      } finally {
        rs.release();
      }
    });
    expect(v, 10);
  });

  test('write autocommits (visible on a fresh connection, no commit)',
      () async {
    if (!reachable) return markTestSkipped('Postgres not reachable');
    await withPostgresConnection<void>(pool, (exec) async {
      (await exec.execute('INSERT INTO pgnc (id, v) VALUES (7, 70)')).release();
    });
    // Fresh acquisition — if it weren't autocommitted, this wouldn't see it.
    final v = await withPostgresConnection<int>(pool, (exec) async {
      final rs = await exec.execute('SELECT v FROM pgnc WHERE id = 7');
      try {
        return rs.row(0).getInt('v')!;
      } finally {
        rs.release();
      }
    });
    expect(v, 70);
  });

  test('N sequential reads reuse the pool without leaking', () async {
    if (!reachable) return markTestSkipped('Postgres not reachable');
    // maxSize=2; running many more calls than that proves connections are
    // released back each time (otherwise acquire would eventually time out).
    for (var i = 0; i < 50; i++) {
      final v = await withPostgresConnection<int>(pool, (exec) async {
        final rs = await exec.execute('SELECT v FROM pgnc WHERE id = 2');
        try {
          return rs.row(0).getInt('v')!;
        } finally {
          rs.release();
        }
      });
      expect(v, 20);
    }
  });

  test('exception in body still releases the connection', () async {
    if (!reachable) return markTestSkipped('Postgres not reachable');
    // Throw inside the body maxSize+1 times; if the conn leaked on throw,
    // the pool (maxSize=2) would exhaust and acquire would hang/timeout.
    for (var i = 0; i < 5; i++) {
      await expectLater(
        withPostgresConnection<void>(pool, (exec) async {
          throw StateError('boom');
        }),
        throwsA(isA<StateError>()),
      );
    }
    // Pool still usable after the throws.
    final v = await withPostgresConnection<int>(pool, (exec) async {
      final rs = await exec.execute('SELECT v FROM pgnc WHERE id = 1');
      try {
        return rs.row(0).getInt('v')!;
      } finally {
        rs.release();
      }
    });
    expect(v, 10);
  });

  test('Extended Query path (params + binaryResult) works in fast-path',
      () async {
    if (!reachable) return markTestSkipped('Postgres not reachable');
    final v = await withPostgresConnection<int>(pool, (exec) async {
      final rs = await exec.execute(
        'SELECT v FROM pgnc WHERE id = \$1',
        params: [Param.int4(2)],
        binaryResult: true,
      );
      try {
        return rs.row(0).getInt('v')!;
      } finally {
        rs.release();
      }
    });
    expect(v, 20);
  });
}
