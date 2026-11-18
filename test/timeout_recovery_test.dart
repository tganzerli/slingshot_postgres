/// A query timeout costs the query, not the connection (k101).
///
/// Before the fix, the simple, parameterised, multi-read and pipeline paths
/// cancelled on expiry and returned without draining the cancel's result:
/// libpq kept a command in progress, every later dispatch on that connection
/// failed, and the slot stayed broken for the next borrowers too.
///
/// Two families of cases, on every path (the prefixed and cached paths
/// included):
///   * drained: a statement that sleeps far past the 5 s cancel grace times
///     out within ~the deadline, and the same session (same backend pid)
///     serves the same executor and the next borrow. If the cancel did not
///     take, the drain would give up, the slot would be reset and the pid
///     would change.
///   * not fully sent: 64 MiB cannot cross the socket in 1 ms, so the deadline
///     hits while sending. The session is given up (ConnectionLostException)
///     instead of the send being finished, and the INSERT never runs.
///
/// One-connection pools, so the next borrow is the same session. Requires
/// the dev Postgres; skips if the native lib or the server is missing.
library;

import 'dart:ffi' as ffi;
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:slingshot/slingshot.dart' show ConnectionLostException;
import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:slingshot_postgres/src/bindings/postgres_binding.dart';
import 'package:slingshot_postgres/src/native/postgres_lib_loader.dart';
import 'package:slingshot_postgres/src/native/postgres_native_pool.dart';
import 'package:slingshot_postgres/src/postgres/postgres_query_executor.dart';
import 'package:test/test.dart';

final _connInfo = Platform.environment['SLINGSHOT_PG_CONNINFO'] ??
    'host=localhost port=5432 dbname=teste user=postgres password=123';

const _short = Duration(milliseconds: 300);
const _tiny = Duration(milliseconds: 1);

