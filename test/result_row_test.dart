/// Integration tests for the type decoder + PostgresResultRow against a real
/// Postgres instance. Requires PostgreSQL at localhost:5432.
///
/// ABI MAJOR 2 (2026-05-20): migrated from raw `connect_db` +
/// `start_query_async` to a 1-conn `NativePool` per test (retro B2).
library;

import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:slingshot_postgres/src/bindings/postgres_binding.dart';
import 'package:slingshot_postgres/src/native/postgres_native_pool.dart';
import 'package:slingshot_postgres/src/native/postgres_lib_loader.dart';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

const _connInfo =
    'host=localhost port=5432 dbname=teste user=postgres password=123';

typedef _QueryRun = ({
  PostgresBinding binding,
  NativePool pool,
  NativeConn conn,
  ffi.Pointer<ffi.Void> result,
});

/// Issues [sql], waits for the result. Returns null if Postgres
/// unreachable or libnative_db not built. Caller is responsible for
/// calling [_dispose] on the returned record once it is done with
/// the PGresult.
Future<_QueryRun?> _runQuery(String sql) async {
  late final PostgresBinding binding;
  try {
    binding = PostgresBinding(loadNativeDb());
  } on StateError {
    return null;
  }

  binding.initDartApi(ffi.NativeApi.initializeApiDLData);

  final NativePool pool;
  try {
    pool = NativePool.create(
      binding: binding,
      conninfo: _connInfo,
      maxSize: 1,
      acquireTimeout: const Duration(seconds: 5),
    );
  } on NativePoolStartupException {
    return null;
  }

  final conn = pool.acquire();
  final port = ReceivePort();
  final sqlPtr = sql.toNativeUtf8();
  final status =
      binding.poolSubmitQuery(conn.ptr, sqlPtr, port.sendPort.nativePort, 0);
  malloc.free(sqlPtr);
  if (status != 1) {
    port.close();
    conn.release();
    pool.destroy();
    return null;
  }
  await port.first;
  port.close();
  final result = binding.pollResult(conn.ptr);
  return (binding: binding, pool: pool, conn: conn, result: result);
}

/// Releases the conn + tears down the pool that backed [_runQuery].
void _dispose(_QueryRun r) {
  // Drain any residual PGresult so the conn returns to the pool clean.
  while (true) {
    final extra = r.binding.pollResult(r.conn.ptr);
    if (extra == ffi.nullptr) break;
    r.binding.clearResult(extra);
  }
  r.conn.release();
  r.pool.destroy();
}

