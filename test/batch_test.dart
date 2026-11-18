/// Integration tests for `executeBatch` (ABI MINOR 8, `pool_submit_batch`):
/// several Extended statements with their own parameters in one round-trip.
///
/// One-connection pools, so `pg_prepared_statements` shows what the cache
/// prepared on the session. Each SQL carries a marker comment (`/*k99-…*/`);
/// the inspection queries are parameterless (Simple protocol, never
/// cached). Requires the dev Postgres; skips if the native lib or the server
/// is missing.
library;

import 'dart:ffi' as ffi;
import 'dart:io' show Platform;

import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:slingshot_postgres/src/bindings/postgres_binding.dart';
import 'package:slingshot_postgres/src/native/postgres_lib_loader.dart';
import 'package:slingshot_postgres/src/native/postgres_native_pool.dart';
import 'package:slingshot_postgres/src/postgres/postgres_query_executor.dart';
import 'package:slingshot_postgres/src/postgres/session_reset.dart';
import 'package:test/test.dart';

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
  if (binding == null || binding.poolSubmitBatch == null) {
    test('skipped (native library not built or older than MINOR 8)', () {
      markTestSkipped('libnative_db with ABI MINOR 8 not available');
    });
    return;
  }
  final b = binding;

  final pools = <PostgresConnectionPool>[];
  tearDown(() async {
    PostgresQueryExecutor.debugForceSequentialBatch = false;
    DeferredSessionReset.debugFailingPrefix = false;
    for (final p in pools) {
      await p.close();
    }
    pools.clear();
  });

  Future<PostgresConnectionPool?> open(
      {int cache = 0, bool defer = false}) async {
    final pool = PostgresConnectionPool.withBinding(
        b,
        PoolConfig(
          connInfo: _connInfo,
          minSize: 1,
          maxSize: 1,
          acquireTimeout: const Duration(seconds: 3),
          deferSessionReset: defer,
          preservePreparedStatements: true,
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

  PostgresBatchExecutor batchOf(PostgresQueryExecutorContract exec) =>
      exec as PostgresBatchExecutor;

  // First column of every row, as text, for each result set; releases them.
  List<List<String?>> cols(List<PostgresResultSet> sets) {
    try {
      return [
        for (final rs in sets)
          [for (var i = 0; i < rs.rowCount; i++) rs.row(i).getString('v')]
      ];
    } finally {
      for (final rs in sets) {
        rs.release();
      }
    }
  }

  Future<String?> one(PostgresQueryExecutorContract exec, String sql) async {
    final rs = await exec.execute(sql);
    try {
      return rs.rowCount > 0 ? rs.row(0).getString('v') : null;
    } finally {
      rs.release();
    }
  }

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

  final mixed = [
    PgBatchQuery(
        r'SELECT ($1::int4 + 1)::text AS v /*k99-a*/', [Param.int4(41)]),
    PgBatchQuery(r'SELECT upper($1) AS v /*k99-b*/', [Param.text('x')]),
    PgBatchQuery(r'SELECT g::text AS v FROM generate_series(1, $1) g /*k99-c*/',
        [Param.int4(3)]),
    const PgBatchQuery('SELECT 7::text AS v /*k99-d*/'),
  ];

  test('N statements, rows in order, text and binary results', () async {
    final pool = await open();
    if (pool == null) return;
    await withPostgresConnection(pool, (exec) async {
      expect(cols(await batchOf(exec).executeBatch(mixed)), [
        ['42'],
        ['X'],
        ['1', '2', '3'],
        ['7'],
      ]);
      final sets = await batchOf(exec).executeBatch([
        PgBatchQuery(r'SELECT $1::int8 AS n /*k99-bin*/', [Param.int8(9)]),
        PgBatchQuery(r'SELECT $1::text AS t /*k99-bin*/', [Param.text('y')]),
      ], binaryResult: true);
      try {
        expect(sets[0].row(0)['n'], 9);
        expect(sets[1].row(0)['t'], 'y');
      } finally {
        for (final rs in sets) {
          rs.release();
        }
      }
    });
  });

  test('empty batch and batch of one', () async {
    final pool = await open();
    if (pool == null) return;
    await withPostgresConnection(pool, (exec) async {
      expect(await batchOf(exec).executeBatch(const []), isEmpty);
      expect(cols(await batchOf(exec).executeBatch([mixed.first])), [
        ['42']
      ]);
    });
    // Empty batch as the first statement of a transaction still opens it.
    await withTransaction(pool, (exec) async {
      expect(await batchOf(exec).executeBatch(const []), isEmpty);
      expect(
          await one(exec, 'SELECT (now() <> statement_timestamp())::text AS v'),
          'true');
    });
  });

  test('inside a transaction: the fused BEGIN rides the batch', () async {
    final pool = await open();
    if (pool == null) return;
    await withPostgresConnection(pool, (exec) async {
      (await exec.execute('DROP TABLE IF EXISTS k99_t')).release();
      (await exec.execute('CREATE TABLE k99_t (v int)')).release();
    });
    try {
      await withTransaction(pool, (exec) async {
        cols(await batchOf(exec).executeBatch([
          PgBatchQuery(r'INSERT INTO k99_t VALUES ($1) RETURNING v::text AS v',
              [Param.int4(1)]),
          PgBatchQuery(r'INSERT INTO k99_t VALUES ($1) RETURNING v::text AS v',
              [Param.int4(2)]),
        ]));
        expect(
            await one(
                exec, 'SELECT (now() <> statement_timestamp())::text AS v'),
            'true');
      });
      await withPostgresConnection(pool, (exec) async {
        expect(await one(exec, 'SELECT sum(v)::text AS v FROM k99_t'), '3');
      });
    } finally {
      await withPostgresConnection(pool, (exec) async {
        (await exec.execute('DROP TABLE IF EXISTS k99_t')).release();
      });
    }
  });

  test('the deferred session reset rides the batch, and recovers', () async {
    final pool = await open(defer: true);
    if (pool == null) return;
    const q = PgBatchQuery(
        "SELECT current_setting('application_name') AS v /*k99-reset*/");
    await withPostgresConnection(pool, (exec) async {
      (await exec.execute("SET application_name = 'k99-dirty'")).release();
    });
    await withPostgresConnection(pool, (exec) async {
      expect(cols(await batchOf(exec).executeBatch([q, q])), [
        [''],
        ['']
      ]);
      (await exec.execute("SET application_name = 'k99-dirty'")).release();
    });
    DeferredSessionReset.debugFailingPrefix = true;
    await withPostgresConnection(pool, (exec) async {
      expect(cols(await batchOf(exec).executeBatch([q])), [
        ['']
      ]);
    });
  });

  test('with the cache: one prepared statement per key, reused', () async {
    final pool = await open(cache: 8);
    if (pool == null) return;
    await withPostgresConnection(pool, (exec) async {
      for (var i = 0; i < 2; i++) {
        expect(cols(await batchOf(exec).executeBatch(mixed)), hasLength(4));
      }
      for (final m in ['k99-a', 'k99-b', 'k99-c', 'k99-d']) {
        expect(await prepared(exec, m), (1, 2), reason: m);
      }
      // The same key twice in one batch: one statement, two executions.
      expect(
          cols(await batchOf(exec).executeBatch([
            PgBatchQuery(
                r'SELECT $1::text AS v /*k99-dup*/', [Param.text('p')]),
            PgBatchQuery(
                r'SELECT $1::text AS v /*k99-dup*/', [Param.text('q')]),
          ])),
          [
            ['p'],
            ['q']
          ]);
      expect(await prepared(exec, 'k99-dup'), (1, 2));
    });
  });

  test('without the cache: nothing is prepared', () async {
    final pool = await open();
    if (pool == null) return;
    await withPostgresConnection(pool, (exec) async {
      cols(await batchOf(exec).executeBatch(mixed));
      expect(
          await one(
              exec,
              'SELECT count(*)::text AS v FROM pg_prepared_statements '
              r"WHERE name LIKE '\_ss%'"),
          '0');
    });
  });

  test('a batch larger than the cache still runs', () async {
    final pool = await open(cache: 2);
    if (pool == null) return;
    await withPostgresConnection(pool, (exec) async {
      for (var i = 0; i < 3; i++) {
        expect(cols(await batchOf(exec).executeBatch(mixed)), [
          ['42'],
          ['X'],
          ['1', '2', '3'],
          ['7'],
        ]);
      }
    });
  });

  test(
      'a failing statement names itself, aborts the rest, keeps the '
      "caller's transaction for the caller", () async {
    final pool = await open(cache: 8);
    if (pool == null) return;
    final uow = PostgresUnitOfWork(pool);
    await uow.begin();
    try {
      await expectLater(
          batchOf(uow.executor).executeBatch([
            mixed[0],
            PgBatchQuery(r'SELECT ($1::int4 / 0)::text AS v /*k99-div*/',
                [Param.int4(1)]),
            mixed[1],
          ]),
          throwsA(isA<QueryFailedException>()
              .having((e) => e.sql, 'sql', contains('k99-div'))
              .having((e) => e.serverMessage, 'serverMessage',
                  contains('[SQLSTATE 22012]'))));
      // No automatic ROLLBACK: the transaction is still there, aborted.
      await expectLater(
          uow.executor.execute('SELECT 1'),
          throwsA(isA<QueryFailedException>().having(
              (e) => e.serverMessage, 'serverMessage', contains('aborted'))));
    } finally {
      await uow.rollback();
    }
    // The connection is clean afterwards.
    await withPostgresConnection(pool, (exec) async {
      expect(cols(await batchOf(exec).executeBatch([mixed[0]])), [
        ['42']
      ]);
    });
  });

  test('a Prepare error takes its query\'s place', () async {
    final pool = await open(cache: 8);
    if (pool == null) return;
    await withPostgresConnection(pool, (exec) async {
      await expectLater(
          batchOf(exec).executeBatch([
            mixed[0],
            PgBatchQuery(r'SELEC $1 /*k99-syntax*/', [Param.int4(1)]),
          ]),
          throwsA(isA<QueryFailedException>()
              .having((e) => e.sql, 'sql', contains('k99-syntax'))
              .having((e) => e.serverMessage, 'serverMessage',
                  contains('[SQLSTATE 42601]'))));
      expect(cols(await batchOf(exec).executeBatch([mixed[1]])), [
        ['X']
      ]);
    });
  });

  test('stale statements: re-run outside a transaction, error inside',
      () async {
    final pool = await open(cache: 8);
    if (pool == null) return;
    await withPostgresConnection(pool, (exec) async {
      cols(await batchOf(exec).executeBatch(mixed));
      (await exec.execute('DEALLOCATE ALL')).release();
      expect(cols(await batchOf(exec).executeBatch(mixed)), hasLength(4));
    });
    await withPostgresConnection(pool, (exec) async {
      (await exec.execute('DEALLOCATE ALL')).release();
    });
    await expectLater(
        withTransaction(pool, (exec) async {
          cols(await batchOf(exec).executeBatch(mixed));
        }),
        throwsA(isA<QueryFailedException>().having((e) => e.serverMessage,
            'serverMessage', contains('[SQLSTATE 26000]'))));
    await withTransaction(pool, (exec) async {
      expect(cols(await batchOf(exec).executeBatch(mixed)), hasLength(4));
    });
  });

  Future<int> cachedNames(PostgresQueryExecutorContract exec) async =>
      int.parse((await one(
          exec,
          'SELECT count(*)::text AS v FROM pg_prepared_statements '
          r"WHERE name LIKE '\_ss%'"))!);

  Future<String> nameOf(
          PostgresQueryExecutorContract exec, String marker) async =>
      (await one(
          exec,
          'SELECT name AS v FROM pg_prepared_statements '
          "WHERE statement LIKE '%$marker%'"))!;

  test(
      'one Sync (the proxy for one round-trip): the batch runs in one '
      'implicit transaction', () async {
    final pool = await open();
    if (pool == null) return;
    await withPostgresConnection(pool, (exec) async {
      // Outside a transaction, statements sent one by one get a transaction
      // each (different now()); one pipeline under one Sync shares one.
      final sets = await batchOf(exec).executeBatch([
        PgBatchQuery(r'SELECT now()::text AS v /*k99-now1*/ WHERE $1',
            [const Param.bool(true)]),
        PgBatchQuery(r'SELECT pg_sleep($1)::text AS v /*k99-nap*/',
            [Param.float8(0.05)]),
        PgBatchQuery(r'SELECT now()::text AS v /*k99-now2*/ WHERE $1',
            [const Param.bool(true)]),
      ]);
      final v = cols(sets);
      expect(v[0], v[2]);
      PostgresQueryExecutor.debugForceSequentialBatch = true;
      final seq = cols(await batchOf(exec).executeBatch([
        PgBatchQuery(r'SELECT now()::text AS v /*k99-now1*/ WHERE $1',
            [const Param.bool(true)]),
        PgBatchQuery(r'SELECT pg_sleep($1)::text AS v /*k99-nap*/',
            [Param.float8(0.05)]),
        PgBatchQuery(r'SELECT now()::text AS v /*k99-now2*/ WHERE $1',
            [const Param.bool(true)]),
      ]));
      expect(seq[0], isNot(seq[2]), reason: 'the probe tells the two apart');
    });
  });

  test('stale: one statement of the batch gone, the rest still cached',
      () async {
    final pool = await open(cache: 8);
    if (pool == null) return;
    await withPostgresConnection(pool, (exec) async {
      cols(await batchOf(exec).executeBatch(mixed));
      final before = {
        for (final m in ['k99-a', 'k99-b', 'k99-d']) m: await nameOf(exec, m)
      };
      (await exec.execute('DEALLOCATE "${await nameOf(exec, 'k99-c')}"'))
          .release();
      expect(cols(await batchOf(exec).executeBatch(mixed)), [
        ['42'],
        ['X'],
        ['1', '2', '3'],
        ['7'],
      ]);
      // The retry re-prepared every statement of the batch and closed the
      // old ones; a further job sends the pending closes.
      cols(await batchOf(exec).executeBatch([mixed[0]]));
      for (final m in ['k99-a', 'k99-b', 'k99-c', 'k99-d']) {
        expect((await prepared(exec, m)).$1, 1, reason: m);
      }
      expect(await cachedNames(exec), 4);
      // ...under new names: the entries the batch hit were dropped too.
      for (final e in before.entries) {
        expect(await nameOf(exec, e.key), isNot(e.value), reason: e.key);
      }
    });
  });

  test('stale: a schema change (0A000) inside the batch', () async {
    final pool = await open(cache: 8);
    if (pool == null) return;
    await withPostgresConnection(pool, (exec) async {
      (await exec.execute('DROP TABLE IF EXISTS k99_s')).release();
      (await exec.execute('CREATE TABLE k99_s (a int)')).release();
      (await exec.execute('INSERT INTO k99_s VALUES (1)')).release();
    });
    try {
      final q = [
        mixed[0],
        PgBatchQuery(
            r'SELECT * FROM k99_s WHERE a = $1 /*k99-ddl*/', [Param.int4(1)]),
      ];
      await withPostgresConnection(pool, (exec) async {
        void release(List<PostgresResultSet> sets) {
          for (final rs in sets) {
            rs.release();
          }
        }

        var sets = await batchOf(exec).executeBatch(q);
        expect(sets[1].colCount, 1);
        release(sets);
        (await exec.execute('ALTER TABLE k99_s ADD COLUMN b int')).release();
        sets = await batchOf(exec).executeBatch(q);
        expect(sets[1].colCount, 2);
        release(sets);
      });
    } finally {
      await withPostgresConnection(pool, (exec) async {
        (await exec.execute('DROP TABLE IF EXISTS k99_s')).release();
      });
    }
  });

  test('a name taken by the caller in the middle of the batch', () async {
    final pool = await open(cache: 8);
    if (pool == null) return;
    await withPostgresConnection(pool, (exec) async {
      // A fresh connection's cache hands out _ss0, _ss1, _ss2 to these.
      (await exec.execute('PREPARE _ss1 AS SELECT 1')).release();
      expect(cols(await batchOf(exec).executeBatch(mixed.sublist(0, 3))), [
        ['42'],
        ['X'],
        ['1', '2', '3'],
      ]);
      // The collision did happen: the first statement took _ss0, so the
      // second asked for _ss1 and was moved to a fresh name on the retry.
      expect(await nameOf(exec, 'k99-a'), '_ss0');
      expect(await nameOf(exec, 'k99-b'), isNot('_ss1'));
      (await exec.execute('DEALLOCATE _ss1')).release();
    });
  });

  test('a repeated key whose statement went stale', () async {
    final pool = await open(cache: 8);
    if (pool == null) return;
    await withPostgresConnection(pool, (exec) async {
      final q = [
        PgBatchQuery(r'SELECT $1::text AS v /*k99-twice*/', [Param.text('p')]),
        PgBatchQuery(r'SELECT $1::text AS v /*k99-twice*/', [Param.text('q')]),
      ];
      cols(await batchOf(exec).executeBatch(q));
      (await exec.execute('DEALLOCATE ALL')).release();
      expect(cols(await batchOf(exec).executeBatch(q)), [
        ['p'],
        ['q']
      ]);
      expect((await prepared(exec, 'k99-twice')).$1, 1);
    });
  });

  test('a batch larger than the cache leaves only the capacity behind',
      () async {
    final pool = await open(cache: 2);
    if (pool == null) return;
    await withPostgresConnection(pool, (exec) async {
      cols(await batchOf(exec).executeBatch(mixed));
      // The last two inserted are cached; a hit sends the pending closes.
      cols(await batchOf(exec).executeBatch([mixed[3]]));
      expect(await cachedNames(exec), 2);
      expect((await prepared(exec, 'k99-d')).$1, 1);
    });
  });

  test('sequential fallback: a failure names its statement', () async {
    final pool = await open(cache: 8);
    if (pool == null) return;
    PostgresQueryExecutor.debugForceSequentialBatch = true;
    await withPostgresConnection(pool, (exec) async {
      await expectLater(
          batchOf(exec).executeBatch([
            mixed[0],
            PgBatchQuery(r'SELECT ($1::int4 / 0)::text AS v /*k99-div2*/',
                [Param.int4(1)]),
          ]),
          throwsA(isA<QueryFailedException>()
              .having((e) => e.sql, 'sql', contains('k99-div2'))));
      expect(cols(await batchOf(exec).executeBatch([mixed[1]])), [
        ['X']
      ]);
    });
  });

  test('timeout: drained, the session kept', () async {
    final pool = await open(cache: 8);
    if (pool == null) return;
    final leased = await pool.acquire();
    try {
      final exec = PostgresQueryExecutor(b, leased.raw,
          timeout: const Duration(milliseconds: 300), statementCache: true);
      final before = await one(exec, 'SELECT pg_backend_pid()::text AS v');
      await expectLater(
          exec.executeBatch([
            mixed[0],
            PgBatchQuery(r'SELECT pg_sleep($1)::text AS v /*k99-sleep*/',
                [Param.float8(10)]),
          ]),
          throwsA(isA<QueryTimeoutException>()));
      expect(await one(exec, 'SELECT pg_backend_pid()::text AS v'), before);
      expect(cols(await exec.executeBatch([mixed[1]])), [
        ['X']
      ]);
    } finally {
      await leased.release();
    }
  });

  test('sequential fallback (older library): same results', () async {
    final pool = await open(cache: 8);
    if (pool == null) return;
    PostgresQueryExecutor.debugForceSequentialBatch = true;
    await withTransaction(pool, (exec) async {
      expect(cols(await batchOf(exec).executeBatch(mixed)), [
        ['42'],
        ['X'],
        ['1', '2', '3'],
        ['7'],
      ]);
    });
  });
}
