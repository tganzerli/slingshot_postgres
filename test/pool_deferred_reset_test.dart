/// Integration tests for the deferred session reset
/// (`PoolConfig.deferSessionReset`): the reset leaves the release and rides
/// the first statement of the next borrow, as a `BEGIN; <DISCARD ALL
/// decomposed>; COMMIT` prefix. With `maxSize: 1` every borrow gets the same
/// connection, so whatever one borrower leaves in the session is what the
/// next one would inherit. Requires the dev Postgres; skips if the native lib
/// or server is missing.
library;

import 'dart:ffi' as ffi;

import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:slingshot_postgres/src/bindings/postgres_binding.dart';
import 'package:slingshot_postgres/src/native/postgres_lib_loader.dart';
import 'package:slingshot_postgres/src/native/postgres_native_pool.dart';
import 'package:slingshot_postgres/src/postgres/postgres_query_executor.dart';
import 'package:slingshot_postgres/src/postgres/session_reset.dart';
import 'package:test/test.dart';

const _connInfo =
    'host=localhost port=5432 dbname=teste user=postgres password=123';

/// One statement of a borrow: Simple when [params] is empty and [binary]
/// is false, Extended otherwise.
typedef _Step = ({String sql, List<Param> params, bool binary});

_Step _s(String sql) => (sql: sql, params: const [], binary: false);
_Step _p(String sql, List<Param> params, {bool binary = false}) =>
    (sql: sql, params: params, binary: binary);

