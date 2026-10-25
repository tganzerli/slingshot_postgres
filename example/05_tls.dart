// ignore_for_file: file_names — numbered prefix is intentional for didactic ordering.

/// 05 — TLS: verify-full with a client certificate, built with
/// [PostgresConnInfo].
///
/// [SslMode] has no default in the builder: you choose. Without an
/// `sslmode`, libpq uses `prefer`, which encrypts when it can but never
/// checks the certificate. `verifyFull` checks the chain against
/// `sslRootCert` and the host name against the certificate; the client
/// certificate is for servers with `clientcert=verify-full` in pg_hba.conf.
/// A failed handshake raises a [NativePoolStartupException] whose message is
/// libpq's reason (e.g. "certificate verify failed").
///
/// Run against a PostgreSQL with TLS (see "Local PostgreSQL with TLS" in the
/// package README), passing the directory that holds `ca.crt`, `client.crt`
/// and `client.key`. Host, port, database and credentials are set below
/// (`localhost:5434`, `postgres`); edit them for your server.
///   dart run example/05_tls.dart <certs-dir>
library;

import 'dart:io';

import 'package:slingshot_postgres/slingshot_postgres.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run example/05_tls.dart <certs-dir>');
    exit(64);
  }
  final certs = args.first;
  final pool = PostgresConnectionPool(PoolConfig(
    connInfo: PostgresConnInfo(
      host: 'localhost',
      port: 5434,
      database: 'teste',
      user: 'postgres',
      password: '123',
      sslMode: SslMode.verifyFull,
      sslRootCert: '$certs/ca.crt',
      sslCert: '$certs/client.crt',
      sslKey: '$certs/client.key',
    ).build(),
    maxSize: 2,
  ));
  await pool.start();
  try {
    final rs = await withTransaction<PostgresResultSet>(
        pool,
        (exec) => exec.execute('SELECT ssl, version, cipher FROM pg_stat_ssl '
            'WHERE pid = pg_backend_pid()'));
    final row = rs.row(0);
    print('ssl=${row[0]} version=${row[1]} cipher=${row[2]}');
    rs.release();
  } finally {
    await pool.close();
  }
}
