// ignore_for_file: file_names — numbered prefix is intentional for didactic ordering.

/// 04 — Per-transaction diagnostics with `withTransactionInstrumented`.
///
/// Wraps a transaction in [withTransactionInstrumented] and emits a
/// [TxDiagnostics] record to a [PoolDiagnosticsSink] for each commit
/// (or rollback). Useful to identify pool contention, slow BEGIN, or
/// long-running `body` callbacks.
///
/// Enable [PoolConfig.instrumentationEnabled] so the pool measures
/// `acquireWaitUs` and `queueDepthAtAcquire`. Overhead is ≤2% TPS.
///
/// **Experimental:** the [TxDiagnostics] record may gain fields
/// (`lockWaitUs`, `walFlushUs`, ...) before 1.0.
///
/// Run (with Postgres up at localhost:5432, dbname=teste):
///   dart run example/04_diagnostics.dart
library;

import 'package:slingshot_postgres/slingshot_postgres.dart';

const _connInfo =
    'host=localhost port=5432 dbname=teste user=postgres password=123';

void main() async {
  final pool = PostgresConnectionPool(
    const PoolConfig(
      connInfo: _connInfo,
      maxSize: 4,
      instrumentationEnabled: true,
    ),
  );
  await pool.start();

  try {
    // Collect diagnostics into a list. In production, push to a
    // metrics backend (Prometheus, StatsD, OpenTelemetry).
    final events = <TxDiagnostics>[];
    void sink(TxDiagnostics diag) => events.add(diag);

    await withTransaction<void>(pool, (exec) async {
      await exec.execute('DROP TABLE IF EXISTS counter');
      await exec.execute('''
        CREATE TABLE counter (
          id int4 PRIMARY KEY,
          n  int4 NOT NULL
        )
      ''');
      await exec.execute('INSERT INTO counter (id, n) VALUES (1, 0)');
    });

    // Run 5 instrumented transactions and observe how the timings
    // break down (acquire vs begin vs body vs commit).
    for (var i = 0; i < 5; i++) {
      await withTransactionInstrumented<void>(pool, (exec) async {
        await exec.execute('UPDATE counter SET n = n + 1 WHERE id = 1');
      }, sink);
    }

    print('[ok] coletadas ${events.length} amostras');
    for (var i = 0; i < events.length; i++) {
      final d = events[i];
      print('  tx[$i] '
          'acquire=${d.acquireWaitUs}us '
          'qdepth=${d.queueDepthAtAcquire} '
          'begin=${d.beginUs}us '
          'work=${d.workUs}us '
          'commit=${d.commitUs}us '
          'total=${d.totalUs}us '
          'committed=${d.committed}');
    }
  } finally {
    await pool.close();
  }
}
