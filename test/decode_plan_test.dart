/// Tests for the codec plan (plan cache, per-column decoders and
/// pointer parsers) against a real Postgres instance.
/// Requires PostgreSQL at localhost:5432.
library;

import 'dart:ffi' as ffi;
import 'dart:isolate';

import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:slingshot_postgres/src/bindings/postgres_binding.dart';
import 'package:slingshot_postgres/src/decoder/postgres_decode_plan.dart';
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

/// Issues [sql] and waits for the result. Returns null if Postgres is
/// unreachable or libnative_db is not built. Caller must [_dispose].
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

void _dispose(_QueryRun r) {
  while (true) {
    final extra = r.binding.pollResult(r.conn.ptr);
    if (extra == ffi.nullptr) break;
    r.binding.clearResult(extra);
  }
  r.conn.release();
  r.pool.destroy();
}

/// Skips the enclosing test when the DB/lib is unavailable.
bool _skipIfNull(_QueryRun? r) {
  if (r == null) {
    markTestSkipped('Postgres not reachable — start PostgreSQL at localhost:5432');
    return true;
  }
  return false;
}

void main() {
  group('PostgresPlanCache — keying & lifetime', () {
    test('same shape returns the SAME plan instance (hit)', () async {
      final cache = PostgresPlanCache();
      final r1 = await _runQuery('SELECT 1::int4 AS a, 2::int8 AS b');
      if (_skipIfNull(r1)) return;
      final r2 = await _runQuery('SELECT 9::int4 AS a, 8::int8 AS b');

      final cols1 = r1!.binding.getColCount(r1.result);
      final p1 = cache.planFor(r1.binding, r1.result, cols1, false);
      final cols2 = r2!.binding.getColCount(r2.result);
      final p2 = cache.planFor(r2.binding, r2.result, cols2, false);

      expect(identical(p1, p2), isTrue, reason: 'same shape → cached hit');
      expect(cache.size, 1);
      expect(p1.columnNames, ['a', 'b']);

      _dispose(r1);
      _dispose(r2);
    });

    test('same OIDs but different names → DISTINCT plans', () async {
      final cache = PostgresPlanCache();
      final r1 = await _runQuery('SELECT 1::int4 AS a, 2::int4 AS b');
      if (_skipIfNull(r1)) return;
      final r2 = await _runQuery('SELECT 1::int4 AS x, 2::int4 AS y');

      final p1 = cache.planFor(
          r1!.binding, r1.result, r1.binding.getColCount(r1.result), false);
      final p2 = cache.planFor(
          r2!.binding, r2.result, r2.binding.getColCount(r2.result), false);

      expect(identical(p1, p2), isFalse,
          reason: 'name verification must reject the fingerprint collision');
      expect(cache.size, 2);
      expect(p1.columnNames, ['a', 'b']);
      expect(p2.columnNames, ['x', 'y']);

      _dispose(r1);
      _dispose(r2);
    });

    test('binary flag distinguishes plans of the same shape', () async {
      final cache = PostgresPlanCache();
      final r = await _runQuery('SELECT 1::int4 AS a');
      if (_skipIfNull(r)) return;

      final cols = r!.binding.getColCount(r.result);
      final pText = cache.planFor(r.binding, r.result, cols, false);
      final pBin = cache.planFor(r.binding, r.result, cols, true);

      expect(identical(pText, pBin), isFalse);
      expect(cache.size, 2);

      _dispose(r);
    });

    test('eviction bounds the cache at the documented cap (256)', () async {
      final cache = PostgresPlanCache();
      _QueryRun? sample;
      // 260 distinct-name single-int4 shapes: same fingerprint, distinct
      // plans (name check misses each time) — exercises insert + evict.
      for (var k = 0; k < 260; k++) {
        final r = await _runQuery('SELECT 1::int4 AS c$k');
        if (_skipIfNull(r)) return;
        cache.planFor(
            r!.binding, r.result, r.binding.getColCount(r.result), false);
        if (sample == null) {
          sample = r;
        } else {
          _dispose(r);
        }
      }
      expect(cache.size, 256, reason: 'FIFO eviction caps total plans');
      if (sample != null) _dispose(sample);
    });
  });

  group('decode equivalence — plan cache ON vs OFF', () {
    const bigSelect = """
      SELECT
        true                                       AS booleano,
        (-7)::int2                                 AS short_,
        42::int4                                   AS i4,
        9223372036854775807::int8                  AS i8,
        3.14::float8                               AS dbl,
        (1.01)::numeric(12,2)                      AS num,
        'héllo'::text                              AS txt,
        ''::text                                   AS empty_,
        NULL::int4                                 AS nulo,
        '{"x":1}'::jsonb                           AS j,
        '2026-05-17 13:45:00.123+00'::timestamptz  AS ts,
        decode('48656c6c6f','hex')::bytea          AS bin
    """;

    test('cached and uncached decode to identical values', () async {
      final rc = await _runQuery(bigSelect);
      if (_skipIfNull(rc)) return;
      final ru = await _runQuery(bigSelect);

      final cached = PostgresResultSet.fromResult(rc!.binding, rc.result);
      final uncached =
          PostgresResultSet.fromResult(ru!.binding, ru.result, usePlanCache: false);

      final rowC = cached.row(0);
      final rowU = uncached.row(0);
      for (final col in cached.columnNames) {
        final vc = rowC[col];
        final vu = rowU[col];
        // bytea decodes to a fresh Uint8List each call → compare contents.
        expect('$vc', '$vu', reason: 'mismatch on column "$col"');
      }
      // Spot-check concrete values through the cached path (pointer parsers).
      expect(rowC.getBool('booleano'), isTrue);
      expect(rowC.getInt('short_'), -7);
      expect(rowC.getInt('i4'), 42);
      expect(rowC.getInt('i8'), 9223372036854775807);
      expect(rowC.getDouble('dbl'), closeTo(3.14, 0.001));
      expect(rowC.getString('txt'), 'héllo');
      expect(rowC.getString('empty_'), '');
      expect(rowC['nulo'], isNull);
      expect(rowC.getJson('j'), {'x': 1});

      cached.release();
      uncached.release();
      _dispose(rc);
      _dispose(ru);
    });

    test('int pointer parser handles sign / zero / int64 boundaries', () async {
      final r = await _runQuery("""
        SELECT
          '-9223372036854775808'::int8 AS i8_min,
          9223372036854775807::int8    AS i8_max,
          0::int8                      AS zero_,
          (-42)::int4                  AS neg4,
          (+7)::int4                   AS pos4
      """);
      if (_skipIfNull(r)) return;

      final rs = PostgresResultSet.fromResult(r!.binding, r.result);
      final row = rs.row(0);
      expect(row.getInt('i8_min'), -9223372036854775808);
      expect(row.getInt('i8_max'), 9223372036854775807);
      expect(row.getInt('zero_'), 0);
      expect(row.getInt('neg4'), -42);
      expect(row.getInt('pos4'), 7);

      rs.release();
      _dispose(r);
    });
  });

  group('public API preservation', () {
    test('multi-row iteration still yields rows in order', () async {
      final r = await _runQuery(
          'SELECT n FROM generate_series(1,5) AS t(n) ORDER BY n');
      if (_skipIfNull(r)) return;

      final rs = PostgresResultSet.fromResult(r!.binding, r.result);
      expect(rs.rowCount, 5);
      expect([for (final row in rs.rows) row.getInt('n')], [1, 2, 3, 4, 5]);

      rs.release();
      _dispose(r);
    });

    test('columnNames / columnOids are unmodifiable', () async {
      final r = await _runQuery('SELECT 1::int4 AS a, 2::int8 AS b');
      if (_skipIfNull(r)) return;

      final rs = PostgresResultSet.fromResult(r!.binding, r.result);
      expect(rs.columnNames, ['a', 'b']);
      expect(rs.columnOids, [PostgresOid.int4, PostgresOid.int8]);
      expect(() => rs.columnNames.add('c'), throwsUnsupportedError);
      expect(() => rs.columnOids.add(0), throwsUnsupportedError);

      rs.release();
      _dispose(r);
    });

    test('empty result set exposes an empty shape', () async {
      final rs = PostgresResultSet.empty();
      expect(rs.rowCount, 0);
      expect(rs.colCount, 0);
      expect(rs.columnNames, isEmpty);
      expect(rs.columnOids, isEmpty);
      rs.release();
    });
  });
}
