/// SQL injection regression — Extended Query Protocol (ABI MINOR 1).
///
/// Validates that values passed via [Param] cannot inject SQL, even when
/// the payload contains classic injection vectors (`'; DROP TABLE …`,
/// `' OR '1'='1`). Requires Docker Postgres up; skips gracefully when
/// the native lib or the database is unreachable.
library;

import 'dart:ffi' as ffi;

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

Future<void> _resetTable(PostgresQueryExecutorContract exec) async {
  await exec.execute('DROP TABLE IF EXISTS injection_target');
  await exec.execute('''
    CREATE TABLE injection_target (
      id int4 PRIMARY KEY,
      descricao text NOT NULL
    )
  ''');
  await exec.execute(
    'INSERT INTO injection_target (id, descricao) VALUES (\$1, \$2)',
    params: [Param.int4(1), Param.text('alpha')],
  );
  await exec.execute(
    'INSERT INTO injection_target (id, descricao) VALUES (\$1, \$2)',
    params: [Param.int4(2), Param.text('beta')],
  );
}

Future<bool> _tableExists(PostgresQueryExecutorContract exec, String table) async {
  final rs = await exec.execute(
    "SELECT to_regclass(\$1) IS NOT NULL AS exists",
    params: [Param.text('public.$table')],
  );
  try {
    return rs.row(0).getBool('exists')!;
  } finally {
    rs.release();
  }
}

Future<int> _rowCount(PostgresQueryExecutorContract exec, String table) async {
  // Identifiers can't be bound — but `table` is a hard-coded constant here,
  // so the inline interpolation is safe within this test helper.
  final rs = await exec.execute('SELECT count(*)::int4 AS n FROM $table');
  try {
    return rs.row(0).getInt('n')!;
  } finally {
    rs.release();
  }
}

void main() {
  if (!_canLoadNative()) {
    test('skipped (native library not built)', () {
      markTestSkipped('libnative_db not available');
    });
    return;
  }

  group('SQL injection through Param is structurally impossible', () {
    test("`'; DROP TABLE …; --` payload does not execute", () async {
      final binding = _binding();
      final pool = await _freshPool(binding).catchError((Object e) {
        markTestSkipped('Postgres not reachable: $e');
        throw e;
      });

      try {
        // Setup
        final setup = PostgresUnitOfWork(pool);
        await setup.begin();
        await _resetTable(setup.executor);
        await setup.commit();

        // Attack: classic injection vector as the *value* of a bound param.
        final attack = "'; DROP TABLE injection_target; --";

        final uow = PostgresUnitOfWork(pool);
        await uow.begin();
        try {
          final rs = await uow.executor.execute(
            'SELECT id FROM injection_target WHERE descricao = \$1',
            params: [Param.text(attack)],
          );
          try {
            // Server treats the payload as a literal value, finds zero
            // matches, and returns an empty result set.
            expect(rs.rowCount, 0,
                reason: 'injection payload must NOT match any row');
          } finally {
            rs.release();
          }
        } finally {
          await uow.commit();
        }

        // Crucially: the table is still alive with its original 2 rows.
        final check = PostgresUnitOfWork(pool);
        await check.begin();
        try {
          expect(await _tableExists(check.executor, 'injection_target'),
              isTrue,
              reason:
                  'attack must not have dropped the table — Param values '
                  'travel separately from SQL text in Extended Protocol');
          expect(await _rowCount(check.executor, 'injection_target'), 2,
              reason: 'no rows should have been added/removed by the attack');
        } finally {
          await check.commit();
        }
      } finally {
        await pool.close();
      }
    });

    test("`' OR '1'='1` payload does not widen the predicate", () async {
      final binding = _binding();
      final pool = await _freshPool(binding).catchError((Object e) {
        markTestSkipped('Postgres not reachable: $e');
        throw e;
      });

      try {
        final setup = PostgresUnitOfWork(pool);
        await setup.begin();
        await _resetTable(setup.executor);
        await setup.commit();

        final uow = PostgresUnitOfWork(pool);
        await uow.begin();
        try {
          final rs = await uow.executor.execute(
            'SELECT id FROM injection_target WHERE descricao = \$1',
            params: [Param.text("' OR '1'='1")],
          );
          try {
            // In string-concat code this payload would expand the WHERE
            // and return ALL rows. With Param it's a literal value
            // comparison: zero matches.
            expect(rs.rowCount, 0,
                reason: 'tautology payload must NOT expand the predicate');
          } finally {
            rs.release();
          }
        } finally {
          await uow.commit();
        }
      } finally {
        await pool.close();
      }
    });

    test('multi-statement `; UPDATE …` payload does not execute', () async {
      final binding = _binding();
      final pool = await _freshPool(binding).catchError((Object e) {
        markTestSkipped('Postgres not reachable: $e');
        throw e;
      });

      try {
        final setup = PostgresUnitOfWork(pool);
        await setup.begin();
        await _resetTable(setup.executor);
        await setup.commit();

        final uow = PostgresUnitOfWork(pool);
        await uow.begin();
        try {
          final rs = await uow.executor.execute(
            'SELECT id FROM injection_target WHERE descricao = \$1',
            params: [
              Param.text("alpha'; UPDATE injection_target SET descricao = 'pwned'; --"),
            ],
          );
          try {
            expect(rs.rowCount, 0);
          } finally {
            rs.release();
          }
        } finally {
          await uow.commit();
        }

        // None of the rows were updated — values still match initial seed.
        final check = PostgresUnitOfWork(pool);
        await check.begin();
        try {
          final rs = await check.executor.execute(
            'SELECT descricao FROM injection_target WHERE id = \$1',
            params: [Param.int4(1)],
          );
          try {
            expect(rs.row(0).getString('descricao'), 'alpha',
                reason: 'no row was overwritten by the attack');
          } finally {
            rs.release();
          }
        } finally {
          await check.commit();
        }
      } finally {
        await pool.close();
      }
    });
  });
}
