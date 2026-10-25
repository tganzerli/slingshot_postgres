/// PostgresConnInfo builds a libpq connection string with TLS as an explicit
/// choice. Pure unit tests, no server.
library;

import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:slingshot_postgres/src/native/postgres_native_pool.dart'
    show redactConninfo;
import 'package:test/test.dart';

void main() {
  test('the six libpq modes', () {
    expect(SslMode.values.map((m) => m.libpq), [
      'disable',
      'allow',
      'prefer',
      'require',
      'verify-ca',
      'verify-full',
    ]);
  });

  test('every value is quoted, and only the given options appear', () {
    const c = PostgresConnInfo(
        host: 'db', database: 'app', user: 'u', sslMode: SslMode.require);
    expect(c.build(),
        "host='db' port='5432' dbname='app' user='u' sslmode='require'");
  });

  test('TLS files, timeout and application name', () {
    const c = PostgresConnInfo(
      host: 'db.example.com',
      port: 6543,
      database: 'app',
      user: 'app',
      password: 'pw',
      sslMode: SslMode.verifyFull,
      sslRootCert: '/etc/ssl/ca.pem',
      sslCert: '/etc/ssl/app.crt',
      sslKey: '/etc/ssl/app.key',
      sslCrl: '/etc/ssl/crl.pem',
      connectTimeout: 5,
      applicationName: 'myapp',
    );
    expect(
        c.build(),
        "host='db.example.com' port='6543' dbname='app' user='app' "
        "password='pw' sslmode='verify-full' sslrootcert='/etc/ssl/ca.pem' "
        "sslcert='/etc/ssl/app.crt' sslkey='/etc/ssl/app.key' "
        "sslcrl='/etc/ssl/crl.pem' connect_timeout='5' application_name='myapp'");
  });

  test(r"quotes and backslashes are escaped the libpq way", () {
    const c = PostgresConnInfo(
        host: 'db',
        database: 'my db',
        user: 'u',
        password: r"it's a \secret",
        sslMode: SslMode.disable);
    final s = c.build();
    expect(s, contains(r"dbname='my db'"));
    expect(s, contains(r"password='it\'s a \\secret'"));
  });

  test('the password the builder writes is the one the redaction masks', () {
    const c = PostgresConnInfo(
        host: 'db',
        database: 'app',
        user: 'u',
        password: r"Zq9'k x\Vb",
        sslMode: SslMode.verifyFull);
    final redacted = redactConninfo(c.build());
    for (final piece in ['Zq9', 'k x', 'Vb']) {
      expect(redacted, isNot(contains(piece)));
    }
    expect(redacted, contains('password=***'));
    expect(redacted, contains("sslmode='verify-full'"));
  });

  test('toString never shows the password', () {
    const c = PostgresConnInfo(
        host: 'db',
        database: 'app',
        user: 'u',
        password: 'secret',
        sslMode: SslMode.verifyFull);
    expect(c.toString(), isNot(contains('secret')));
    expect(c.toString(), contains('verify-full'));
  });
}
