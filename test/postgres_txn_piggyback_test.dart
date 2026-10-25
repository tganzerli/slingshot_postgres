/// Tests for the BEGIN-piggyback transaction path.
///
/// The Postgres `UnitOfWork` defers `BEGIN` and fuses it into the first
/// statement of the body (`BEGIN;<sql>` in one round-trip on the Simple
/// Protocol, reusing the ABI MINOR 2 multi-read primitive). When that
/// first statement uses the Extended Protocol, the BEGIN rides the same
/// libpq pipeline under one Sync (ABI MINOR 5, 2026-10-09), or is sent
/// standalone with an older library. These tests cover the full case
/// matrix:
/// Simple/Extended first statement, error/timeout on the fused
/// statement, empty transactions (`BEGIN;COMMIT` / `BEGIN;ROLLBACK`),
/// `executeMultiRead`/`executePipeline` as the first submit (with error
/// indexing offset by the prepended BEGIN), and the `TransactionStateError`
/// contract. Write-visibility is asserted across a second logical
/// transaction to prove the explicit BEGIN opened a real transaction
/// (i.e. ROLLBACK actually undoes the fused write).
library;

import 'dart:ffi' as ffi;

import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:slingshot_postgres/src/bindings/postgres_binding.dart';
import 'package:slingshot_postgres/src/native/postgres_lib_loader.dart';
import 'package:slingshot_postgres/src/postgres/postgres_query_executor.dart';
import 'package:test/test.dart';

const _connInfo =
    'host=localhost port=5432 dbname=teste user=postgres password=123';
const _missing = 'no_such_table_p5_piggyback_xyz';

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

/// Runs [sql] in autocommit on a freshly acquired conn (no transaction).
Future<void> _autocommit(PostgresConnectionPool pool, String sql) async {
  final leased = await pool.acquire();
  try {
    (await PostgresQueryExecutor(pool.binding, leased.raw).execute(sql))
        .release();
  } finally {
    await leased.release();
  }
}

/// Reads committed state on a second logical transaction: how many rows
/// with [id] are visible in `p5_scratch`.
Future<int> _count(PostgresConnectionPool pool, int id) async {
  final leased = await pool.acquire();
  try {
    final rs = await PostgresQueryExecutor(pool.binding, leased.raw)
        .execute('SELECT count(*)::int AS n FROM p5_scratch WHERE id=$id');
    final n = rs.row(0).getInt('n')!;
    rs.release();
    return n;
  } finally {
    await leased.release();
  }
}

