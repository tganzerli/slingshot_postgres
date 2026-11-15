/// Integration tests for the array parameters (`Param.*Array`): the server
/// must accept the binary arrays and see the same values, nulls included.
/// Requires the dev Postgres; skips if the native lib or server is missing.
library;

import 'dart:ffi' as ffi;

import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:slingshot_postgres/src/bindings/postgres_binding.dart';
import 'package:slingshot_postgres/src/native/postgres_lib_loader.dart';
import 'package:slingshot_postgres/src/native/postgres_native_pool.dart';
import 'package:slingshot_postgres/src/postgres/postgres_query_executor.dart';
import 'package:test/test.dart';

const _connInfo =
    'host=localhost port=5432 dbname=teste user=postgres password=123';

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

  late PostgresConnectionPool pool;
  var available = true;

  setUpAll(() async {
    pool = PostgresConnectionPool.withBinding(
        b, const PoolConfig(connInfo: _connInfo, minSize: 1, maxSize: 1));
    try {
      await pool.start();
    } on NativePoolStartupException {
      available = false;
    }
  });

  tearDownAll(() async {
    if (available) await pool.close();
  });

  // Runs [sql] with [params] and returns column `v` of the first row.
  Future<String?> one(String sql, List<Param> params) async {
    final leased = await pool.acquire();
    try {
      final rs = await PostgresQueryExecutor(b, leased.raw)
          .execute(sql, params: params);
      try {
        return rs.rowCount == 0 ? null : rs.row(0).getString('v');
      } finally {
        rs.release();
      }
    } finally {
      await leased.release();
    }
  }

  void check(String name, Future<void> Function() body) {
    test(name, () async {
      if (!available) {
        markTestSkipped(
            'Postgres not reachable — start PostgreSQL at localhost:5432');
        return;
      }
      await body();
    });
  }

  // Each array, its text form as the server prints it, and a member.
  final cases = <String, (Param, String, Param)>{
    'bool': (
      const Param.boolArray([true, null, false]),
      '{t,NULL,f}',
      const Param.bool(false)
    ),
    'int2': (
      const Param.int2Array([-3, null, 32767]),
      '{-3,NULL,32767}',
      const Param.int2(32767)
    ),
    'int4': (
      const Param.int4Array([1, null, -2147483648]),
      '{1,NULL,-2147483648}',
      const Param.int4(-2147483648)
    ),
    'int8': (
      const Param.int8Array([9007199254740993, null, -1]),
      '{9007199254740993,NULL,-1}',
      const Param.int8(9007199254740993)
    ),
    'float8': (
      const Param.float8Array([1.5, null, -0.25]),
      '{1.5,NULL,-0.25}',
      const Param.float8(-0.25)
    ),
    'text': (
      const Param.textArray(['a,"b"}', null, 'ção']),
      r'{"a,\"b\"}",NULL,ção}',
      const Param.text('a,"b"}')
    ),
    'uuid': (
      const Param.uuidArray([
        '00112233-4455-6677-8899-aabbccddeeff',
        null,
        'FFEEDDCCBBAA99887766554433221100',
      ]),
      '{00112233-4455-6677-8899-aabbccddeeff,NULL,'
          'ffeeddcc-bbaa-9988-7766-554433221100}',
      const Param.uuid('ffeeddcc-bbaa-9988-7766-554433221100')
    ),
  };

  for (final MapEntry(key: name, value: (array, text, member))
      in cases.entries) {
    check('$name[]: the server sees the same elements, null included',
        () async {
      expect(await one(r'SELECT $1::text AS v', [array]), text);
      expect(await one(r'SELECT array_length($1, 1)::text AS v', [array]), '3');
      expect(await one(r'SELECT array_position($1, NULL)::text AS v', [array]),
          '2');
      expect(await one(r'SELECT ($2 = ANY($1))::text AS v', [array, member]),
          'true');
    });
  }

  check('an empty array matches nothing with = ANY', () async {
    expect(
        await one(
            r'SELECT count(*)::text AS v FROM generate_series(1, 5) g '
            r'WHERE g = ANY($1)',
            [const Param.int8Array([])]),
        '0');
    expect(
        await one(
            r'SELECT cardinality($1)::text AS v', [const Param.uuidArray([])]),
        '0');
  });

  check('WHERE id = ANY(\$1) over uuids picks exactly the listed rows',
      () async {
    final leased = await pool.acquire();
    try {
      final exec = PostgresQueryExecutor(b, leased.raw);
      (await exec.execute('CREATE TEMP TABLE arr_probe (id uuid PRIMARY KEY, '
              'n int) ON COMMIT PRESERVE ROWS'))
          .release();
      (await exec.execute('INSERT INTO arr_probe '
              'SELECT gen_random_uuid(), g FROM generate_series(1, 20) g'))
          .release();
      final rs = await exec
          .execute('SELECT id::text AS v FROM arr_probe WHERE n IN (3, 7, 11)');
      final ids = [
        for (var i = 0; i < rs.rowCount; i++) rs.row(i).getString('v')!
      ];
      rs.release();
      final picked = await exec.execute(
          r"SELECT string_agg(n::text, ',' ORDER BY n) AS v FROM arr_probe "
          r'WHERE id = ANY($1)',
          params: [
            Param.uuidArray([...ids, null])
          ]);
      expect(picked.row(0).getString('v'), '3,7,11');
      picked.release();
      final unnested = await exec.execute(
          r'SELECT count(*)::text AS v FROM unnest($1::int4[]) x',
          params: [
            const Param.int4Array([1, 2, 3, 4])
          ]);
      expect(unnested.row(0).getString('v'), '4');
      unnested.release();
    } finally {
      await leased.release();
    }
  });

  check('untypedArrayOfNulls takes its type from the context', () async {
    expect(
        await one(
            r'SELECT count(*)::text AS v FROM generate_series(1, 3) g '
            r'WHERE g = ANY($1)',
            [const Param.untypedArrayOfNulls(0)]),
        '0');
    expect(
        await one(r'SELECT cardinality($1::uuid[])::text AS v',
            [const Param.untypedArrayOfNulls(2)]),
        '2');
  });
}
