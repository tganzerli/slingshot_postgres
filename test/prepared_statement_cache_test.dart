/// Integration tests for the prepared-statement cache
/// (`PoolConfig.statementCacheSize`, ABI MINOR 7).
///
/// One-connection pools, so consecutive borrows share the server session
/// and `pg_prepared_statements` shows what the cache prepared on it. Each
/// SQL carries a marker comment (`/*k95-…*/`); the inspection queries are
/// parameterless, so they take the Simple protocol and are never cached
/// themselves. Requires the dev Postgres; skips if the native lib or the
/// server is missing.
library;

import 'dart:ffi' as ffi;
import 'dart:io' show Platform;

import 'package:slingshot/slingshot.dart' show ConnectionLostException;
import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:slingshot_postgres/src/bindings/postgres_binding.dart';
import 'package:slingshot_postgres/src/native/postgres_lib_loader.dart';
import 'package:slingshot_postgres/src/native/postgres_native_pool.dart';
import 'package:slingshot_postgres/src/postgres/postgres_query_executor.dart';
import 'package:slingshot_postgres/src/postgres/session_reset.dart';
import 'package:test/test.dart';

// Overridable so the suite can run from a Linux container against the dev
// server (the libpq < 17 path, without `PQsendClosePrepared`).
final _connInfo = Platform.environment['SLINGSHOT_PG_CONNINFO'] ??
    'host=localhost port=5432 dbname=teste user=postgres password=123';