void main() {
  PostgresBinding? binding;
  try {
    binding = PostgresBinding(loadNativeDb());
    binding.initDartApi(ffi.NativeApi.initializeApiDLData);
  } on StateError {
    binding = null;
  }
  if (binding == null || binding.poolSubmitQueryParamsPrefixedN == null) {
    test('skipped (native library not built, or older than ABI MINOR 6)', () {
      markTestSkipped('libnative_db MINOR 6 not available');
    });
    return;
  }
  final b = binding;

  Future<PostgresConnectionPool?> open({bool defer = true}) async {
    final pool = PostgresConnectionPool.withBinding(
        b,
        PoolConfig(
            connInfo: _connInfo,
            minSize: 1,
            maxSize: 1,
            acquireTimeout: const Duration(seconds: 3),
            sessionResetQuery: defer ? 'DISCARD ALL' : null,
            deferSessionReset: defer));
    try {
      await pool.start();
    } on NativePoolStartupException {
      markTestSkipped('Postgres not reachable — start PostgreSQL at localhost:5432');
      return null;
    }
    return pool;
  }

  // Reads column `v` of the first row as text (null when there is no row).
  String? first(PostgresResultSet rs) {
    final v =
        rs.rowCount > 0 && rs.colCount > 0 ? rs.row(0).getString('v') : null;
    rs.release();
    return v;
  }

  // One borrow: runs [steps] in order and returns `v` of the last one.
  Future<String?> borrow(PostgresConnectionPool pool, List<_Step> steps,
      {bool deferredBegin = false}) async {
    final leased = await pool.acquire();
    final exec =
        PostgresQueryExecutor(b, leased.raw, deferredBegin: deferredBegin);
    String? out;
    try {
      for (final st in steps) {
        out = first(await exec.execute(st.sql,
            params: st.params, binaryResult: st.binary));
      }
    } finally {
      await leased.release();
    }
    return out;
  }

  // Leaves session state behind: a GUC, set_config, a temp table, LISTEN,
  // a session advisory lock and a SQL PREPARE.
  final dirty = [
    _s("SELECT set_config('app.tenant_id', 'clinic-a', false) AS v"),
    _s("SET work_mem = '77MB'"),
    _s('CREATE TEMP TABLE deferred_probe (x int)'),
    _s('LISTEN deferred_chan'),
    _s('SELECT pg_advisory_lock(434343)::text AS v'),
    _s("PREPARE deferred_ps AS SELECT 'p'::text AS v"),
  ];

  // One row of the session state [dirty] touches, as text.
  const stateSql = "SELECT concat_ws('|', "
      "coalesce(current_setting('app.tenant_id', true), ''), "
      "current_setting('work_mem'), "
      "(to_regclass('pg_temp.deferred_probe') IS NOT NULL)::text, "
      '(SELECT count(*) FROM pg_listening_channels())::text, '
      "(SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' "
      'AND objid = 434343 AND pid = pg_backend_pid())::text, '
      "(SELECT count(*) FROM pg_prepared_statements))::text AS v";
  const clean = '|4MB|false|0|0|0';

  test('a custom reset query cannot be deferred', () async {
    final pool = PostgresConnectionPool.withBinding(
        b,
        const PoolConfig(
            connInfo: _connInfo,
            minSize: 1,
            maxSize: 1,
            sessionResetQuery: 'RESET ALL',
            deferSessionReset: true));
    await expectLater(pool.start(), throwsArgumentError);
  });

  test('release marks the connection instead of running the reset', () async {
    final pool = await open();
    if (pool == null) return;
    try {
      final leased = await pool.acquire();
      final conn = leased.raw;
      await leased.release();
      expect(DeferredSessionReset.isPending(conn), isTrue);
      // A borrow with no statement leaves the reset pending, for free.
      final idle = await pool.acquire();
      await idle.release();
      expect(DeferredSessionReset.isPending(conn), isTrue);
      expect(await borrow(pool, [_s(stateSql)]), clean);
      expect(DeferredSessionReset.isPending(conn), isTrue,
          reason: 'marked again on that release');
    } finally {
      await pool.close();
    }
  });

  final firstStatements = <String, _Step>{
    'Simple': _s(stateSql),
    'Extended, text result':
        _p('SELECT \$1::text || ($stateSql) AS v', [const Param.text('')]),
    'Extended, binary result': _p(
        'SELECT \$1::text || ($stateSql) AS v', [const Param.text('')],
        binary: true),
  };
  for (final MapEntry(key: name, value: step) in firstStatements.entries) {
    test('the next borrow sees a clean session — first statement $name',
        () async {
      final pool = await open();
      if (pool == null) return;
      try {
        await borrow(pool, dirty);
        expect(await borrow(pool, [step]), clean);
      } finally {
        await pool.close();
      }
    });

    test('a deferred BEGIN rides after the reset — $name', () async {
      final pool = await open();
      if (pool == null) return;
      try {
        await borrow(pool, dirty);
        final leased = await pool.acquire();
        try {
          final exec =
              PostgresQueryExecutor(b, leased.raw, deferredBegin: true);
          expect(
              first(await exec.execute(step.sql,
                  params: step.params, binaryResult: step.binary)),
              clean);
          (await exec.execute('SELECT pg_sleep(0.02)')).release();
          // Inside the caller's transaction: it started before this one.
          expect(
              first(await exec.execute('SELECT (statement_timestamp() > '
                  'transaction_timestamp())::text AS v')),
              'true');
          (await exec.execute('COMMIT')).release();
        } finally {
          await leased.release();
        }
      } finally {
        await pool.close();
      }
    });
  }

  test('the reset rides a multi-read', () async {
    final pool = await open();
    if (pool == null) return;
    try {
      await borrow(pool, dirty);
      final leased = await pool.acquire();
      try {
        final exec = PostgresQueryExecutor(b, leased.raw);
        final rs = await exec.executeMultiRead([stateSql, "SELECT 'x' AS v"]);
        expect(first(rs[0]), clean);
        expect(first(rs[1]), 'x');
      } finally {
        await leased.release();
      }
    } finally {
      await pool.close();
    }
  });

  test('a pipeline first pays the reset standalone and still sees it clean',
      () async {
    final pool = await open();
    if (pool == null) return;
    try {
      await borrow(pool, dirty);
      final leased = await pool.acquire();
      try {
        final exec = PostgresQueryExecutor(b, leased.raw);
        await exec.executePipeline(["SELECT 'ignored'"]);
        expect(first(await exec.execute(stateSql)), clean);
      } finally {
        await leased.release();
      }
    } finally {
      await pool.close();
    }
  });

  test('a failing first statement does not undo the reset', () async {
    final pool = await open();
    if (pool == null) return;
    try {
      await borrow(pool, dirty);
      final leased = await pool.acquire();
      try {
        final exec = PostgresQueryExecutor(b, leased.raw);
        await expectLater(
            exec.execute('SELECT 1/0'), throwsA(isA<QueryFailedException>()));
        expect(first(await exec.execute(stateSql)), clean);
      } finally {
        await leased.release();
      }
    } finally {
      await pool.close();
    }
  });

  test('the same holds when the failing first statement is Extended', () async {
    final pool = await open();
    if (pool == null) return;
    try {
      await borrow(pool, dirty);
      final leased = await pool.acquire();
      try {
        final exec = PostgresQueryExecutor(b, leased.raw);
        await expectLater(
            exec.execute(r'SELECT 1/$1::int', params: [const Param.int4(0)]),
            throwsA(isA<QueryFailedException>()));
        expect(first(await exec.execute(stateSql)), clean);
      } finally {
        await leased.release();
      }
    } finally {
      await pool.close();
    }
  });

  for (final (name, steps) in [
    ('open', [_s('BEGIN'), _s("SELECT 'in txn' AS v")]),
    ('aborted', [_s('BEGIN')]),
  ]) {
    test(
        'a connection returned with an $name transaction is rolled back '
        'at release', () async {
      final pool = await open();
      final observer = await open(defer: false);
      if (pool == null || observer == null) return;
      try {
        final leased = await pool.acquire();
        final exec = PostgresQueryExecutor(b, leased.raw);
        String? pid;
        for (final st in steps) {
          (await exec.execute(st.sql)).release();
        }
        pid = first(await exec.execute('SELECT pg_backend_pid()::text AS v'));
        if (name == 'aborted') {
          await expectLater(exec.execute('SELECT * FROM deferred_missing'),
              throwsA(isA<QueryFailedException>()));
        }
        await leased.release();
        // Seen from another connection before any new borrow: no
        // transaction left idle on the released one.
        expect(
            await borrow(observer, [
              _s('SELECT state AS v FROM pg_stat_activity WHERE pid = $pid')
            ]),
            'idle');
      } finally {
        await pool.close();
        await observer.close();
      }
    });
  }

  for (final (name, step) in [
    ('Simple', _s(stateSql)),
    (
      'Extended',
      _p('SELECT \$1::text || ($stateSql) AS v', [const Param.text('')])
    ),
  ]) {
    test('a failure inside the reset prefix is recovered — $name', () async {
      final pool = await open();
      if (pool == null) return;
      try {
        await borrow(pool, [
          _s('CREATE TABLE IF NOT EXISTS deferred_runs (x int)'),
          _s('TRUNCATE deferred_runs'),
        ]);
        await borrow(pool, dirty);
        DeferredSessionReset.debugFailingPrefix = true;
        try {
          // The statement runs once, after the standalone reset.
          expect(await borrow(pool, [step]), clean);
          expect(
              await borrow(pool, [
                _p(
                    'INSERT INTO deferred_runs VALUES (\$1) RETURNING '
                    "'1' AS v",
                    [const Param.int4(1)])
              ]),
              '1');
        } finally {
          DeferredSessionReset.debugFailingPrefix = false;
        }
        expect(
            await borrow(
                pool, [_s('SELECT count(*)::text AS v FROM deferred_runs')]),
            '1');
      } finally {
        await borrow(pool, [_s('DROP TABLE IF EXISTS deferred_runs')]);
        await pool.close();
      }
    });
  }

  test('with a library older than MINOR 6 the Extended reset goes standalone',
      () async {
    final pool = await open();
    if (pool == null) return;
    PostgresQueryExecutor.debugForceStandaloneReset = true;
    try {
      await borrow(pool, dirty);
      expect(await borrow(pool, [firstStatements['Extended, text result']!]),
          clean);
    } finally {
      PostgresQueryExecutor.debugForceStandaloneReset = false;
      await pool.close();
    }
  });

  test('pool executors never consume the pending reset', () async {
    final pool = await open();
    if (pool == null) return;
    try {
      final leased = await pool.acquire();
      final conn = leased.raw;
      await leased.release();
      final again = await pool.acquire();
      final exec =
          PostgresQueryExecutor(b, again.raw, applyDeferredReset: false);
      (await exec.execute('SELECT 1')).release();
      expect(DeferredSessionReset.isPending(conn), isTrue);
      await again.release();
    } finally {
      await pool.close();
    }
  });
}
