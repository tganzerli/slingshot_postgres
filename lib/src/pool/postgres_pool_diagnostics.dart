/// Per-transaction diagnostic record for the `PostgresConnectionPool`.
///
/// Emitted by [withTransactionInstrumented] when
/// [PoolConfig.instrumentationEnabled] is true.
///
/// All time fields are in **microseconds** to match the existing
/// `latency_us` column of the benchmark results.
library;

import 'dart:async';

import 'package:meta/meta.dart';

@experimental
class TxDiagnostics {
  /// Time from `pool.acquire()` call to obtaining a `PooledConnection`.
  /// In a healthy 1×1 case this is near zero (fast path on idle stack).
  /// In a contended 4×4 case it grows with the depth of the `_waiters`
  /// queue.
  final int acquireWaitUs;

  /// Length of the `_waiters` queue at the moment `acquire()` was
  /// called. 0 means fast path (idle conn available or pool can grow).
  final int queueDepthAtAcquire;

  /// Round-trip time of the explicit `BEGIN` statement (without
  /// pool-acquire overhead).
  final int beginUs;

  /// Wall-clock time spent in the user `body(executor)` callback (i.e.
  /// the SELECT/UPDATE/INSERT round-trips of the transaction).
  final int workUs;

  /// Round-trip time of `COMMIT` (or `ROLLBACK` on failure).
  final int commitUs;

  /// Sum of the above (≈ user-facing latency of the transaction).
  final int totalUs;

  /// True if the transaction committed; false if rolled back.
  final bool committed;

  const TxDiagnostics({
    required this.acquireWaitUs,
    required this.queueDepthAtAcquire,
    required this.beginUs,
    required this.workUs,
    required this.commitUs,
    required this.totalUs,
    required this.committed,
  });
}

/// Sink invoked once per transaction when instrumentation is on.
///
/// Passed to [withTransactionInstrumented] (and similar instrumented
/// helpers). Implementations should be cheap and non-blocking — the
/// sink runs on the transaction's hot path. Buffer to a `StreamController`
/// or stats counter rather than doing I/O inline.
///
/// The sink cannot change the transaction's outcome: an exception thrown by
/// it goes to the current [Zone] (`Zone.handleUncaughtError`), never to the
/// caller, who still gets the body's value or the original error. In the
/// root zone that terminates the isolate, as any uncaught error does; run
/// under `runZonedGuarded` to observe it instead.
///
/// **Experimental:** the function signature may gain a context
/// parameter (e.g. transaction ID) before 1.0.
@experimental
typedef PoolDiagnosticsSink = void Function(TxDiagnostics diag);

/// Calls [sink] without letting it change the transaction's outcome: an
/// exception from the sink goes to the current zone, never to the caller.
@internal
void emitTxDiagnostics(PoolDiagnosticsSink sink, TxDiagnostics diag) {
  try {
    sink(diag);
  } catch (e, st) {
    Zone.current.handleUncaughtError(e, st);
  }
}
