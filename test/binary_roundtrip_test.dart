/// End-to-end binary wire-format roundtrip — ABI MINOR 1.
///
/// For each canonical [Param] subclass whose binary decoder is
/// implemented, INSERT a value via `params:` then `SELECT` it back
/// with `binaryResult: true` and assert the decoded value equals the
/// original. Validates the **encoder ↔ Postgres ↔ decoder** loop
/// against a real server (PostgreSQL 16).
///
/// `numeric` is excluded — binary `numeric` is not decoded yet (see
/// `decodeByOidBinary` docstring); covered in unit tests as raw bytes.
library;

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:slingshot_postgres/src/bindings/postgres_binding.dart';
import 'package:slingshot_postgres/src/native/postgres_lib_loader.dart';
import 'package:test/test.dart';

const _connInfo =
    'host=localhost port=5432 dbname=teste user=postgres password=123';

bool _canLoadNative() {
  try {
    loadNativeDb();
    return true;
  } on StateError {
    return false;
  }
}

PostgresBinding _binding() {
  final b = PostgresBinding(loadNativeDb());
  b.initDartApi(ffi.NativeApi.initializeApiDLData);
  return b;
}

Future<PostgresConnectionPool> _freshPool(PostgresBinding b) async {
  final pool = PostgresConnectionPool.withBinding(
    b,
    const PoolConfig(connInfo: _connInfo, minSize: 1, maxSize: 2),
  );
  await pool.start();
  return pool;
}

/// Inserts [value] into a single-column table of [pgType], reads it back
/// with `binaryResult: true`, and returns the decoded value.
Future<Object?> _roundtrip(
  PostgresConnectionPool pool,
  String pgType,
  Param value,
) async {
  final tbl = 'rt_${pgType.replaceAll(RegExp(r'[^a-z0-9]'), '_')}';

  final setup = PostgresUnitOfWork(pool);
  await setup.begin();
  await setup.executor.execute('DROP TABLE IF EXISTS $tbl');
  await setup.executor.execute('CREATE TABLE $tbl (v $pgType)');
  await setup.executor.execute(
    'INSERT INTO $tbl (v) VALUES (\$1)',
    params: [value],
  );
  await setup.commit();

  final read = PostgresUnitOfWork(pool);
  await read.begin();
  final rs = await read.executor.execute(
    'SELECT v FROM $tbl',
    binaryResult: true,
  );
  try {
    expect(rs.rowCount, 1, reason: 'inserted row not retrievable');
    return rs.row(0)['v'];
  } finally {
    rs.release();
    await read.commit();
  }
}

/// Reads the same expression twice — text format and binary format —
/// and returns both decoded values.
Future<(Object?, Object?)> _bothFormats(
  PostgresConnectionPool pool,
  String selectExpr,
) async {
  final uow = PostgresUnitOfWork(pool);
  await uow.begin();
  try {
    final t = await uow.executor.execute('SELECT $selectExpr AS v');
    final textValue = t.row(0)['v'];
    t.release();
    final b = await uow.executor
        .execute('SELECT $selectExpr AS v', binaryResult: true);
    final binValue = b.row(0)['v'];
    b.release();
    return (textValue, binValue);
  } finally {
    await uow.commit();
  }
}

