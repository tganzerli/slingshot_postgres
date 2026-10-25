// ignore_for_file: file_names — numbered prefix is intentional for didactic ordering.

/// 03 — Pipelined transaction for bulk OLTP writes.
///
/// `withPipelinedTransaction` issues `BEGIN; <queries...>; COMMIT;`
/// in a single network round-trip — vs N+2 for the sequential
/// pattern. Suited for batch INSERT/UPDATE/DELETE where command tags
/// (rows affected) are enough.
///
/// **v1 limitation:** result rows are NOT returned by the pipelined
/// path. For mixed read/write transactions, use the sequential
/// `withTransaction` in `02_transaction.dart`.
///
/// Run (with Postgres up at localhost:5432, dbname=teste):
///   dart run example/03_pipeline_oltp.dart
library;

import 'package:slingshot_postgres/slingshot_postgres.dart';

const _connInfo =
    'host=localhost port=5432 dbname=teste user=postgres password=123';

const _rows = 1000;

Future<void> main() async {
  final pool = PostgresConnectionPool(
    const PoolConfig(connInfo: _connInfo, maxSize: 4),
  );
  await pool.start();

  try {
    await withTransaction<void>(pool, (exec) async {
      await exec.execute('DROP TABLE IF EXISTS evento');
      await exec.execute('''
        CREATE TABLE evento (
          id      int4 PRIMARY KEY,
          payload text NOT NULL
        )
      ''');
    });
    print('[ok] table evento created');

    // Build a list of $_rows INSERTs and ship them as one pipeline.
    // Net effect on the wire: 1 BEGIN + N INSERTs + 1 COMMIT, all
    // batched in a single round-trip thanks to libpq pipeline mode.
    final queries = [
      for (var i = 0; i < _rows; i++)
        "INSERT INTO evento (id, payload) VALUES ($i, 'evt-$i')",
    ];

    final sw = Stopwatch()..start();
    await withPipelinedTransaction(pool, queries);
    sw.stop();
    print('[ok] $_rows inserts pipelined em ${sw.elapsedMilliseconds}ms');

    // Verify via a sequential read.
    final count = await withTransaction<int>(pool, (exec) async {
      final rs = await exec.execute('SELECT count(*)::int4 AS n FROM evento');
      try {
        return rs.row(0).getInt('n')!;
      } finally {
        rs.release();
      }
    });
    print('[ok] linhas persistidas: $count');
    assert(count == _rows, 'expected $_rows rows, got $count');
  } finally {
    await pool.close();
  }
}
