/// Full-text search conformance: a generated `tsvector` column with a GIN
/// index, queried with `to_tsquery` and a text parameter through
/// `withTransaction`, reading the `tsvector` column back as a `String` in
/// both result formats.
///
/// Requires the dev Postgres; skips if the native lib or server is missing.
library;

import 'dart:ffi' as ffi;

import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:slingshot_postgres/src/bindings/postgres_binding.dart';
import 'package:slingshot_postgres/src/native/postgres_lib_loader.dart';
import 'package:slingshot_postgres/src/native/postgres_native_pool.dart';
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

  test(
      'generated tsvector + GIN + to_tsquery(Param.text) + ts_rank '
      'via withTransaction', () async {
    final pool = PostgresConnectionPool.withBinding(
        b, const PoolConfig(connInfo: _connInfo, minSize: 1, maxSize: 1));
    try {
      await pool.start();
    } on NativePoolStartupException {
      markTestSkipped(
          'Postgres not reachable — start PostgreSQL at localhost:5432');
      return;
    }
    try {
      await withTransaction(pool, (exec) async {
        Future<void> run(String sql) async =>
            (await exec.execute(sql)).release();

        // Temporary and dropped on commit: nothing is left in the dev
        // database, and concurrent runs do not collide.
        await run('''
          CREATE TEMP TABLE fts_pacientes (
            id int PRIMARY KEY,
            nome_busca text NOT NULL,
            busca tsvector GENERATED ALWAYS AS
              (to_tsvector('simple', nome_busca)) STORED
          ) ON COMMIT DROP''');
        await run('CREATE INDEX fts_pacientes_busca_gin '
            'ON fts_pacientes USING GIN (busca)');
        await run('INSERT INTO fts_pacientes (id, nome_busca) VALUES '
            "(1, 'joao da silva'), (2, 'joana silveira'), (3, 'maria souza')");

        const sql = r'SELECT id, busca, '
            r"ts_rank(busca, to_tsquery('simple', $1)) AS rank "
            r'FROM fts_pacientes '
            r"WHERE busca @@ to_tsquery('simple', $1) "
            r'ORDER BY rank DESC, id';
        for (final binary in [false, true]) {
          final rs = await exec.execute(sql,
              params: [Param.text('jo:* & sil:*')], binaryResult: binary);
          try {
            expect(rs.rowCount, 2, reason: 'binary=$binary');
            expect(rs.typeOf('busca'), PostgresType.text);
            final byId = {for (final r in rs.rows) r.getInt('id'): r};
            expect(byId[1]!.getString('busca'), "'da':2 'joao':1 'silva':3");
            expect(byId[2]!.getString('busca'), "'joana':1 'silveira':2");
            expect(byId[1]!.getDouble('rank'), greaterThan(0));
          } finally {
            rs.release();
          }
        }

        // The GIN index serves the parameterised predicate. Sequential
        // scan is turned off because three rows would never pick the
        // index on cost.
        await run('SET LOCAL enable_seqscan = off');
        final plan = await exec.execute(
            'EXPLAIN (COSTS OFF) SELECT id FROM fts_pacientes '
            r"WHERE busca @@ to_tsquery('simple', $1)",
            params: [Param.text('jo:*')]);
        try {
          final lines = [for (final r in plan.rows) r.getString('QUERY PLAN')];
          expect(lines.join('\n'), contains('fts_pacientes_busca_gin'));
        } finally {
          plan.release();
        }
      });
    } finally {
      await pool.close();
    }
  });
}