void main() {
  if (!_canLoadNative()) {
    test('skipped (native library not built)', () {
      markTestSkipped('libnative_db not available');
    });
    return;
  }

  group('Postgres BEGIN piggyback', () {
    late PostgresBinding b;
    late PostgresConnectionPool pool;

    setUp(() async {
      b = _binding();
      pool = await _freshPool(b).catchError((Object e) {
        markTestSkipped('Postgres not reachable: $e');
        throw e;
      });
      await _autocommit(pool,
          'CREATE TABLE IF NOT EXISTS p5_scratch(id int primary key, v int)');
      await _autocommit(pool, 'TRUNCATE p5_scratch');
    });

    tearDown(() async {
      try {
        await _autocommit(pool, 'DROP TABLE IF EXISTS p5_scratch');
      } catch (_) {
        // A prior test may have left the single conn in an undefined
        // state (timeout/cancel); best-effort cleanup.
      }
      await pool.close();
    });

    // ── Case 1: Simple first statement OK; ROLLBACK undoes the fused
    //    write (proves the explicit BEGIN dominated the multi-statement
    //    implicit transaction). ──
    test('Simple first statement: fused BEGIN, rollback undoes the write',
        () async {
      final uow = PostgresUnitOfWork(pool);
      await uow.begin();
      (await uow.executor.execute('INSERT INTO p5_scratch(id,v) VALUES (1,10)'))
          .release();
      await uow.rollback();
      await uow.close();
      expect(await _count(pool, 1), 0, reason: 'fused write must roll back');
    });

    test('Simple first statement: commit makes the fused write visible',
        () async {
      final uow = PostgresUnitOfWork(pool);
      await uow.begin();
      (await uow.executor.execute('INSERT INTO p5_scratch(id,v) VALUES (2,20)'))
          .release();
      await uow.commit();
      await uow.close();
      expect(await _count(pool, 2), 1);
    });

    // ── Case 2: Extended first statement (bound params) → BEGIN fused in
    //    the same pipeline (ABI MINOR 5); still transactional. ──
    test('Extended first statement: fused BEGIN, rollback undoes', () async {
      final uow = PostgresUnitOfWork(pool);
      await uow.begin();
      (await uow.executor.execute(
        'INSERT INTO p5_scratch(id,v) VALUES (\$1,\$2)',
        params: [Param.int4(3), Param.int4(30)],
      ))
          .release();
      await uow.rollback();
      await uow.close();
      expect(await _count(pool, 3), 0);
    });

    test('Extended first statement: commit makes the write visible', () async {
      final uow = PostgresUnitOfWork(pool);
      await uow.begin();
      (await uow.executor.execute(
        'INSERT INTO p5_scratch(id,v) VALUES (\$1,\$2)',
        params: [Param.int4(4), Param.int4(40)],
      ))
          .release();
      await uow.commit();
      await uow.close();
      expect(await _count(pool, 4), 1);
    });

    test('Extended first statement: binary result decodes', () async {
      final uow = PostgresUnitOfWork(pool);
      await uow.begin();
      final rs = await uow.executor.execute(
        'SELECT \$1::int4 + 1 AS v',
        params: [Param.int4(41)],
        binaryResult: true,
      );
      expect(rs.row(0).getInt('v'), 42);
      rs.release();
      await uow.rollback();
      await uow.close();
    });

    test('Extended first statement: older-library fallback still works',
        () async {
      PostgresQueryExecutor.debugForceStandaloneBegin = true;
      try {
        final uow = PostgresUnitOfWork(pool);
        await uow.begin();
        (await uow.executor.execute(
          'INSERT INTO p5_scratch(id,v) VALUES (\$1,\$2)',
          params: [Param.int4(5), Param.int4(50)],
        ))
            .release();
        await uow.rollback();
        await uow.close();
        expect(await _count(pool, 5), 0);
      } finally {
        PostgresQueryExecutor.debugForceStandaloneBegin = false;
      }
    });

    // ── Case 2b: error on the fused Extended first statement. The BEGIN
    //    ran, so the transaction is open and aborted; ROLLBACK recovers
    //    and the conn left pipeline mode (a simple query works). ──
    test('error on fused Extended first statement keeps the conn usable',
        () async {
      final leased = await pool.acquire();
      try {
        final exec = PostgresQueryExecutor(pool.binding, leased.raw,
            deferredBegin: true);
        await expectLater(
          exec.execute('SELECT * FROM $_missing WHERE id = \$1',
              params: [Param.int4(1)]),
          throwsA(isA<QueryFailedException>().having(
              (e) => e.serverMessage, 'serverMessage', contains(_missing))),
        );
        (await exec.execute('ROLLBACK')).release();
        final rs = await exec.execute('SELECT 6 AS v');
        expect(rs.row(0).getInt('v'), 6);
        rs.release();
      } finally {
        await leased.release();
      }
    });

    // ── Case 2c: the fused BEGIN itself fails. A conn already inside an
    //    aborted transaction rejects BEGIN; the statement after it must
    //    be skipped (PIPELINE_ABORTED), so the error names BEGIN. ──
    test('failed fused BEGIN surfaces as BEGIN and skips the statement',
        () async {
      final leased = await pool.acquire();
      try {
        final raw = PostgresQueryExecutor(pool.binding, leased.raw);
        (await raw.execute('BEGIN')).release();
        await expectLater(raw.execute('SELECT * FROM $_missing'),
            throwsA(isA<QueryFailedException>()));
        // Conn is now INERROR: a deferred-BEGIN executor's BEGIN fails.
        final exec = PostgresQueryExecutor(pool.binding, leased.raw,
            deferredBegin: true);
        await expectLater(
          exec.execute('INSERT INTO p5_scratch(id,v) VALUES (\$1,\$2)',
              params: [Param.int4(6), Param.int4(60)]),
          throwsA(
              isA<QueryFailedException>().having((e) => e.sql, 'sql', 'BEGIN')),
        );
        (await raw.execute('ROLLBACK')).release();
        final rs = await raw.execute('SELECT 7 AS v');
        expect(rs.row(0).getInt('v'), 7);
        rs.release();
      } finally {
        await leased.release();
      }
      expect(await _count(pool, 6), 0);
    });

    // ── Case 2d: timeout on the fused Extended first statement. The
    //    worker cancels and drains to the Sync, so the SAME conn is still
    //    usable afterwards (not stuck in pipeline mode). ──
    test('timeout on fused Extended first statement leaves the conn usable',
        () async {
      final localPool = await _freshPool(b);
      try {
        final leased = await localPool.acquire();
        try {
          final exec = PostgresQueryExecutor(localPool.binding, leased.raw,
              timeout: const Duration(milliseconds: 300), deferredBegin: true);
          await expectLater(
            exec.execute('SELECT pg_sleep(\$1)', params: [Param.float8(3)]),
            throwsA(isA<QueryTimeoutException>()),
          );
          final after = PostgresQueryExecutor(localPool.binding, leased.raw);
          (await after.execute('ROLLBACK')).release();
          final rs = await after.execute('SELECT 8 AS v');
          expect(rs.row(0).getInt('v'), 8);
          rs.release();
        } finally {
          await leased.release();
        }
      } finally {
        await localPool.close();
      }
    });

    // ── Case 3: error on the fused first statement. Server is left in an
    //    aborted (but open) transaction; ROLLBACK recovers and the conn
    //    is reusable. ──
    test('error on fused first statement throws with real server message',
        () async {
      final leased = await pool.acquire();
      try {
        final exec = PostgresQueryExecutor(pool.binding, leased.raw,
            deferredBegin: true);
        await expectLater(
          exec.execute('SELECT * FROM $_missing'),
          throwsA(isA<QueryFailedException>().having(
              (e) => e.serverMessage, 'serverMessage', contains(_missing))),
        );
        // The BEGIN succeeded → the transaction is open and aborted.
        // ROLLBACK closes it; the conn is then reusable.
        (await exec.execute('ROLLBACK')).release();
        final rs = await exec.execute('SELECT 5 AS v');
        expect(rs.row(0).getInt('v'), 5);
        rs.release();
      } finally {
        await leased.release();
      }
    });

    // ── Case 4: error on a SUBSEQUENT statement (unchanged behavior). ──
    test('error on a later statement rolls back the fused write', () async {
      final uow = PostgresUnitOfWork(pool);
      await uow.begin();
      (await uow.executor.execute('INSERT INTO p5_scratch(id,v) VALUES (7,70)'))
          .release(); // fuses BEGIN
      await expectLater(
        uow.executor.execute('SELECT * FROM $_missing'),
        throwsA(isA<QueryFailedException>()),
      );
      await uow.rollback();
      await uow.close();
      expect(await _count(pool, 7), 0);
    });

    // ── Case 5: empty transaction + commit → BEGIN;COMMIT fused. ──
    test('empty transaction commit succeeds (BEGIN;COMMIT fused)', () async {
      final uow = PostgresUnitOfWork(pool);
      await uow.begin();
      expect(uow.isActive, isTrue);
      await uow.commit();
      expect(uow.isActive, isFalse);
      await uow.close();
    });

    // ── Case 6: empty transaction + rollback/close → BEGIN;ROLLBACK. ──
    test('empty transaction rollback succeeds (BEGIN;ROLLBACK fused)',
        () async {
      final uow = PostgresUnitOfWork(pool);
      await uow.begin();
      await uow.rollback();
      expect(uow.isActive, isFalse);
      await uow.close();
    });

    test('empty transaction close (no commit/rollback) is best-effort',
        () async {
      final uow = PostgresUnitOfWork(pool);
      await uow.begin();
      await uow.close(); // best-effort ROLLBACK, fused with BEGIN
      expect(uow.isActive, isFalse);
    });

    // ── Case 7: executeMultiRead as the first submit. ──
    test('executeMultiRead as first submit: N results, BEGIN consumed',
        () async {
      final leased = await pool.acquire();
      try {
        final exec = PostgresQueryExecutor(pool.binding, leased.raw,
            deferredBegin: true);
        final rs =
            await exec.executeMultiRead(['SELECT 1 AS a', 'SELECT 2 AS b']);
        expect(rs, hasLength(2));
        expect(rs[0].row(0).getInt('a'), 1);
        expect(rs[1].row(0).getInt('b'), 2);
        for (final r in rs) {
          r.release();
        }
        // Close the transaction opened by the fused BEGIN.
        (await exec.execute('ROLLBACK')).release();
      } finally {
        await leased.release();
      }
    });

    test('executeMultiRead error names the right statement (BEGIN offset)',
        () async {
      final leased = await pool.acquire();
      try {
        final exec = PostgresQueryExecutor(pool.binding, leased.raw,
            deferredBegin: true);
        await expectLater(
          exec.executeMultiRead(['SELECT 1', 'SELECT * FROM $_missing']),
          throwsA(isA<QueryFailedException>()
              .having((e) => e.sql, 'sql', contains(_missing))),
        );
      } finally {
        await leased.release();
      }
    });

    test('executeMultiRead with empty list still opens the transaction',
        () async {
      final leased = await pool.acquire();
      try {
        final exec = PostgresQueryExecutor(pool.binding, leased.raw,
            deferredBegin: true);
        expect(await exec.executeMultiRead(const []), isEmpty);
        // A standalone BEGIN was sent; ROLLBACK must find an open txn
        // (no "no transaction in progress" error path exercised here —
        // just that the conn is coherent).
        (await exec.execute('ROLLBACK')).release();
        final rs = await exec.execute('SELECT 1 AS v');
        expect(rs.row(0).getInt('v'), 1);
        rs.release();
      } finally {
        await leased.release();
      }
    });

    // ── Case 8: executePipeline as the first submit consumes the
    //    deferred BEGIN (standalone, not fused — the pipeline primitive
    //    force-rolls-back any txn still open at its end, a PRE-EXISTING
    //    behavior since ABI MAJOR 2, orthogonal to the fused BEGIN). We assert the
    //    fused-BEGIN property: the pending BEGIN is consumed exactly once
    //    and the connection stays coherent for the next statement. ──
    test('executePipeline as first submit consumes the deferred BEGIN once',
        () async {
      final leased = await pool.acquire();
      try {
        final exec = PostgresQueryExecutor(pool.binding, leased.raw,
            deferredBegin: true);
        await exec
            .executePipeline(['INSERT INTO p5_scratch(id,v) VALUES (8,80)']);
        // The pending BEGIN must have been consumed: the next execute is
        // a plain statement, not a second (fused) BEGIN, and the conn is
        // coherent.
        final rs = await exec.execute('SELECT 1 AS v');
        expect(rs.row(0).getInt('v'), 1);
        rs.release();
      } finally {
        await leased.release();
      }
    });

    // ── Case 9: timeout on the fused first statement. Isolated to a
    //    local pool so the cancelled conn doesn't contaminate teardown. ──
    test('timeout on fused first statement throws QueryTimeoutException',
        () async {
      final localPool = await _freshPool(b);
      try {
        final leased = await localPool.acquire();
        final exec = PostgresQueryExecutor(localPool.binding, leased.raw,
            timeout: const Duration(milliseconds: 300), deferredBegin: true);
        await expectLater(
          exec.execute('SELECT pg_sleep(3)'),
          throwsA(isA<QueryTimeoutException>()),
        );
        await leased.release();
      } finally {
        await localPool.close();
      }
    });

    // ── Case 10: TransactionStateError contract (regression). ──
    test(
        'state contract: executor before begin, double begin, commit w/o begin',
        () async {
      final uow = PostgresUnitOfWork(pool);
      expect(() => uow.executor, throwsA(isA<TransactionStateError>()));
      expect(uow.commit, throwsA(isA<TransactionStateError>()));
      expect(uow.rollback, throwsA(isA<TransactionStateError>()));

      await uow.begin();
      expect(uow.begin, throwsA(isA<TransactionStateError>()));
      await uow.rollback();
      await uow.close();
    });
  });
}