void main() {
  if (!_canLoadNative()) {
    test('skipped (native library not built)', () {
      markTestSkipped('libnative_db not available');
    });
    return;
  }

  late PostgresBinding binding;
  late PostgresConnectionPool pool;

  setUpAll(() async {
    binding = _binding();
    try {
      pool = await _freshPool(binding);
    } catch (e) {
      pool = PostgresConnectionPool.withBinding(
        binding,
        const PoolConfig(connInfo: _connInfo, minSize: 1, maxSize: 2),
      );
      markTestSkipped('Postgres not reachable: $e');
    }
  });

  tearDownAll(() async {
    await pool.close().catchError((_) {});
  });

  group('binary roundtrip', () {
    test('bool', () async {
      expect(await _roundtrip(pool, 'bool', Param.bool(true)), true);
      expect(await _roundtrip(pool, 'bool', Param.bool(false)), false);
    });

    test('numeric — binary reconstruction equals the server own text',
        () async {
      // The server renders the text; our base-10000 parser renders the
      // binary. Agreement on all of these is the real proof that the
      // reconstruction is right, including the padding rules.
      const cases = <String>[
        '1234.56',
        '0.001',
        '-0.5',
        '10000',
        '10002',
        '0',
        '1.5000',
        '99999999999999999999.99999999',
        '-1234567890123456789.0123456',
      ];
      for (final c in cases) {
        final (t, b) = await _bothFormats(pool, '($c)::numeric');
        expect(b, isA<PostgresNumeric>(), reason: 'binary for $c');
        expect(t, isA<PostgresNumeric>(), reason: 'text for $c');
        expect(b.toString(), t.toString(), reason: 'formats disagree on $c');
        expect(t.toString(), c, reason: 'server text for $c');
      }
    });

    test('numeric — declared scale is preserved, not normalised', () async {
      final (t, b) = await _bothFormats(pool, '(1.5)::numeric(12,4)');
      expect(t.toString(), '1.5000');
      expect(b.toString(), '1.5000');
    });

    test('numeric — NaN survives both formats', () async {
      final (t, b) = await _bothFormats(pool, "('NaN')::numeric");
      expect((t as PostgresNumeric).isNaN, isTrue);
      expect((b as PostgresNumeric).isNaN, isTrue);
    });

    test('date', () async {
      final v = DateTime(2026, 5, 17);
      final got = await _roundtrip(pool, 'date', Param.date(v)) as DateTime;
      expect([got.year, got.month, got.day], [2026, 5, 17]);
      expect(got.isUtc, isFalse);
      // Pre-epoch, to exercise the signed int32 against a real server.
      final old = await _roundtrip(pool, 'date', Param.date(DateTime(1970, 1, 1)))
          as DateTime;
      expect([old.year, old.month, old.day], [1970, 1, 1]);
    });

    test('uuid', () async {
      const v = '6ba7b810-9dad-11d1-80b4-00c04fd430c8';
      expect(await _roundtrip(pool, 'uuid', Param.uuid(v)), v);
    });

    test('int2', () async {
      expect(await _roundtrip(pool, 'int2', Param.int2(-7)), -7);
      expect(await _roundtrip(pool, 'int2', Param.int2(0x7FFF)), 0x7FFF);
    });

    test('int4', () async {
      expect(await _roundtrip(pool, 'int4', Param.int4(123456)), 123456);
      expect(
          await _roundtrip(pool, 'int4', Param.int4(-0x80000000)),
          -0x80000000);
    });

    test('int8', () async {
      expect(await _roundtrip(pool, 'int8', Param.int8(1 << 40)), 1 << 40);
    });

    test('float4', () async {
      final v = await _roundtrip(pool, 'float4', Param.float4(3.5)) as double;
      expect(v, closeTo(3.5, 1e-6));
    });

    test('float8', () async {
      final v =
          await _roundtrip(pool, 'float8', Param.float8(2.71828)) as double;
      expect(v, 2.71828);
    });

    test('text', () async {
      // Multi-byte UTF-8 to exercise the codec on both ends.
      expect(await _roundtrip(pool, 'text', Param.text('café')), 'café');
    });

    test('varchar', () async {
      expect(await _roundtrip(pool, 'varchar(16)', Param.varchar('hello')),
          'hello');
    });

    test('bpchar (blank-padded char)', () async {
      // bpchar(8) pads the value with spaces to width 8.
      expect(await _roundtrip(pool, 'char(8)', Param.bpchar('abc')),
          'abc     ');
    });

    test('json', () async {
      final v = await _roundtrip(pool, 'json', Param.json('{"k":1,"a":[2,3]}'))
          as Map;
      expect(v['k'], 1);
      expect(v['a'], [2, 3]);
    });

    test('jsonb', () async {
      final v =
          await _roundtrip(pool, 'jsonb', Param.jsonb('{"x":true}')) as Map;
      expect(v['x'], true);
    });

    test('bytea', () async {
      final raw = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x42]);
      final v = await _roundtrip(pool, 'bytea', Param.bytea(raw)) as Uint8List;
      expect(v, raw);
    });

    test('timestamp', () async {
      final ts = DateTime.utc(2026, 5, 23, 14, 30, 45, 123, 456);
      final v = await _roundtrip(pool, 'timestamp', Param.timestamp(ts))
          as DateTime;
      // Changed 2026-09-10: `timestamp` decodes naive, so comparing
      // epoch microseconds would measure the runner's UTC offset rather
      // than the round-trip. The wall-clock reading is what survives.
      expect(v.isUtc, isFalse);
      expect([v.year, v.month, v.day, v.hour, v.minute, v.second],
          [2026, 5, 23, 14, 30, 45]);
      expect(v.microsecond, 456);
      expect(v.millisecond, 123);
    });

    test('timestamptz', () async {
      final ts = DateTime.utc(2026, 5, 23, 14, 30, 45, 123, 456);
      final v =
          await _roundtrip(pool, 'timestamptz', Param.timestamptz(ts))
              as DateTime;
      expect(v.microsecondsSinceEpoch, ts.microsecondsSinceEpoch);
    });
  });

  group('SQL NULL roundtrip via Param.nullValue', () {
    test('nullValue(text) inserts SQL NULL and reads back as null',
        () async {
      final v = await _roundtrip(
          pool, 'text', Param.nullValue(PostgresOid.text));
      expect(v, isNull);
    });

    test('nullValue(int4) inserts SQL NULL and reads back as null',
        () async {
      final v = await _roundtrip(
          pool, 'int4', Param.nullValue(PostgresOid.int4));
      expect(v, isNull);
    });
  });

  group('catalog types (name, "char") decode as String in both formats', () {
    test('name', () async {
      final (t, b) = await _bothFormats(pool, "'rls_prova'::name");
      expect(t, 'rls_prova');
      expect(b, 'rls_prova');
    });

    test('"char"', () async {
      final (t, b) = await _bothFormats(pool, "'r'::\"char\"");
      expect(t, 'r');
      expect(b, 'r');
    });

    test('"char" with the high bit set agrees across formats', () async {
      // charout renders it as `\ooo` (PostgreSQL 15+); the binary path
      // must produce the same String from the raw byte. The int4 cast is
      // signed, so 0xE9 is -23.
      final (t, b) = await _bothFormats(pool, "(-23)::int4::\"char\"");
      expect(t, r'\351');
      expect(b, t);
    });

    test('pg_class.relname and relkind', () async {
      final (t, b) = await _bothFormats(
          pool, "(SELECT relname FROM pg_class WHERE relname = 'pg_class')");
      expect(t, 'pg_class');
      expect(b, 'pg_class');
      final (kt, kb) = await _bothFormats(
          pool, "(SELECT relkind FROM pg_class WHERE relname = 'pg_class')");
      expect(kt, 'r');
      expect(kb, 'r');
    });
  });

  group('text search types decode as String in both formats', () {
    const tsvectors = [
      "to_tsvector('simple', 'João da Silva')",
      "'a:1A,2B,3C,4 b'::tsvector",
      r"$$'it''s' 'back\\slash'$$::tsvector",
      "strip(to_tsvector('simple', 'x y'))",
      "''::tsvector",
    ];
    const tsqueries = [
      "to_tsquery('simple', 'jo:* & sil:*')",
      "'a & (b | c)'::tsquery",
      "'!(a & b) | c'::tsquery",
      "'a <-> b <2> c'::tsquery",
      "'a <-> (b <-> c)'::tsquery",
      "'a:*AB & !b:C'::tsquery",
      r"$$'it''s' & 'back\\slash'$$::tsquery",
      "''::tsquery",
    ];
    for (final e in [...tsvectors, ...tsqueries]) {
      test(e, () async {
        final (t, b) = await _bothFormats(pool, e);
        expect(t, isA<String>());
        expect(b, t);
      });
    }

    test('jo:* & sil:* reads as the server prints it', () async {
      final (t, b) =
          await _bothFormats(pool, "to_tsquery('simple', 'jo:* & sil:*')");
      expect(t, "'jo':* & 'sil':*");
      expect(b, t);
    });

    test('regconfig: name in text, decimal OID in binary', () async {
      final (t, b) = await _bothFormats(pool, "'simple'::regconfig");
      final (oid, _) =
          await _bothFormats(pool, "'simple'::regconfig::oid::text");
      expect(t, 'simple');
      expect(b, oid);
    });
  });
}
