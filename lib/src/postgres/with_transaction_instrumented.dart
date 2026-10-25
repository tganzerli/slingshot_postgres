/// Instrumented variant of [withTransaction] for diagnostics.
///
/// Identical lifecycle (`acquire → BEGIN → body → COMMIT|ROLLBACK →
/// release`) but captures Stopwatches around each phase and emits a
/// [TxDiagnostics] event to the provided sink. Bypasses [UnitOfWork]
/// abstraction to keep the timing surface narrow.
///
/// **Intentional divergence from the fused BEGIN:** this variant keeps
/// the `BEGIN` **eager** (a standalone dispatch, not fused into the
/// first body statement) so `beginUs` still measures one real
/// round-trip in isolation. It is diagnostic-only (opt-in) and must not
/// be used to benchmark the fused-BEGIN production path.
///
/// Use ONLY when [PoolConfig.instrumentationEnabled] is true. Otherwise
/// `acquireWaitUs`/`queueDepthAtAcquire` arrive null and the
/// diagnostics record is meaningless.
library;

import 'package:slingshot/slingshot.dart';
import 'package:meta/meta.dart';

import '../pool/postgres_connection_pool.dart';
import '../pool/postgres_pool_diagnostics.dart';
import 'postgres_query_executor.dart';

/// Runs [body] inside a fresh transaction on a connection acquired from
/// [pool], emitting a [TxDiagnostics] record to [sink] when the
/// transaction finishes (committed or rolled back).
///
/// Returns the value produced by [body]. Rolls back and rethrows on
/// exception. The diagnostics event is emitted even on the rollback
/// path (with `committed=false`).
@experimental
Future<T> withTransactionInstrumented<T>(
  PostgresConnectionPool pool,
  Future<T> Function(PostgresQueryExecutorContract exec) body,
  PoolDiagnosticsSink sink,
) async {
  final total = Stopwatch()..start();
  final leased = await pool.acquire();
  final exec = PostgresQueryExecutor(pool.binding, leased.raw);

  final acquireWaitUs = leased.acquireWaitUs ?? 0;
  final queueDepth = leased.queueDepthAtAcquire ?? 0;

  // BEGIN
  final beginSw = Stopwatch()..start();
  try {
    (await exec.execute('BEGIN')).release();
  } catch (e) {
    beginSw.stop();
    total.stop();
    await leased.release();
    sink(TxDiagnostics(
      acquireWaitUs: acquireWaitUs,
      queueDepthAtAcquire: queueDepth,
      beginUs: beginSw.elapsedMicroseconds,
      workUs: 0,
      commitUs: 0,
      totalUs: total.elapsedMicroseconds,
      committed: false,
    ));
    rethrow;
  }
  beginSw.stop();

  // body() — user work
  final workSw = Stopwatch()..start();
  T? result;
  Object? thrown;
  try {
    result = await body(exec);
  } catch (e) {
    thrown = e;
  }
  workSw.stop();

  // commit OR rollback
  final commitSw = Stopwatch()..start();
  bool committed = false;
  Object? finalError;
  try {
    if (thrown == null) {
      (await exec.execute('COMMIT')).release();
      committed = true;
    } else {
      (await exec.execute('ROLLBACK')).release();
    }
  } catch (e) {
    finalError = e;
  }
  commitSw.stop();
  total.stop();

  await leased.release();

  sink(TxDiagnostics(
    acquireWaitUs: acquireWaitUs,
    queueDepthAtAcquire: queueDepth,
    beginUs: beginSw.elapsedMicroseconds,
    workUs: workSw.elapsedMicroseconds,
    commitUs: commitSw.elapsedMicroseconds,
    totalUs: total.elapsedMicroseconds,
    committed: committed,
  ));

  if (thrown != null) {
    // ignore: only_throw_errors
    throw thrown;
  }
  if (finalError != null) {
    // ignore: only_throw_errors
    throw finalError;
  }
  return result as T;
}
