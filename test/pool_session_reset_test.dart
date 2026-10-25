/// Integration tests for the session reset on release
/// (`PoolConfig.sessionResetQuery`). With `maxSize: 1` every borrow gets the
/// same connection, so whatever one borrower leaves in the session is what
/// the next one would inherit. A downstream consumer measured this leak
/// through this connector.
/// Requires the dev Postgres; skips if the native lib or server is missing.
library;

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

  // A one-connection pool, so consecutive borrows share the session.
  Future<PostgresConnectionPool?> open({String? reset = 'DISCARD ALL'}) async {
    final pool = PostgresConnectionPool.withBinding(
        b,
        PoolConfig(
            connInfo: _connInfo,
            minSize: 1,
            maxSize: 1,
            acquireTimeout: const Duration(seconds: 3),
            sessionResetQuery: reset));
    try {
      await pool.start();
    } on NativePoolStartupException {
      markTestSkipped('Postgres not reachable — start PostgreSQL at localhost:5432');
      return null;
    }
    return pool;
  }

  // One borrow: runs [sqls] in order and returns the first column of the
  // last statement's first row as text (null when there is no row).
  Future<String?> borrow(PostgresConnectionPool pool, List<String> sqls,
      {bool release = true}) async {
    final leased = await pool.acquire();
    final exec = PostgresQueryExecutor(b, leased.raw);
    String? out;
    try {
      for (final sql in sqls) {
        final rs = await exec.execute(sql);
        out = rs.rowCount > 0 && rs.colCount > 0
            ? rs.row(0).getString('v')
            : null;
        rs.release();
      }
    } finally {
      if (release) await leased.release();
    }
    return out;
  }

  const pid = 'SELECT pg_backend_pid()::text AS v';
  const tenant = "SELECT current_setting('app.tenant_id', true) AS v";

  test('the default config resets with DISCARD ALL', () {
    expect(
        const PoolConfig(connInfo: _connInfo).sessionResetQuery, 'DISCARD ALL');
  });

  test('T3c: a session set_config does not reach the next borrower', () async {
    final pool = await open();
    if (pool == null) return;
    try {
      final pid1 = await borrow(pool, [
        "SELECT set_config('app.tenant_id', 'clinic-a', false) AS v",
        pid,
      ]);
      final pid2 = await borrow(pool, [pid]);
      expect(pid2, pid1, reason: 'same connection, reissued by the pool');
      expect(await borrow(pool, [tenant]), anyOf(isNull, isEmpty));
    } finally {
      await pool.close();
    }
  });

  test('control: with the reset off the value leaks (the old behaviour)',
      () async {
    final pool = await open(reset: null);
    if (pool == null) return;
    try {
      await borrow(pool, [
        "SELECT set_config('app.tenant_id', 'clinic-a', false) AS v",
      ]);
      expect(await borrow(pool, [tenant]), 'clinic-a');
    } finally {
      await pool.close();
    }
  });

  test('search_path, temp tables and session advisory locks are cleared',
      () async {
    final pool = await open();
    if (pool == null) return;
    try {
      await borrow(pool, [
        'SET search_path TO pg_catalog',
        'CREATE TEMP TABLE reset_probe (x int)',
        'SELECT pg_advisory_lock(424242)::text AS v',
      ]);
      expect(await borrow(pool, ["SELECT current_setting('search_path') AS v"]), isNot('pg_catalog'));
      expect(
          await borrow(pool, [
            "SELECT count(*)::text AS v FROM pg_class "
                "WHERE relname = 'reset_probe' AND relpersistence = 't'"
          ]),
          '0');
      expect(
          await borrow(pool, [
            'SELECT count(*)::text AS v FROM pg_locks '
                "WHERE locktype = 'advisory' AND objid = 424242 "
                'AND pid = pg_backend_pid()'
          ]),
          '0');
    } finally {
      await pool.close();
    }
  });

  test('a connection returned inside a transaction is rolled back', () async {
    final pool = await open();
    if (pool == null) return;
    try {
      await borrow(pool, [
        'CREATE TABLE IF NOT EXISTS reset_txn_probe (x int)',
        'TRUNCATE reset_txn_probe',
      ]);
      // BEGIN without COMMIT, then release: the misuse the reset now covers.
      await borrow(pool, ['BEGIN', 'INSERT INTO reset_txn_probe VALUES (1)']);
      // Not in a transaction any more: DISCARD ALL would refuse to run there.
      await borrow(pool, ['DISCARD ALL']);
      expect(
          await borrow(
              pool, ['SELECT count(*)::text AS v FROM reset_txn_probe']),
          '0');
    } finally {
      await borrow(pool, ['DROP TABLE IF EXISTS reset_txn_probe']);
      await pool.close();
    }
  });

  test('an aborted transaction is rolled back too', () async {
    final pool = await open();
    if (pool == null) return;
    try {
      final leased = await pool.acquire();
      final exec = PostgresQueryExecutor(b, leased.raw);
      (await exec.execute('BEGIN')).release();
      await expectLater(exec.execute('SELECT * FROM reset_missing_table'),
          throwsA(isA<QueryFailedException>()));
      await leased.release();
      expect(await borrow(pool, ["SELECT 'ok' AS v"]), 'ok');
    } finally {
      await pool.close();
    }
  });

  test('the reset deallocates SQL PREPARE; with it off the statement survives',
      () async {
    for (final (reset, survives) in [('DISCARD ALL', false), (null, true)]) {
      final pool = await open(reset: reset);
      if (pool == null) return;
      try {
        await borrow(pool, ["PREPARE reset_ps AS SELECT 'p'::text AS v"]);
        final found = await borrow(pool, [
          "SELECT count(*)::text AS v FROM pg_prepared_statements "
              "WHERE name = 'reset_ps'"
        ]);
        expect(found, survives ? '1' : '0', reason: 'reset=$reset');
      } finally {
        await pool.close();
      }
    }
  });

  test('a failing reset command still returns the slot and does not throw',
      () async {
    final pool = await open(reset: 'SELECT * FROM reset_no_such_table');
    if (pool == null) return;
    try {
      await borrow(pool, ["SELECT 'a' AS v"]);
      expect(pool.borrowed, 0);
      expect(await borrow(pool, ["SELECT 'b' AS v"]), 'b');
    } finally {
      await pool.close();
    }
  });

  test('release is idempotent, and a release after close lets close finish',
      () async {
    final pool = await open();
    if (pool == null) return;
    final leased = await pool.acquire();
    await leased.release();
    await leased.release();
    expect(pool.borrowed, 0);
    final late = await pool.acquire();
    // close() waits for the borrowed connection: pool_destroy never runs
    // while a caller still holds a native connection.
    final closing = pool.close();
    expect(pool.isClosed, isTrue);
    await late.release();
    await late.release(); // idempotent, also after close
    await closing;
    expect(pool.borrowed, 0);
    expect(pool.nativePool, isNull);
  });
}
