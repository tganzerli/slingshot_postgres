/// Tests for the Postgres multi-read primitive (ABI MINOR 2, 2026-07-28).
///
/// `executeMultiRead` runs N read statements in one round-trip (Simple
/// Query Protocol multi-statement) and preserves the N result sets via
/// the per-conn chain. These tests verify order + values, mid-statement
/// error surfacing (with the real server message), the N=1 equivalence
/// to `execute`, the empty-list fast path, and the behavioral fix that
/// a SQL error on the single path now throws instead of returning an
/// empty result set.
library;

import 'dart:ffi' as ffi;

import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:slingshot_postgres/src/bindings/postgres_binding.dart';
import 'package:slingshot_postgres/src/native/postgres_lib_loader.dart';
import 'package:slingshot_postgres/src/postgres/postgres_query_executor.dart';
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
    const PoolConfig(connInfo: _connInfo, minSize: 1, maxSize: 1),
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

  group('Postgres multi-read (ABI MINOR 2)', () {
    late PostgresBinding b;
    late PostgresConnectionPool pool;

    setUp(() async {
      b = _binding();
      pool = await _freshPool(b).catchError((Object e) {
        markTestSkipped('Postgres not reachable: $e');
        throw e;
      });
    });

    tearDown(() async {
      await pool.close();
    });

    test('returns N result sets in statement order with correct values',
        () async {
      final leased = await pool.acquire();
      try {
        final exec = PostgresQueryExecutor(b, leased.raw);
        final results = await exec.executeMultiRead([
          'SELECT 1 AS a',
          "SELECT 'hello' AS b",
          'SELECT 2 AS c, 3 AS d',
        ]);
        expect(results, hasLength(3));
        expect(results[0].row(0).getInt('a'), 1);
        expect(results[1].row(0).getString('b'), 'hello');
        expect(results[2].row(0).getInt('c'), 2);
        expect(results[2].row(0).getInt('d'), 3);
        for (final rs in results) {
          rs.release();
        }
      } finally {
        await leased.release();
      }
    });

    test('N=1 is equivalent to execute', () async {
      final leased = await pool.acquire();
      try {
        final exec = PostgresQueryExecutor(b, leased.raw);
        final results = await exec.executeMultiRead(['SELECT 42 AS answer']);
        expect(results, hasLength(1));
        expect(results.single.row(0).getInt('answer'), 42);
        results.single.release();
      } finally {
        await leased.release();
      }
    });

    test('empty list returns empty list without a round-trip', () async {
      final leased = await pool.acquire();
      try {
        final exec = PostgresQueryExecutor(b, leased.raw);
        expect(await exec.executeMultiRead(const []), isEmpty);
      } finally {
        await leased.release();
      }
    });

    test('error in a later statement throws with the real server message',
        () async {
      final leased = await pool.acquire();
      try {
        final exec = PostgresQueryExecutor(b, leased.raw);
        await expectLater(
          exec.executeMultiRead([
            'SELECT 1',
            'SELECT * FROM a_table_that_does_not_exist_xyz',
            'SELECT 2',
          ]),
          throwsA(
            isA<QueryFailedException>().having(
              (e) => e.serverMessage,
              'serverMessage',
              contains('a_table_that_does_not_exist_xyz'),
            ),
          ),
        );
      } finally {
        await leased.release();
      }
    });

    test('conn stays usable after a multi-read error', () async {
      final leased = await pool.acquire();
      try {
        final exec = PostgresQueryExecutor(b, leased.raw);
        try {
          await exec
              .executeMultiRead(['SELECT bad_col FROM still_missing_xyz']);
          fail('expected QueryFailedException');
        } on QueryFailedException {
          // expected
        }
        // The chain was drained clean — a fresh query on the same conn
        // must succeed.
        final ok = await exec.executeMultiRead(['SELECT 7 AS v']);
        expect(ok.single.row(0).getInt('v'), 7);
        ok.single.release();
      } finally {
        await leased.release();
      }
    });

    test('SQL error on the single path now throws (behavioral fix)', () async {
      final leased = await pool.acquire();
      try {
        final exec = PostgresQueryExecutor(b, leased.raw);
        await expectLater(
          exec.execute('SELECT * FROM another_missing_table_xyz'),
          throwsA(isA<QueryFailedException>()),
        );
      } finally {
        await leased.release();
      }
    });

    test('EXECUTE of prepared statements works inside a multi-read', () async {
      // The TPC-C benchmark batches `EXECUTE <prepared>(...)` statements —
      // verify prepared statements compose with multi-statement Simple
      // Protocol on the same conn.
      final leased = await pool.acquire();
      try {
        final exec = PostgresQueryExecutor(b, leased.raw);
        await exec.execute('PREPARE mr_p1 (int) AS SELECT \$1::int AS v');
        await exec.execute('PREPARE mr_p2 (int) AS SELECT \$1::int * 10 AS v');
        final rs = await exec.executeMultiRead([
          'EXECUTE mr_p1(3)',
          'EXECUTE mr_p2(4)',
        ]);
        expect(rs, hasLength(2));
        expect(rs[0].row(0).getInt('v'), 3);
        expect(rs[1].row(0).getInt('v'), 40);
        for (final r in rs) {
          r.release();
        }
      } finally {
        await leased.release();
      }
    });

    test('a successful single query still returns rows', () async {
      final leased = await pool.acquire();
      try {
        final exec = PostgresQueryExecutor(b, leased.raw);
        final rs = await exec.execute('SELECT 99 AS n');
        expect(rs.row(0).getInt('n'), 99);
        rs.release();
      } finally {
        await leased.release();
      }
    });
  });
}
