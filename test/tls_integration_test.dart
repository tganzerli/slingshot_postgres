/// TLS through the connector, against a server that requires TLS from every
/// client, signs with a CA of its own, authenticates `postgres` by a client
/// certificate and `tls_nocert` by password only. Skips when the native lib,
/// the certificates or the server are missing.
///
/// Env: TLS_PG_PORT (default 5434); TLS_PG_CERTS, a directory with ca.crt,
/// client.crt, client.key (CN=postgres) and other-ca.crt (an unrelated CA).
/// Setting up such a server: README, "Local PostgreSQL with TLS".
library;

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:slingshot/slingshot.dart'
    show ConnectionLostException;
import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:slingshot_postgres/src/bindings/postgres_binding.dart';
import 'package:slingshot_postgres/src/native/postgres_lib_loader.dart';
import 'package:slingshot_postgres/src/native/postgres_native_pool.dart';
import 'package:slingshot_postgres/src/postgres/postgres_query_executor.dart';
import 'package:test/test.dart';

final _port = Platform.environment['TLS_PG_PORT'] ?? '5434';
final _certs = Platform.environment['TLS_PG_CERTS'];

String _conn({
  String user = 'postgres',
  String sslmode = 'verify-full',
  String? rootCert,
  bool clientCert = true,
  String host = 'host=localhost',
}) {
  final b = StringBuffer(
      '$host port=$_port dbname=teste user=$user password=123 sslmode=$sslmode');
  b.write(' sslrootcert=${rootCert ?? '$_certs/ca.crt'}');
  if (clientCert) {
    b.write(' sslcert=$_certs/client.crt sslkey=$_certs/client.key');
  }
  return b.toString();
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
  if (_certs == null || !File('$_certs/ca.crt').existsSync()) {
    test('skipped (no TLS certificates)', () {
      markTestSkipped('set TLS_PG_CERTS to a directory with ca.crt, '
          'client.crt, client.key and other-ca.crt; see the README, '
          '"Local PostgreSQL with TLS"');
    });
    return;
  }
  final b = binding;

  Future<PostgresConnectionPool?> open(String connInfo, {int size = 2}) async {
    final pool = PostgresConnectionPool.withBinding(
        b,
        PoolConfig(
            connInfo: connInfo,
            minSize: size,
            maxSize: size,
            acquireTimeout: const Duration(seconds: 5)));
    try {
      await pool.start();
    } on NativePoolStartupException {
      return null;
    }
    return pool;
  }

  Future<String?> scalar(PostgresConnectionPool pool, String sql) =>
      withPostgresConnection(pool, (exec) async {
        final rs = await exec.execute(sql);
        final v = rs.rowCount > 0 ? rs.row(0)[0]?.toString() : null;
        rs.release();
        return v;
      });

  const sslOfSession =
      'SELECT ssl::text FROM pg_stat_ssl WHERE pid = pg_backend_pid()';

  group('TLS succeeds', () {
    test('verify-full + client certificate, through the pool', () async {
      final pool = await open(_conn());
      if (pool == null) {
        markTestSkipped('TLS Postgres not reachable on $_port');
        return;
      }
      try {
        expect(await scalar(pool, sslOfSession), 'true');
        expect(
            await scalar(pool,
                'SELECT version FROM pg_stat_ssl WHERE pid = pg_backend_pid()'),
            startsWith('TLSv1.'));
      } finally {
        await pool.close();
      }
    });

    test('verify-full + client certificate, through withTransaction', () async {
      final pool = await open(_conn());
      if (pool == null) {
        markTestSkipped('TLS Postgres not reachable on $_port');
        return;
      }
      try {
        final r = await withTransaction(pool, (exec) async {
          await exec.execute('CREATE TEMP TABLE tls_probe (x int)');
          await exec.execute('INSERT INTO tls_probe VALUES (7)');
          final rs = await exec.execute(sslOfSession);
          final v = rs.row(0)[0]?.toString();
          rs.release();
          return v;
        });
        expect(r, 'true');
      } finally {
        await pool.close();
      }
    });

    test('the typed builder connects with verify-full and a client cert',
        () async {
      final pool = await open(PostgresConnInfo(
        host: 'localhost',
        port: int.parse(_port),
        database: 'teste',
        user: 'postgres',
        password: '123',
        sslMode: SslMode.verifyFull,
        sslRootCert: '$_certs/ca.crt',
        sslCert: '$_certs/client.crt',
        sslKey: '$_certs/client.key',
      ).build());
      if (pool == null) {
        markTestSkipped('TLS Postgres not reachable on $_port');
        return;
      }
      try {
        expect(await scalar(pool, sslOfSession), 'true');
      } finally {
        await pool.close();
      }
    });

    test('the extended protocol (parameters) works under TLS', () async {
      final pool = await open(_conn());
      if (pool == null) {
        markTestSkipped('TLS Postgres not reachable on $_port');
        return;
      }
      try {
        final v = await withPostgresConnection(pool, (exec) async {
          final rs = await exec
              .execute(r'SELECT $1::int + 1 AS v', params: [Param.int4(41)]);
          final v = rs.row(0).getInt('v');
          rs.release();
          return v;
        });
        expect(v, 42);
      } finally {
        await pool.close();
      }
    });

    test('verify-full without a client certificate, for a user that needs none',
        () async {
      final pool = await open(_conn(user: 'tls_nocert', clientCert: false));
      if (pool == null) {
        markTestSkipped('TLS Postgres not reachable on $_port');
        return;
      }
      try {
        expect(await scalar(pool, sslOfSession), 'true');
      } finally {
        await pool.close();
      }
    });
  });

  group('TLS fails', () {
    Future<NativePoolStartupException?> startupFailure(String connInfo) async {
      final pool = PostgresConnectionPool.withBinding(
          b, PoolConfig(connInfo: connInfo, minSize: 1, maxSize: 1));
      try {
        await pool.start();
        await pool.close();
        return null;
      } on NativePoolStartupException catch (e) {
        return e;
      }
    }

    // Skip the negative cases when the server is down, or every one of
    // them would "fail" for the wrong reason.
    Future<bool> serverUp() async {
      final pool = await open(_conn(), size: 1);
      await pool?.close();
      return pool != null;
    }

    // The libpq reason reaches the exception (ABI MINOR 4).
    for (final (name, connInfo, cause) in [
      (
        'postgres without a client certificate',
        _conn(clientCert: false),
        'client certificate'
      ),
      (
        'a foreign CA',
        _conn(
            user: 'tls_nocert',
            clientCert: false,
            rootCert: '$_certs/other-ca.crt'),
        'certificate verify failed'
      ),
      (
        'a host name outside the certificate',
        _conn(
            user: 'tls_nocert',
            clientCert: false,
            host: 'hostaddr=127.0.0.1 host=wrong.example'),
        'does not match host name'
      ),
      (
        'no TLS at all',
        _conn(user: 'tls_nocert', clientCert: false, sslmode: 'disable'),
        'no encryption'
      ),
    ]) {
      test('startup fails with $name, and says why', () async {
        if (!await serverUp()) {
          markTestSkipped('TLS Postgres not reachable on $_port');
          return;
        }
        final e = await startupFailure(connInfo);
        expect(e, isNotNull);
        expect(e!.nativeMessage, contains(cause));
        expect(e.toString(), contains(cause));
        expect(e.toString(), isNot(contains('password=123')));
      });
    }
  });

  group('the worker under TLS', () {
    // A response that is already decrypted in libpq's buffer does not make
    // the socket readable again; a worker that select()s before checking
    // PQisBusy would sleep there. Large payloads in both directions, no
    // native timeout, and a Dart-side deadline to turn a hang into a
    // failure.
    test('large responses and large statements never stall', () async {
      final pool = await open(_conn(), size: 1);
      if (pool == null) {
        markTestSkipped('TLS Postgres not reachable on $_port');
        return;
      }
      final big = 'x' * (2 << 20);
      try {
        for (var i = 0; i < 10; i++) {
          final n = await withPostgresConnection(pool, (exec) async {
            final rs = await exec.execute(
                "SELECT repeat('y', 1000) FROM generate_series(1, 20000)");
            final n = rs.rowCount;
            rs.release();
            return n;
          }).timeout(const Duration(seconds: 20));
          expect(n, 20000);
          final len = await scalar(pool, "SELECT length('$big')")
              .timeout(const Duration(seconds: 20));
          expect(len, '${big.length}');
          final plen = await withPostgresConnection(pool, (exec) async {
            final rs = await exec
                .execute(r'SELECT length($1) AS n', params: [Param.text(big)]);
            final v = rs.row(0).getInt('n');
            rs.release();
            return v;
          }).timeout(const Duration(seconds: 20));
          expect(plen, big.length);
        }
      } finally {
        await pool.close();
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('cancelling a query works under hostssl-only pg_hba', () async {
      final pool = await open(_conn(), size: 1);
      if (pool == null) {
        markTestSkipped('TLS Postgres not reachable on $_port');
        return;
      }
      try {
        final leased = await pool.acquire();
        final exec = PostgresQueryExecutor(b, leased.raw);
        Future<void>.delayed(
            const Duration(milliseconds: 300), () => b.poolCancel(leased.raw));
        final sw = Stopwatch()..start();
        Object? err;
        try {
          (await exec.execute('SELECT pg_sleep(10)')).release();
        } catch (e) {
          err = e;
        }
        sw.stop();
        await leased.release();
        expect(sw.elapsedMilliseconds, lessThan(5000),
            reason: 'the cancel request must reach the server');
        expect(err, isNotNull);
      } finally {
        await pool.close();
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    // The lost link may surface on the next query (ConnectionLostException)
    // or be absorbed by release()'s session reset, which meets the dead
    // link first and lets the worker reconnect. Either way the session
    // that comes back must be a new backend, still on TLS.
    test('a lost link reconnects with TLS again', () async {
      final pool = await open(_conn(), size: 1);
      if (pool == null) {
        markTestSkipped('TLS Postgres not reachable on $_port');
        return;
      }
      try {
        final pid1 = await scalar(pool, 'SELECT pg_backend_pid()::text');
        await scalar(pool, 'SELECT pg_terminate_backend(pg_backend_pid())')
            .catchError((Object _) => null);
        Future<String?> retry(String sql) async {
          try {
            return await scalar(pool, sql);
          } on ConnectionLostException {
            return scalar(pool, sql);
          }
        }

        final pid2 = await retry('SELECT pg_backend_pid()::text');
        expect(pid2, isNot(pid1));
        expect(await retry(sslOfSession), 'true');
      } finally {
        await pool.close();
      }
    });
  });
}
