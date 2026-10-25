/// First-contact example for `slingshot`.
///
/// Opens a pool, runs a couple of queries inside a transaction, and
/// closes everything cleanly. Other files in this directory drill into
/// specific patterns (raw queries, repositories, pipelined writes,
/// diagnostics).
///
/// Run (with Postgres up at localhost:5432, dbname=teste):
///   dart run example/main.dart
library;

import 'package:slingshot_postgres/slingshot_postgres.dart';

const _connInfo =
    'host=localhost port=5432 dbname=teste user=postgres password=123';

Future<void> main() async {
  final pool = PostgresConnectionPool(
    const PoolConfig(connInfo: _connInfo, maxSize: 4),
  );
  await pool.start();

  try {
    final greeting = await withTransaction<String>(pool, (exec) async {
      final rs = await exec.execute("SELECT 'hello from libpq' AS msg");
      try {
        return rs.row(0).getString('msg')!;
      } finally {
        rs.release();
      }
    });
    print(greeting);
  } finally {
    await pool.close();
  }
}