void main() {
  PostgresBinding? binding;
  try {
    binding = PostgresBinding(loadNativeDb());
    binding.initDartApi(ffi.NativeApi.initializeApiDLData);
  } on StateError {
    binding = null;
  }
  if (binding == null || binding.poolSubmitQueryCached == null) {
    test('skipped (native library not built or older than MINOR 7)', () {
      markTestSkipped('libnative_db with ABI MINOR 7 not available');
    });
    return;
  }
  final b = binding;

  final pools = <PostgresConnectionPool>[];
  tearDown(() async {
    for (final p in pools) {
      await p.close();
    }
    pools.clear();
  });

  Future<PostgresConnectionPool?> open({
    int cache = 8,
    bool preserve = true,
    String? reset = 'DISCARD ALL',
    bool defer = false,
  }) async {
    final pool = PostgresConnectionPool.withBinding(
        b,
        PoolConfig(
          connInfo: _connInfo,
          minSize: 1,
          maxSize: 1,
          acquireTimeout: const Duration(seconds: 3),
          sessionResetQuery: reset,
          deferSessionReset: defer,
          preservePreparedStatements: preserve,
          statementCacheSize: cache,
        ));
    try {
      await pool.start();
    } on NativePoolStartupException {
      markTestSkipped(
          'Postgres not reachable — start PostgreSQL at localhost:5432');
      return null;
    }
    pools.add(pool);
    return pool;
  }

  // First column of the first row as text (`v`), or null.
  Future<String?> one(PostgresQueryExecutorContract exec, String sql,
      [List<Param> params = const []]) async {
    final rs = await exec.execute(sql, params: params);
    try {
      return rs.rowCount > 0 ? rs.row(0).getString('v') : null;
    } finally {
      rs.release();
    }
  }

  // Statements of this session whose text contains [marker]: count and
  // total executions (generic + custom plans).
  Future<(int, int)> prepared(
      PostgresQueryExecutorContract exec, String marker) async {
    final v = await one(
        exec,
        "SELECT count(*)::text || ':' || "
        'coalesce(sum(generic_plans + custom_plans), 0)::text AS v '
        "FROM pg_prepared_statements WHERE statement LIKE '%$marker%'");
    final parts = v!.split(':');
    return (int.parse(parts[0]), int.parse(parts[1]));
  }

  Future<int> cachedNames(PostgresQueryExecutorContract exec) async =>
      int.parse((await one(
          exec,
          'SELECT count(*)::text AS v FROM pg_prepared_statements '
          r"WHERE name LIKE '\_ss%'"))!);

  test('off by default: nothing is prepared', () async {
    final pool = await open(cache: 0);
    if (pool == null) return;
    await withPostgresConnection(pool, (exec) async {
      for (var i = 0; i < 2; i++) {
        expect(
            await one(exec, r'SELECT ($1::int4 + 1)::text AS v /*k95-off*/',
                [Param.int4(1)]),
            '2');
      }
      expect(await cachedNames(exec), 0);
    });
  });

  test('second use of the same SQL runs the prepared statement', () async {
    final pool = await open();
    if (pool == null) return;
    const sql = r'SELECT ($1::int4 * 2)::text AS v /*k95-hit*/';
    for (var i = 1; i <= 3; i++) {
      // Separate borrows: the statement survives the preserving reset.
      await withPostgresConnection(pool, (exec) async {
        expect(await one(exec, sql, [Param.int4(i)]), '${i * 2}');
      });
    }
    await withPostgresConnection(pool, (exec) async {
      expect(await prepared(exec, 'k95-hit'), (1, 3));
    });
  });

  test('the key includes the parameter types', () async {
    final pool = await open();
    if (pool == null) return;
    await withPostgresConnection(pool, (exec) async {
      const sql = r'SELECT $1::text AS v /*k95-types*/';
      expect(await one(exec, sql, [Param.int4(7)]), '7');
      expect(await one(exec, sql, [Param.text('x')]), 'x');
      expect(await one(exec, sql, [Param.text('y')]), 'y');
      expect(await prepared(exec, 'k95-types'), (2, 3));
    });
  });

  test('a full cache evicts the least recently used and closes it', () async {
    final pool = await open(cache: 2);
    if (pool == null) return;
    await withPostgresConnection(pool, (exec) async {
      for (final m in ['k95-l1', 'k95-l2', 'k95-l3']) {
        expect(await one(exec, 'SELECT \$1::text AS v /*$m*/', [Param.text(m)]),
            m);
      }
      // The eviction of l1 is closed on the server by the next cached job.
      expect(
          await one(
              exec, r'SELECT $1::text AS v /*k95-l3*/', [Param.text('again')]),
          'again');
      expect(await prepared(exec, 'k95-l1'), (0, 0));
      expect((await prepared(exec, 'k95-l2')).$1, 1);
      expect((await prepared(exec, 'k95-l3')).$1, 1);
      expect(await cachedNames(exec), 2);
    });
  });

  test('DEALLOCATE ALL outside a transaction is absorbed by a re-prepare',
      () async {
    final pool = await open();
    if (pool == null) return;
    await withPostgresConnection(pool, (exec) async {
      const sql = r'SELECT ($1::int4 + 10)::text AS v /*k95-dealloc*/';
      expect(await one(exec, sql, [Param.int4(1)]), '11');
      (await exec.execute('DEALLOCATE ALL')).release();
      expect(await one(exec, sql, [Param.int4(2)]), '12');
      expect((await prepared(exec, 'k95-dealloc')).$1, 1);
    });
  });

  group('schema change of a cached query', () {
    setUp(() async {
      final pool = await open(cache: 0);
      if (pool == null) return;
      await withPostgresConnection(pool, (exec) async {
        (await exec.execute('DROP TABLE IF EXISTS k95_t')).release();
        (await exec.execute('CREATE TABLE k95_t (a int)')).release();
        (await exec.execute('INSERT INTO k95_t VALUES (1)')).release();
      });
    });
    tearDown(() async {
      final pool = await open(cache: 0);
      if (pool == null) return;
      await withPostgresConnection(pool, (exec) async {
        (await exec.execute('DROP TABLE IF EXISTS k95_t')).release();
      });
    });

    test('outside a transaction: re-prepared, new columns visible', () async {
      final pool = await open();
      if (pool == null) return;
      await withPostgresConnection(pool, (exec) async {
        const sql = r'SELECT * FROM k95_t WHERE a = $1 /*k95-ddl*/';
        var rs = await exec.execute(sql, params: [Param.int4(1)]);
        expect(rs.colCount, 1);
        rs.release();
        (await exec.execute('ALTER TABLE k95_t ADD COLUMN b int')).release();
        rs = await exec.execute(sql, params: [Param.int4(1)]);
        expect(rs.colCount, 2);
        rs.release();
        // The stale statement was closed by the retry: one left.
        expect((await prepared(exec, 'k95-ddl')).$1, 1);
      });
    });

    test('inside a transaction: fails with the SQLSTATE, next one works',
        () async {
      final pool = await open();
      if (pool == null) return;
      const sql = r'SELECT * FROM k95_t WHERE a = $1 /*k95-ddl-tx*/';
      await withTransaction(pool, (exec) async {
        final rs = await exec.execute(sql, params: [Param.int4(1)]);
        expect(rs.colCount, 1);
        rs.release();
      });
      await withPostgresConnection(pool, (exec) async {
        (await exec.execute('ALTER TABLE k95_t ADD COLUMN b int')).release();
      });
      await expectLater(
          withTransaction(pool, (exec) async {
            (await exec.execute(sql, params: [Param.int4(1)])).release();
          }),
          throwsA(isA<QueryFailedException>().having((e) => e.serverMessage,
              'serverMessage', contains('[SQLSTATE 0A000]'))));
      await withTransaction(pool, (exec) async {
        final rs = await exec.execute(sql, params: [Param.int4(1)]);
        expect(rs.colCount, 2);
        rs.release();
      });
    });
  });

  test('a failed re-prepare surfaces with its own SQLSTATE', () async {
    final pool = await open(cache: 0);
    final cached = await open();
    if (pool == null || cached == null) return;
    await withPostgresConnection(pool, (exec) async {
      (await exec.execute('DROP TABLE IF EXISTS k95_gone')).release();
      (await exec.execute('CREATE TABLE k95_gone (a int)')).release();
    });
    await withPostgresConnection(cached, (exec) async {
      const sql = r'SELECT a FROM k95_gone WHERE a = $1 /*k95-gone*/';
      (await exec.execute(sql, params: [Param.int4(1)])).release();
      // The statement disappears (26000 on the hit), and its re-prepare
      // fails too: the table is gone (42P01). The second failure is the one
      // reported.
      (await exec.execute('DEALLOCATE ALL')).release();
      (await exec.execute('DROP TABLE k95_gone')).release();
      await expectLater(
          exec.execute(sql, params: [Param.int4(1)]),
          throwsA(isA<QueryFailedException>().having((e) => e.serverMessage,
              'serverMessage', contains('[SQLSTATE 42P01]'))));
      expect(
          await one(exec, r'SELECT $1::text AS v /*k95-gone-after*/',
              [Param.text('ok')]),
          'ok');
    });
  });

  test('with the reset off and no preserving reset, the cache works', () async {
    final pool = await open(preserve: false, reset: null);
    if (pool == null) return;
    const sql = r'SELECT ($1::int4 + 5)::text AS v /*k95-noreset*/';
    for (var i = 0; i < 2; i++) {
      await withPostgresConnection(pool, (exec) async {
        expect(await one(exec, sql, [Param.int4(i)]), '${5 + i}');
      });
    }
    await withPostgresConnection(pool, (exec) async {
      expect(await prepared(exec, 'k95-noreset'), (1, 2));
    });
  });

  test('evictions inside transactions do not pile up on the server', () async {
    final pool = await open(cache: 2);
    if (pool == null) return;
    for (var i = 0; i < 20; i++) {
      await withTransaction(pool, (exec) async {
        // Parameterless: the fused BEGIN goes by the Simple protocol, so
        // every cached job below starts inside the transaction.
        (await exec.execute("SELECT set_config('k95.x', '1', true)")).release();
        for (final m in ['k95-ev1', 'k95-ev2', 'k95-ev3']) {
          expect(
              await one(exec, 'SELECT \$1::text AS v /*$m*/', [Param.text(m)]),
              m);
        }
      });
    }
    await withPostgresConnection(pool, (exec) async {
      // At most the capacity, plus the one evicted by the last job, whose
      // close goes out with the next one.
      expect(await cachedNames(exec), lessThanOrEqualTo(3));
    });
  });

  test('a failure inside the deferred reset prefix, with the cache', () async {
    final pool = await open(defer: true);
    if (pool == null) return;
    const sql = r'SELECT ($1::int4 + 7)::text AS v /*k95-badreset*/';
    await withPostgresConnection(pool, (exec) async {
      expect(await one(exec, sql, [Param.int4(1)]), '8');
    });
    DeferredSessionReset.debugFailingPrefix = true;
    try {
      await withPostgresConnection(pool, (exec) async {
        expect(await one(exec, sql, [Param.int4(2)]), '9');
      });
    } finally {
      DeferredSessionReset.debugFailingPrefix = false;
    }
    await withPostgresConnection(pool, (exec) async {
      expect(await one(exec, sql, [Param.int4(3)]), '10');
      expect((await prepared(exec, 'k95-badreset')).$1, 1);
    });
  });

  test('a 0A000 that is not the plan cache\'s is not retried', () async {
    final admin = await open(cache: 0);
    final pool = await open();
    if (admin == null || pool == null) return;
    await withPostgresConnection(admin, (exec) async {
      for (final sql in [
        'DROP FUNCTION IF EXISTS k95_raise(int)',
        'DROP SEQUENCE IF EXISTS k95_seq',
        'CREATE SEQUENCE k95_seq',
        // nextval survives the error: a retry would show as a second call.
        'CREATE FUNCTION k95_raise(n int) RETURNS int LANGUAGE plpgsql AS '
            r"$$BEGIN PERFORM nextval('k95_seq'); IF n > 0 THEN "
            r"RAISE EXCEPTION 'k95' USING ERRCODE = '0A000'; END IF; "
            r'RETURN 0; END$$',
      ]) {
        (await exec.execute(sql)).release();
      }
    });
    try {
      await withPostgresConnection(pool, (exec) async {
        const sql = r'SELECT k95_raise($1)::text AS v /*k95-raise*/';
        expect(await one(exec, sql, [Param.int4(0)]), '0');
        await expectLater(
            exec.execute(sql, params: [Param.int4(1)]),
            throwsA(isA<QueryFailedException>().having((e) => e.serverMessage,
                'serverMessage', contains('[SQLSTATE 0A000]'))));
        expect(
            await one(exec, 'SELECT last_value::text AS v FROM k95_seq'), '2');
        // Still cached: the entry was not dropped either.
        expect((await prepared(exec, 'k95-raise')).$1, 1);
      });
    } finally {
      await withPostgresConnection(admin, (exec) async {
        (await exec.execute('DROP FUNCTION IF EXISTS k95_raise(int)'))
            .release();
        (await exec.execute('DROP SEQUENCE IF EXISTS k95_seq')).release();
      });
    }
  });

  test('capacity lowered to 0 at run time closes what is left', () async {
    final pool = await open(cache: 4);
    if (pool == null) return;
    await withPostgresConnection(pool, (exec) async {
      for (final m in ['k95-z1', 'k95-z2']) {
        expect(await one(exec, 'SELECT \$1::text AS v /*$m*/', [Param.text(m)]),
            m);
      }
      expect(await cachedNames(exec), 2);
      b.poolSetStatementCacheCapacity!(pool.nativePool!.ptr, 0);
      // The next job runs unnamed and closes both.
      expect(
          await one(
              exec, r'SELECT $1::text AS v /*k95-z3*/', [Param.text('z3')]),
          'z3');
      expect(await cachedNames(exec), 0);
      expect(
          await one(
              exec, r'SELECT $1::text AS v /*k95-z3*/', [Param.text('again')]),
          'again');
      expect(await cachedNames(exec), 0);
    });
  });

  test(
      'closing a statement deallocated by hand inside a transaction '
      'keeps the transaction', () async {
    final admin = await open(cache: 0);
    final pool = await open(cache: 1);
    if (admin == null || pool == null) return;
    await withPostgresConnection(admin, (exec) async {
      (await exec.execute('DROP TABLE IF EXISTS k95_sp')).release();
      (await exec.execute('CREATE TABLE k95_sp (v text)')).release();
    });
    try {
      await withTransaction(pool, (exec) async {
        // Parameterless first statement: the cached jobs run inside the
        // transaction.
        (await exec.execute("INSERT INTO k95_sp VALUES ('before')")).release();
        expect(
            await one(
                exec, r'SELECT $1::text AS v /*k95-sp-a*/', [Param.text('a')]),
            'a');
        final name = await one(
            exec,
            'SELECT name AS v FROM pg_prepared_statements '
            "WHERE statement LIKE '%k95-sp-a%'");
        // Evicts a (capacity 1): its name waits for close.
        expect(
            await one(
                exec, r'SELECT $1::text AS v /*k95-sp-b*/', [Param.text('b')]),
            'b');
        // Someone deallocates it first: the close must not abort us.
        (await exec.execute('DEALLOCATE "$name"')).release();
        expect(
            await one(
                exec, r'SELECT $1::text AS v /*k95-sp-c*/', [Param.text('c')]),
            'c');
        (await exec.execute("INSERT INTO k95_sp VALUES ('after')")).release();
      });
      await withPostgresConnection(admin, (exec) async {
        expect(
            await one(
                exec, "SELECT string_agg(v, ',' ORDER BY v) AS v FROM k95_sp"),
            'after,before');
      });
    } finally {
      await withPostgresConnection(admin, (exec) async {
        (await exec.execute('DROP TABLE IF EXISTS k95_sp')).release();
      });
    }
  });

  test('fused BEGIN: the first statement of a transaction is cached', () async {
    final pool = await open();
    if (pool == null) return;
    for (var i = 0; i < 2; i++) {
      final v = await withTransaction(pool, (exec) async {
        final v = await one(
            exec,
            r'SELECT ($1::int4 + 100)::text AS v /*k95-begin*/',
            [Param.int4(i)]);
        // The fused BEGIN ran: we are inside a transaction block.
        expect(
            await one(
                exec,
                'SELECT (now() = statement_timestamp())::text '
                'AS v'),
            'false');
        return v;
      });
      expect(v, '${100 + i}');
    }
    await withPostgresConnection(pool, (exec) async {
      expect(await prepared(exec, 'k95-begin'), (1, 2));
    });
  });

  test('deferred session reset rides the cached statement', () async {
    final pool = await open(defer: true);
    if (pool == null) return;
    const sql = r'SELECT current_setting($1, true) AS v /*k95-defer*/';
    await withPostgresConnection(pool, (exec) async {
      (await exec.execute("SET application_name = 'k95-dirty'")).release();
      expect(
          await one(exec, sql, [Param.text('application_name')]), 'k95-dirty');
    });
    // The next borrow's first statement carries the deferred reset as
    // prefixes: the setting is gone, and the cached statement survived it.
    await withPostgresConnection(pool, (exec) async {
      expect(await one(exec, sql, [Param.text('application_name')]), '');
      expect(await prepared(exec, 'k95-defer'), (1, 2));
    });
  });

  test('a terminated backend: the next use prepares on the new session',
      () async {
    final pool = await open();
    final killer = await open(cache: 0);
    if (pool == null || killer == null) return;
    const sql = r'SELECT ($1::int4 + 1000)::text AS v /*k95-kill*/';
    final pid = await withPostgresConnection(pool, (exec) async {
      expect(await one(exec, sql, [Param.int4(1)]), '1001');
      return one(exec, 'SELECT pg_backend_pid()::text AS v');
    });
    await withPostgresConnection(killer, (exec) async {
      (await exec.execute('SELECT pg_terminate_backend($pid)')).release();
    });
    // The first use after the kill may report the lost link, as any
    // statement would; it must never surface a stale-statement error.
    try {
      await withPostgresConnection(
          pool, (exec) => one(exec, sql, [Param.int4(2)]));
    } on ConnectionLostException {
      // expected on the dead socket
    }
    await withPostgresConnection(pool, (exec) async {
      expect(await one(exec, sql, [Param.int4(3)]), '1003');
      expect((await prepared(exec, 'k95-kill')).$1, 1);
    });
  });

  test('a name taken by the caller is skipped', () async {
    final pool = await open();
    if (pool == null) return;
    await withPostgresConnection(pool, (exec) async {
      // The first name a fresh connection's cache hands out is _ss0.
      (await exec.execute('PREPARE _ss0 AS SELECT 1')).release();
      expect(
          await one(
              exec, r'SELECT $1::text AS v /*k95-name*/', [Param.text('ok')]),
          'ok');
      expect((await prepared(exec, 'k95-name')).$1, 1);
      (await exec.execute('DEALLOCATE _ss0')).release();
    });
  });

  test('timeout: the connection and its cache stay usable', () async {
    final pool = await open();
    if (pool == null) return;
    final leased = await pool.acquire();
    try {
      final exec = PostgresQueryExecutor(b, leased.raw,
          timeout: const Duration(milliseconds: 300), statementCache: true);
      const sleep = r'SELECT pg_sleep($1::float8)::text AS v /*k95-sleep*/';
      // A miss times out (pipeline path)...
      await expectLater(exec.execute(sleep, params: [Param.float8(3)]),
          throwsA(isA<QueryTimeoutException>()));
      expect(
          await one(exec, r'SELECT $1::text AS v /*k95-after*/',
              [Param.text('alive')]),
          'alive');
      expect(await one(exec, sleep, [Param.float8(0)]), '');
      expect((await prepared(exec, 'k95-sleep')).$1, 1);
      // ...and so does a hit, the hot path: cancelled and drained, the
      // connection still serves.
      await expectLater(exec.execute(sleep, params: [Param.float8(3)]),
          throwsA(isA<QueryTimeoutException>()));
      expect(await one(exec, sleep, [Param.float8(0)]), '');
      expect(
          await one(exec, r'SELECT $1::text AS v /*k95-after2*/',
              [Param.text('alive')]),
          'alive');
    } finally {
      await leased.release();
    }
    // The next borrow gets a working connection too.
    await withPostgresConnection(pool, (exec) async {
      expect(
          await one(
              exec, r'SELECT $1::text AS v /*k95-after3*/', [Param.text('ok')]),
          'ok');
    });
  });

  test('errors carry the SQLSTATE, Prepare errors included', () async {
    final pool = await open();
    if (pool == null) return;
    await withPostgresConnection(pool, (exec) async {
      await expectLater(
          exec.execute(r'SELECT ($1::int4 / 0)::text AS v /*k95-div*/',
              params: [Param.int4(1)]),
          throwsA(isA<QueryFailedException>().having((e) => e.serverMessage,
              'serverMessage', contains('[SQLSTATE 22012]'))));
      await expectLater(
          exec.execute(r'SELEC $1 /*k95-syntax*/', params: [Param.int4(1)]),
          throwsA(isA<QueryFailedException>().having((e) => e.serverMessage,
              'serverMessage', contains('[SQLSTATE 42601]'))));
      // The connection is clean afterwards.
      expect(
          await one(
              exec, r'SELECT $1::text AS v /*k95-clean*/', [Param.text('ok')]),
          'ok');
    });
  });

  test('start refuses the cache with a reset that drops statements', () async {
    final pool = PostgresConnectionPool.withBinding(
        b,
        PoolConfig(
            connInfo: _connInfo,
            maxSize: 1,
            minSize: 1,
            statementCacheSize: 4));
    await expectLater(pool.start(), throwsA(isA<ArgumentError>()));
  });
}
