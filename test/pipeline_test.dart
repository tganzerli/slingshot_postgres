/// Tests for libpq pipeline mode (ABI MINOR 1 of MAJOR 1).
///
/// **v1 limitation:** pipeline drains+discards PGresults; tests verify
/// that side effects (row writes) happened, not result rows.
library;

import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:slingshot_postgres/src/bindings/postgres_binding.dart';
import 'package:slingshot_postgres/src/native/postgres_lib_loader.dart';
import 'package:slingshot_postgres/src/postgres/postgres_query_executor.dart';
import 'package:test/test.dart';

import 'dart:ffi' as ffi;

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

Future<void> _resetTable(PostgresBinding b, PostgresConnectionPool pool) async {
  await withTransaction(pool, (exec) async {
    await exec.execute('DROP TABLE IF EXISTS pipeline_test');
    await exec.execute('CREATE TABLE pipeline_test ('
        'id int4 PRIMARY KEY, payload text NOT NULL)');
  });
}

void main() {
  if (!_canLoadNative()) {
    test('skipped (native library not built)', () {
      markTestSkipped('libnative_db not available');
    });
    return;
  }

  group('Pipeline mode (ABI MINOR 1)', () {
    test('withPipelinedTransaction inserts N rows in 1 round-trip', () async {
      final b = _binding();
      final pool = await _freshPool(b).catchError((Object e) {
        markTestSkipped('Postgres not reachable: $e');
        throw e;
      });
      try {
        await _resetTable(b, pool);

        await withPipelinedTransaction(pool, [
          for (var i = 1; i <= 5; i++)
            "INSERT INTO pipeline_test (id, payload) VALUES ($i, 'row$i')",
        ]);

        // Verify rows are visible after pipeline commit.
        final rows = await withTransaction(pool, (exec) async {
          final rs = await exec
              .execute('SELECT id, payload FROM pipeline_test ORDER BY id');
          final list = rs.rows.map((r) => r.toMap()).toList();
          rs.release();
          return list;
        });

        expect(rows.length, 5);
        expect(rows.first['id'], 1);
        expect(rows.last['payload'], 'row5');
      } finally {
        await pool.close();
      }
    });

    test('empty queries list is a no-op', () async {
      final b = _binding();
      final pool = await _freshPool(b).catchError((Object e) {
        markTestSkipped('Postgres not reachable: $e');
        throw e;
      });
      try {
        // No exception even with empty list.
        await withPipelinedTransaction(pool, []);
      } finally {
        await pool.close();
      }
    });

    test('single query pipeline degenerate case works', () async {
      final b = _binding();
      final pool = await _freshPool(b).catchError((Object e) {
        markTestSkipped('Postgres not reachable: $e');
        throw e;
      });
      try {
        await _resetTable(b, pool);

        await withPipelinedTransaction(pool, [
          "INSERT INTO pipeline_test (id, payload) VALUES (42, 'single')",
        ]);

        final rows = await withTransaction(pool, (exec) async {
          final rs =
              await exec.execute('SELECT id FROM pipeline_test WHERE id = 42');
          final list = rs.rows.map((r) => r.toMap()).toList();
          rs.release();
          return list;
        });
        expect(rows.length, 1);
        expect(rows.first['id'], 42);
      } finally {
        await pool.close();
      }
    });

    test('error mid-pipeline aborts transaction (no rows persisted)', () async {
      final b = _binding();
      final pool = await _freshPool(b).catchError((Object e) {
        markTestSkipped('Postgres not reachable: $e');
        throw e;
      });
      try {
        await _resetTable(b, pool);

        // 2nd query has a PRIMARY KEY violation (duplicate id 1).
        // libpq pipeline semantics: queries after the failure get
        // PGRES_PIPELINE_ABORTED. The COMMIT in BEGIN+inserts+COMMIT
        // then becomes a ROLLBACK effectively.
        await withPipelinedTransaction(pool, [
          "INSERT INTO pipeline_test (id, payload) VALUES (1, 'first')",
          "INSERT INTO pipeline_test (id, payload) VALUES (1, 'duplicate')",
          "INSERT INTO pipeline_test (id, payload) VALUES (2, 'second')",
        ]);

        // After the pipeline returns, no rows should remain — the
        // transaction was aborted by the duplicate-key error.
        final rows = await withTransaction(pool, (exec) async {
          final rs =
              await exec.execute('SELECT COUNT(*) AS n FROM pipeline_test');
          final n = rs.row(0).getInt('n')!;
          rs.release();
          return n;
        });
        expect(rows, 0, reason: 'pipeline transaction must roll back on error');
      } finally {
        await pool.close();
      }
    });

    test('executePipeline composes inside an external withTransaction',
        () async {
      final b = _binding();
      final pool = await _freshPool(b).catchError((Object e) {
        markTestSkipped('Postgres not reachable: $e');
        throw e;
      });
      try {
        await _resetTable(b, pool);

        // The external transaction owns BEGIN/COMMIT; the pipeline carries
        // only the writes. Before the INERROR-only fix, the native pipeline
        // primitive force-rolled-back the still-open (healthy) transaction,
        // so the outer COMMIT persisted nothing (0 rows + WARNING).
        await withTransaction(pool, (exec) async {
          await (exec as PostgresQueryExecutor).executePipeline([
            "INSERT INTO pipeline_test (id, payload) VALUES (1, 'a')",
            "INSERT INTO pipeline_test (id, payload) VALUES (2, 'b')",
          ]);
        });

        final n = await withTransaction(pool, (exec) async {
          final rs =
              await exec.execute('SELECT COUNT(*) AS n FROM pipeline_test');
          final v = rs.row(0).getInt('n')!;
          rs.release();
          return v;
        });
        expect(n, 2,
            reason: 'writes pipelined inside an external transaction '
                'must survive until the outer COMMIT');
      } finally {
        await pool.close();
      }
    });

    test('error inside executePipeline in external txn persists nothing',
        () async {
      final b = _binding();
      final pool = await _freshPool(b).catchError((Object e) {
        markTestSkipped('Postgres not reachable: $e');
        throw e;
      });
      try {
        await _resetTable(b, pool);

        // A duplicate-key error inside the pipeline aborts the surrounding
        // transaction (INERROR → native ROLLBACK), so nothing persists.
        // Whether that error surfaces as a Dart exception is a separate,
        // pre-existing gap (the pipeline drain does not inspect
        // PQresultStatus) tracked as a follow-up — this test pins only the
        // persistence invariant and tolerates either outcome.
        try {
          await withTransaction(pool, (exec) async {
            await (exec as PostgresQueryExecutor).executePipeline([
              "INSERT INTO pipeline_test (id, payload) VALUES (1, 'first')",
              "INSERT INTO pipeline_test (id, payload) VALUES (1, 'duplicate')",
            ]);
          });
        } catch (_) {
          // Tolerated: once the error-surfacing gap is closed, this fires.
        }

        final n = await withTransaction(pool, (exec) async {
          final rs =
              await exec.execute('SELECT COUNT(*) AS n FROM pipeline_test');
          final v = rs.row(0).getInt('n')!;
          rs.release();
          return v;
        });
        expect(n, 0,
            reason: 'a failed pipeline inside a transaction must persist '
                'nothing');
      } finally {
        await pool.close();
      }
    });
  });
}
