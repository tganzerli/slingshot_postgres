/// An error in any statement of a multi-statement string sent through the
/// Simple Query Protocol (no params, text results) must throw.
///
/// The server runs the statements up to the first failing one and returns
/// one result per statement run, so an error past the first statement is
/// the last result. Only the head used to be inspected: inside a
/// transaction the error surfaced on the next query as "current transaction
/// is aborted"; outside one the implicit transaction was rolled back and
/// `execute` returned normally.
///
/// Covers the three Simple-protocol entry points: plain dispatch, the
/// dispatch fused with the deferred BEGIN, and the one fused with the
/// deferred session reset.
library;

import 'dart:ffi' as ffi;

import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:slingshot_postgres/src/bindings/postgres_binding.dart';
import 'package:slingshot_postgres/src/native/postgres_lib_loader.dart';
import 'package:test/test.dart';

const _connInfo =
    'host=localhost port=5432 dbname=teste user=postgres password=123';

const _missing = 'a6_missing_table';

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

Matcher _failsOnMissingTable() => throwsA(isA<QueryFailedException>()
    .having((e) => e.serverMessage, 'serverMessage', contains(_missing)));

Future<int> _count(PostgresQueryExecutorContract exec) async {
  final rs = await exec.execute('SELECT count(*)::int4 AS n FROM a6_t');
  try {
    return rs.row(0).getInt('n')!;
  } finally {
    rs.release();
  }
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

  Future<PostgresConnectionPool> open({bool deferReset = false}) async {
    final p = PostgresConnectionPool.withBinding(
      b,
      PoolConfig(
          connInfo: _connInfo,
          minSize: 1,
          maxSize: 1,
          deferSessionReset: deferReset),
    );
    await p.start();
    return p;
  }

  setUp(() async {
    try {
      pool = await open();
    } catch (_) {
      reachable = false;
      return;
    }
    await withTransaction(pool, (exec) async {
      (await exec.execute('DROP TABLE IF EXISTS a6_t')).release();
      (await exec.execute('CREATE TABLE a6_t (id INT PRIMARY KEY)')).release();
    });
  });

  tearDown(() async {
    if (reachable) await pool.close();
  });

  test('inside a transaction, first statement after begin (fused BEGIN)',
      () async {
    if (!reachable) return markTestSkipped('Postgres not reachable');
    final uow = PostgresUnitOfWork(pool);
    await uow.begin();
    try {
      await expectLater(
          uow.executor.execute('SELECT 1; SELECT * FROM $_missing'),
          _failsOnMissingTable());
    } finally {
      await uow.rollback();
    }
  });

  test('inside a transaction, after a statement already ran (plain Simple)',
      () async {
    if (!reachable) return markTestSkipped('Postgres not reachable');
    final uow = PostgresUnitOfWork(pool);
    await uow.begin();
    try {
      (await uow.executor.execute('SELECT 1')).release();
      await expectLater(
          uow.executor.execute('SELECT 1; SELECT * FROM $_missing'),
          _failsOnMissingTable());
    } finally {
      await uow.rollback();
    }
  });

  test(
      'outside a transaction, the rolled-back write throws and the '
      'connection stays usable', () async {
    if (!reachable) return markTestSkipped('Postgres not reachable');
    await withPostgresConnection<void>(pool, (exec) async {
      await expectLater(
          exec.execute('INSERT INTO a6_t VALUES (1); SELECT * FROM $_missing'),
          _failsOnMissingTable());
      // Same connection: the implicit transaction undid the INSERT.
      expect(await _count(exec), 0);
    });
  });

  test('fused with the deferred session reset', () async {
    if (!reachable) return markTestSkipped('Postgres not reachable');
    final deferred = await open(deferReset: true);
    try {
      // First borrow marks the connection; the second one carries the reset
      // as a prefix of its first statement.
      await withPostgresConnection<void>(deferred, (exec) async {
        (await exec.execute('SELECT 1')).release();
      });
      await withPostgresConnection<void>(deferred, (exec) async {
        await expectLater(
            exec.execute(
                'INSERT INTO a6_t VALUES (1); SELECT * FROM $_missing'),
            _failsOnMissingTable());
        expect(await _count(exec), 0);
      });
    } finally {
      await deferred.close();
    }
  });

  test('success still returns the first statement result', () async {
    if (!reachable) return markTestSkipped('Postgres not reachable');
    await withPostgresConnection<void>(pool, (exec) async {
      final rs = await exec.execute('SELECT 1 AS a; SELECT 2 AS b');
      try {
        expect(rs.row(0).getInt('a'), 1);
      } finally {
        rs.release();
      }
    });
  });

  test('an error in the first statement still throws', () async {
    if (!reachable) return markTestSkipped('Postgres not reachable');
    await withPostgresConnection<void>(pool, (exec) async {
      await expectLater(exec.execute('SELECT * FROM $_missing; SELECT 1'),
          _failsOnMissingTable());
    });
  });
}
