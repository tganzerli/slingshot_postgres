/// The startup exception must not print the password of the connection
/// string it was given, in any libpq format. Pure unit tests, no server.
library;

import 'package:slingshot_postgres/src/native/postgres_native_pool.dart';
import 'package:test/test.dart';

void main() {
  const secret = 's3cr3t';

  for (final (name, conninfo, kept) in [
    (
      'key=value',
      'host=db port=5432 dbname=app user=u password=$secret',
      'host=db port=5432 dbname=app user=u'
    ),
    ('password first', 'password=$secret host=db', 'host=db'),
    ('spaces around =', 'host=db password = $secret user=u', 'user=u'),
    (
      'quoted with spaces',
      "host=db password='$secret with space' user=u",
      'user=u'
    ),
    (
      'quoted with escaped quote',
      r"host=db password='s3cr3t\'x' user=u",
      'user=u'
    ),
    ('upper-case key', 'host=db PASSWORD=$secret', 'host=db'),
    (
      'URI userinfo',
      'postgresql://u:$secret@db:5432/app',
      'postgresql://u:***@db:5432/app'
    ),
    (
      'URI with raw @ in the password',
      'postgresql://u:p@$secret@db/app',
      'postgresql://u:***@db/app'
    ),
    (
      'postgres:// scheme',
      'postgres://u:$secret@db/app?sslmode=require',
      'sslmode=require'
    ),
    (
      'URI query password',
      'postgresql://u@db/app?password=$secret&sslmode=verify-full',
      'sslmode=verify-full'
    ),
  ]) {
    test('masks the password: $name', () {
      final text = NativePoolStartupException(conninfo).toString();
      expect(text, isNot(contains(secret)));
      expect(text, contains('***'));
      expect(text, contains(kept));
    });
  }

  test('the native message is shown, and masked if it echoes a password', () {
    final e = NativePoolStartupException('host=db password=$secret',
        nativeMessage: 'invalid connection option password=$secret');
    expect(e.toString(), contains('invalid connection option'));
    expect(e.toString(), isNot(contains(secret)));
    expect(
        NativePoolStartupException('host=db',
                nativeMessage: 'SSL error: certificate verify failed')
            .toString(),
        contains('certificate verify failed'));
  });

  test('without a native message the old hint stays', () {
    expect(NativePoolStartupException('host=db').toString(),
        contains('check Postgres reachability'));
  });

  test('a conninfo without password is unchanged', () {
    const c = 'host=db port=5432 dbname=app user=u';
    expect(redactConninfo(c), c);
  });

  test('the field keeps the full string for deliberate use', () {
    const c = 'host=db password=$secret';
    expect(NativePoolStartupException(c).conninfo, c);
  });
}
