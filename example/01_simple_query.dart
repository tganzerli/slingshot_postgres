// ignore_for_file: file_names — numbered prefix is intentional for didactic ordering.

/// 01 — Simple query: pool → execute → PostgresResultSet decoding.
///
/// Shows how to inspect column metadata and decode typed values from
/// a [PostgresResultSet]. The query runs inside [withTransaction] because the
/// public API exposes the [PostgresQueryExecutorContract] only inside a transaction
/// frame. For pure read-only workloads, the cost of a single BEGIN +
/// COMMIT round-trip is negligible.
///
/// Run (with Postgres up at localhost:5432, dbname=teste):
///   dart run example/01_simple_query.dart
library;

import 'package:slingshot_postgres/slingshot_postgres.dart';

const _connInfo =
    'host=localhost port=5432 dbname=teste user=postgres password=123';

Future<void> main() async {
  final pool = PostgresConnectionPool(
    const PoolConfig(connInfo: _connInfo, maxSize: 2),
  );
  await pool.start();

  try {
    final rs = await withTransaction<PostgresResultSet>(pool, (exec) async {
      return exec.execute('''
        SELECT
          42 AS the_answer,
          'foo' AS the_label,
          current_timestamp AS now_ts
      ''');
    });

    try {
      print('rows=${rs.rowCount}  cols=${rs.colCount}');
      for (var c = 0; c < rs.colCount; c++) {
        print('  col[$c] name=${rs.columnNames[c]}  oid=${rs.columnOids[c]}'
            '  type=${rs.typeOf(c)}');
      }

      final row = rs.row(0);
      print('row[0].the_answer = ${row.getInt('the_answer')}');
      print('row[0].the_label  = ${row.getString('the_label')}');
      print('row[0].now_ts     = ${row.getDateTime('now_ts')}');
    } finally {
      rs.release();
    }
  } finally {
    await pool.close();
  }
}