/// How a path is driven: the executor flags it needs, and the pool's cache.
final class _Path {
  const _Path(this.name, {this.cache = 0, this.deferredBegin = false});
  final String name;
  final int cache;
  final bool deferredBegin;
}

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
  final hasCache = b.poolSubmitQueryCached != null;

  Future<PostgresConnectionPool?> open({int cache = 0}) async {
    final pool = PostgresConnectionPool.withBinding(
        b,
        PoolConfig(
          connInfo: _connInfo,
          minSize: 1,
          maxSize: 1,
          acquireTimeout: const Duration(seconds: 3),
          preservePreparedStatements: cache > 0,
          statementCacheSize: cache,
        ));
    try {
      await pool.start();
    } on NativePoolStartupException {
      markTestSkipped(
          'Postgres not reachable — start PostgreSQL at localhost:5432');
      return null;
    }
    return pool;
  }

  Future<String> text(PostgresQueryExecutor exec, String sql) async {
    final rs = await exec.execute(sql);
    try {
      return rs.row(0).getString('v')!;
    } finally {
      rs.release();
    }
  }

  Future<String> alive(PostgresQueryExecutor exec) async {
    final rs = await exec
        .execute(r'SELECT $1::text AS v', params: [Param.text('alive')]);
    try {
      return rs.row(0).getString('v')!;
    } finally {
      rs.release();
    }
  }

  Future<String> pid(PostgresQueryExecutor exec) =>
      text(exec, 'SELECT pg_backend_pid()::text AS v');

  PostgresQueryExecutor executor(
          _Path p, ffi.Pointer<ffi.Void> raw, Duration timeout) =>
      PostgresQueryExecutor(b, raw,
          timeout: timeout,
          deferredBegin: p.deferredBegin,
          statementCache: p.cache > 0);

  // ── drained ─────────────────────────────────────────────────────────

  final drained = <_Path, Future<void> Function(PostgresQueryExecutor)>{
    const _Path('simple'): (e) async =>
        (await e.execute('SELECT pg_sleep(10)')).release(),
    const _Path('parameterised'): (e) async =>
        (await e.execute(r'SELECT pg_sleep($1)', params: [Param.float8(10)]))
            .release(),
    const _Path('multi-read'): (e) async {
      for (final r
          in await e.executeMultiRead(['SELECT pg_sleep(10)', 'SELECT 1'])) {
        r.release();
      }
    },
    const _Path('pipeline'): (e) async =>
        e.executePipeline(['SELECT pg_sleep(10)', 'SELECT 1']),
    const _Path('pipeline in its own transaction'): (e) async =>
        e.executePipeline(['BEGIN', 'SELECT pg_sleep(10)', 'COMMIT']),
    const _Path('prefixed (fused BEGIN)', deferredBegin: true): (e) async =>
        (await e.execute(r'SELECT pg_sleep($1)', params: [Param.float8(10)]))
            .release(),
    const _Path('cached', cache: 8): (e) async =>
        (await e.execute(r'SELECT pg_sleep($1)', params: [Param.float8(10)]))
            .release(),
  };

  for (final entry in drained.entries) {
    final p = entry.key;
    test('${p.name}: a timeout is drained, the session kept', () async {
      if (p.cache > 0 && !hasCache) {
        markTestSkipped('library older than ABI MINOR 7');
        return;
      }
      final pool = await open(cache: p.cache);
      if (pool == null) return;
      try {
        String? before;
        final leased = await pool.acquire();
        try {
          final exec = executor(p, leased.raw, _short);
          // With a deferred BEGIN, the first statement must be the slow one.
          if (!p.deferredBegin) before = await pid(exec);
          final sw = Stopwatch()..start();
          await expectLater(
              entry.value(exec), throwsA(isA<QueryTimeoutException>()));
          expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
          // The fused BEGIN opened a transaction the caller ends.
          if (p.deferredBegin) (await exec.execute('ROLLBACK')).release();
          final now = await pid(exec);
          if (before != null) expect(now, before);
          before = now;
          expect(await alive(exec), 'alive');
          expect(
              await text(
                  exec, 'SELECT (now() <> statement_timestamp())::text AS v'),
              'false',
              reason: 'no transaction left open');
        } finally {
          await leased.release();
        }
        // The next borrow of the same (only) connection: same session.
        final next = await pool.acquire();
        try {
          final exec = PostgresQueryExecutor(b, next.raw,
              timeout: const Duration(seconds: 5));
          expect(await pid(exec), before);
          expect(await alive(exec), 'alive');
        } finally {
          await next.release();
        }
      } finally {
        await pool.close();
      }
    });
  }

  // ── not fully sent ──────────────────────────────────────────────────

  // A 64 MiB value: as a bytea parameter, or as a hex literal in the SQL text
  // for the paths that take no parameters.
  final big = Uint8List(64 << 20);
  final bigLiteral = "decode('${'00' * (64 << 20)}', 'hex')";

  final unsent = <_Path, Future<void> Function(PostgresQueryExecutor)>{
    const _Path('simple'): (e) async =>
        (await e.execute('INSERT INTO k101_big VALUES ($bigLiteral)'))
            .release(),
    const _Path('parameterised'): (e) async => (await e.execute(
            r'INSERT INTO k101_big VALUES ($1)',
            params: [Param.bytea(big)]))
        .release(),
    const _Path('multi-read'): (e) async {
      for (final r in await e.executeMultiRead(
          ['INSERT INTO k101_big VALUES ($bigLiteral)', 'SELECT 1'])) {
        r.release();
      }
    },
    const _Path('pipeline'): (e) async =>
        e.executePipeline(['INSERT INTO k101_big VALUES ($bigLiteral)']),
    const _Path('prefixed (fused BEGIN)', deferredBegin: true): (e) async =>
        (await e.execute(r'INSERT INTO k101_big VALUES ($1)',
                params: [Param.bytea(big)]))
            .release(),
    const _Path('cached', cache: 8): (e) async => (await e.execute(
            r'INSERT INTO k101_big VALUES ($1)',
            params: [Param.bytea(big)]))
        .release(),
  };

  for (final entry in unsent.entries) {
    final p = entry.key;
    test('${p.name}: a statement not fully sent by the deadline never runs',
        () async {
      if (p.cache > 0 && !hasCache) {
        markTestSkipped('library older than ABI MINOR 7');
        return;
      }
      final pool = await open(cache: p.cache);
      if (pool == null) return;
      Future<void> admin(String sql) async {
        final leased = await pool.acquire();
        try {
          (await PostgresQueryExecutor(b, leased.raw).execute(sql)).release();
        } finally {
          await leased.release();
        }
      }

      try {
        try {
          await admin('DROP TABLE IF EXISTS k101_big');
          // The bigserial's sequence advances when the INSERT executes, even
          // if its transaction never commits (the fused-BEGIN case): it shows
          // whether the statement ran, not only whether it was kept.
          await admin('CREATE TABLE k101_big (id bigserial, b bytea)');
          final first = await pool.acquire();
          final String oldPid;
          try {
            oldPid = await pid(PostgresQueryExecutor(b, first.raw));
          } finally {
            await first.release();
          }
          Object? error;
          final leased = await pool.acquire();
          try {
            try {
              await entry.value(executor(p, leased.raw, _tiny));
            } catch (e) {
              error = e;
            }
          } finally {
            await leased.release();
          }
          final check = await pool.acquire();
          try {
            final exec = PostgresQueryExecutor(b, check.raw);
            // Let the abandoned backend finish whatever it does with the
            // half-received message before looking at its effects.
            for (var i = 0; i < 50; i++) {
              final gone = await text(
                  exec,
                  'SELECT (count(*) = 0)::text AS v FROM pg_stat_activity '
                  'WHERE pid = $oldPid');
              if (gone == 'true') break;
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
            final ran = await text(
                exec,
                "SELECT (count(*) > 0 OR "
                "(SELECT is_called FROM k101_big_id_seq))::text AS v "
                'FROM k101_big');
            // Told it failed (or not told at all): it must not have run.
            expect(ran, 'false',
                reason: 'the INSERT ran; the caller got ${error.runtimeType}');
          } finally {
            await check.release();
          }
          expect(error, isA<ConnectionLostException>());
        } finally {
          await admin('DROP TABLE IF EXISTS k101_big');
        }
      } finally {
        await pool.close();
      }
    });
  }
}
