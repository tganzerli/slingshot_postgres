/// Tests for the opt-in per-query phase instrumentation
/// (`QueryPhaseSink`).
///
/// Verifies that (1) a wired sink emits exactly one [QueryPhases] per
/// `execute()` with non-negative phases and the correct result shape,
/// (2) the extended (params) path also emits, and (3) with a null sink
/// the behaviour is identical to the baseline — no emission, same
/// [PostgresResultSet]. The instrumentation must never change results, only
/// observe them.
library;

import 'dart:ffi' as ffi;

import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:slingshot_postgres/src/bindings/postgres_binding.dart';
import 'package:slingshot_postgres/src/native/postgres_lib_loader.dart';
import 'package:slingshot_postgres/src/postgres/postgres_query_executor.dart';
import 'package:slingshot_postgres/src/postgres/query_phase_diagnostics.dart';
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
    const PoolConfig(connInfo: _connInfo, minSize: 1, maxSize: 1),
  );
  await pool.start();
  return pool;
}

void main() {
  if (!_canLoadNative()) {
    test('skipped (native library not built)', () {
      markTestSkipped('libnative_db not available');
    });
    return;
  }

  group('Query phase instrumentation (opt-in)', () {
    late PostgresBinding b;
    late PostgresConnectionPool pool;

    setUp(() async {
      b = _binding();
      pool = await _freshPool(b).catchError((Object e) {
        markTestSkipped('Postgres not reachable: $e');
        throw e;
      });
    });

    tearDown(() async {
      await pool.close();
    });

    test('simple path emits exactly one QueryPhases with the result shape',
        () async {
      final leased = await pool.acquire();
      try {
        final phases = <QueryPhases>[];
        final exec =
            PostgresQueryExecutor(b, leased.raw, phaseSink: phases.add);
        final rs = await exec.execute('SELECT 1 AS a, 2 AS b');
        rs.release();

        expect(phases, hasLength(1));
        final p = phases.single;
        expect(p.submitUs, greaterThanOrEqualTo(0));
        expect(p.waitUs, greaterThanOrEqualTo(0));
        expect(p.decodeUs, greaterThanOrEqualTo(0));
        expect(p.rowCount, 1);
        expect(p.colCount, 2);
      } finally {
        await leased.release();
      }
    });

    test('extended (params) path also emits one QueryPhases', () async {
      final leased = await pool.acquire();
      try {
        final phases = <QueryPhases>[];
        final exec =
            PostgresQueryExecutor(b, leased.raw, phaseSink: phases.add);
        final rs = await exec.execute(
          'SELECT \$1::int AS v',
          params: [Param.int4(7)],
        );
        expect(rs.row(0).getInt('v'), 7);
        rs.release();

        expect(phases, hasLength(1));
        expect(phases.single.colCount, 1);
      } finally {
        await leased.release();
      }
    });

    test('one emission per query across a loop', () async {
      final leased = await pool.acquire();
      try {
        final phases = <QueryPhases>[];
        final exec =
            PostgresQueryExecutor(b, leased.raw, phaseSink: phases.add);
        for (var i = 0; i < 5; i++) {
          (await exec.execute('SELECT $i AS n')).release();
        }
        expect(phases, hasLength(5));
      } finally {
        await leased.release();
      }
    });

    test('null sink (default): no emission, unchanged result', () async {
      final leased = await pool.acquire();
      try {
        final exec = PostgresQueryExecutor(b, leased.raw); // no phaseSink
        final rs = await exec.execute('SELECT 42 AS answer');
        expect(rs.row(0).getInt('answer'), 42);
        rs.release();
        // No observable side channel exists when the sink is null; the
        // assertion is that the query behaves exactly like the baseline.
      } finally {
        await leased.release();
      }
    });
  });
}