void main() {
  group('PostgresResultSet / PostgresResultRow', () {
    test('decodes all primary Postgres types', () async {
      final r = await _runQuery("""
        SELECT
          true                                       AS booleano,
          (-7)::int2                                 AS short_,
          42::int4                                   AS i4,
          9223372036854775807::int8                  AS i8,
          3.14::float8                               AS dbl,
          'hello'::text                              AS txt,
          NULL::int4                                 AS nulo,
          '{"x":1}'::jsonb                           AS j,
          '2026-05-17 13:45:00.123+00'::timestamptz  AS ts,
          decode('48656c6c6f','hex')::bytea          AS bin
      """);
      if (r == null) {
        markTestSkipped(
            'Postgres not reachable — start PostgreSQL at localhost:5432');
        return;
      }

      final rs = PostgresResultSet.fromResult(r.binding, r.result);
      expect(rs.rowCount, 1);
      expect(rs.colCount, 10);
      expect(rs.typeOf('booleano'), PostgresType.boolean);
      expect(rs.typeOf('short_'), PostgresType.smallInt);
      expect(rs.typeOf('i4'), PostgresType.integer);
      expect(rs.typeOf('i8'), PostgresType.bigInt);
      expect(rs.typeOf('dbl'), PostgresType.double_);
      expect(rs.typeOf('txt'), PostgresType.text);
      expect(rs.typeOf('j'), PostgresType.jsonb);
      expect(rs.typeOf('ts'), PostgresType.timestamptz);
      expect(rs.typeOf('bin'), PostgresType.bytea);

      final row = rs.row(0);
      expect(row.getBool('booleano'), isTrue);
      expect(row.getInt('short_'), -7);
      expect(row.getInt('i4'), 42);
      expect(row.getInt('i8'), 9223372036854775807);
      expect(row.getDouble('dbl'), closeTo(3.14, 0.001));
      expect(row.getString('txt'), 'hello');
      expect(row['nulo'], isNull);
      expect(row.getJson('j'), {'x': 1});

      final ts = row.getDateTime('ts')!;
      expect(ts.toUtc(), DateTime.utc(2026, 5, 17, 13, 45, 0, 123));

      final bytes = row.getBytes('bin') as Uint8List;
      expect(bytes, [0x48, 0x65, 0x6c, 0x6c, 0x6f]); // "Hello"

      rs.release();
      _dispose(r);
    });

    test('column access by index and name yield the same value', () async {
      final r = await _runQuery("SELECT 'foo'::text AS bar");
      if (r == null) {
        markTestSkipped('Postgres not reachable');
        return;
      }

      final rs = PostgresResultSet.fromResult(r.binding, r.result);
      final row = rs.row(0);
      expect(row[0], row['bar']);
      expect(row[0], 'foo');

      rs.release();
      _dispose(r);
    });

    test('unknown column name throws ArgumentError', () async {
      final r = await _runQuery("SELECT 1::int4 AS x");
      if (r == null) {
        markTestSkipped('Postgres not reachable');
        return;
      }

      final rs = PostgresResultSet.fromResult(r.binding, r.result);
      expect(() => rs.row(0)['does_not_exist'], throwsArgumentError);

      rs.release();
      _dispose(r);
    });

    test('multi-row iteration yields rows in order', () async {
      final r = await _runQuery(
          "SELECT n FROM generate_series(1,5) AS t(n) ORDER BY n");
      if (r == null) {
        markTestSkipped('Postgres not reachable');
        return;
      }

      final rs = PostgresResultSet.fromResult(r.binding, r.result);
      expect(rs.rowCount, 5);
      final values = [for (final row in rs.rows) row.getInt('n')];
      expect(values, [1, 2, 3, 4, 5]);

      rs.release();
      _dispose(r);
    });

    test('toMap materialises all columns', () async {
      final r = await _runQuery(
          "SELECT 1::int4 AS a, 'b'::text AS b, true::bool AS c");
      if (r == null) {
        markTestSkipped('Postgres not reachable');
        return;
      }

      final rs = PostgresResultSet.fromResult(r.binding, r.result);
      final m = rs.row(0).toMap();
      expect(m, {'a': 1, 'b': 'b', 'c': true});

      rs.release();
      _dispose(r);
    });
  });

  // Dart-C boundary audit (2026-11-02): nothing handed to the caller may
  // depend on native memory once `release()` has run.
  group('after release()', () {
    // Only a reliable regression guard under `MallocScribble=1` (macOS),
    // which overwrites freed blocks with 0x55: without it a stale view may
    // still read the old bytes and pass by luck. The deterministic guard
    // is the unit test in binary_decoder_test.dart.
    test('a type without a decoder keeps its own bytes past release', () async {
      final r =
          await _runQuery("SELECT '{1,2}'::int4[] AS a, '10.0.0.1'::inet AS b");
      if (r == null) {
        markTestSkipped('Postgres not reachable');
        return;
      }

      final rs = PostgresResultSet.fromResult(r.binding, r.result);
      final row = rs.row(0);
      final a = row['a'] as Uint8List;
      final b = row['b'] as Uint8List;
      expect(String.fromCharCodes(a), '{1,2}');
      expect(String.fromCharCodes(b), '10.0.0.1');
      rs.release();

      // Same connection, same result shape: the allocator is free to hand
      // the old PGresult block to this query.
      while (true) {
        final extra = r.binding.pollResult(r.conn.ptr);
        if (extra == ffi.nullptr) break;
        r.binding.clearResult(extra);
      }
      final port = ReceivePort();
      final sqlPtr =
          "SELECT '{9,8}'::int4[] AS a, '99.9.9.9'::inet AS b".toNativeUtf8();
      expect(
          r.binding
              .poolSubmitQuery(r.conn.ptr, sqlPtr, port.sendPort.nativePort, 0),
          1);
      malloc.free(sqlPtr);
      await port.first;
      port.close();
      final second = PostgresResultSet.fromResult(
          r.binding, r.binding.pollResult(r.conn.ptr));
      expect(String.fromCharCodes(second.row(0)['a'] as Uint8List), '{9,8}');

      expect(String.fromCharCodes(a), '{1,2}');
      expect(String.fromCharCodes(b), '10.0.0.1');

      second.release();
      _dispose(r);
    });

    test('reading a retained row throws StateError', () async {
      final r = await _runQuery(
          "SELECT 7::int4 AS c, 'hello'::text AS d, '{1,2}'::int4[] AS a");
      if (r == null) {
        markTestSkipped('Postgres not reachable');
        return;
      }

      final rs = PostgresResultSet.fromResult(r.binding, r.result);
      final row = rs.row(0);
      expect(row.getInt('c'), 7);
      rs.release();

      expect(() => row['c'], throwsStateError);
      expect(() => row[1], throwsStateError);
      expect(() => row.getString('d'), throwsStateError);
      expect(() => row.getBytes('a'), throwsStateError);
      expect(() => row.toMap(), throwsStateError);
      expect(() => row['no_such_column'], throwsStateError,
          reason: 'the released state is the real cause, not the name');
      expect(() => rs.row(0), throwsStateError);
      expect(() => rs.rows, throwsStateError);
      expect(row.toString(), contains('released'),
          reason: 'printing a row while debugging must not throw');

      // Metadata lives on the Dart side and stays readable.
      expect(rs.columnNames, ['c', 'd', 'a']);
      expect(rs.rowCount, 1);

      rs.release(); // idempotent, does not throw
      _dispose(r);
    });
  });
}
