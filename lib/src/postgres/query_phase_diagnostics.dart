/// Per-query phase breakdown for the developed PostgreSQL driver.
///
/// Emitted once per `execute()` (simple or extended path) when a
/// [QueryPhaseSink] is wired into `PostgresQueryExecutor`. Used to decompose the
/// `driver_us` measured in the holistic benchmark into submit / wait /
/// decode.
///
/// Mirrors [TxDiagnostics] (`pool_diagnostics.dart`): all time fields are
/// in **microseconds** to match the `latency_us` column of the benchmark
/// CSVs. Diagnostic only — never allocated on the default (null-sink)
/// hot path.
library;

import 'dart:async';

import 'package:meta/meta.dart';

/// Timing decomposition of a single `execute()` call, in microseconds.
///
/// The three phases partition the driver-side wall-clock of one query on
/// the non-blocking path:
///
/// - [submitUs] + [waitUs] + [decodeUs] ≈ the query's user-facing
///   latency (minus the trivial null-check bookkeeping).
///
/// The lazy per-cell decode (`PostgresResultRow.operator[]`) is **not** counted
/// here — it happens on consumption, after `execute()` returns. Measure
/// it with the isolated decode micro-benchmark.
@experimental
class QueryPhases {
  /// Start of `execute()` → `poolSubmitQuery`/`poolSubmitQueryParams`
  /// returned. Covers `toNativeUtf8`, param marshalling (extended path
  /// only), and the FFI dispatch call.
  final int submitUs;

  /// Dispatch → the status int landed on the `ReceivePort`. Covers the
  /// worker thread-hop, network I/O against Postgres, the Native Port
  /// `post`, and the event-loop scheduling of the resumed `await`.
  final int waitUs;

  /// Port message → `PostgresResultSet` built. Covers `pollResult`, result-status
  /// inspection, metadata reads (col count / field names / OIDs), and the
  /// `PostgresResultSet` construction. Excludes lazy per-cell value decode.
  final int decodeUs;

  /// Row count of the resulting [PostgresResultSet] (result shape context).
  final int rowCount;

  /// Column count of the resulting [PostgresResultSet] (result shape context).
  final int colCount;

  const QueryPhases({
    required this.submitUs,
    required this.waitUs,
    required this.decodeUs,
    required this.rowCount,
    required this.colCount,
  });

  @override
  String toString() => 'QueryPhases(submit=${submitUs}us, wait=${waitUs}us, '
      'decode=${decodeUs}us, ${rowCount}x$colCount)';
}

/// Sink invoked once per query when phase instrumentation is wired into a
/// `PostgresQueryExecutor`.
///
/// Implementations must be cheap and non-blocking — the sink runs on the
/// query hot path. Buffer to a `List`/counter rather than doing I/O
/// inline.
///
/// The sink is called only for a query that succeeded, after its result is
/// ready, and it cannot change what `execute` returns: an exception thrown by
/// the sink goes to the current [Zone] (`Zone.handleUncaughtError`), never to
/// the caller. In the root zone that terminates the isolate, as any uncaught
/// error does; run under `runZonedGuarded` to observe it instead.
///
/// **Experimental:** the signature may gain a context parameter (e.g. the
/// SQL text or a query id) before 1.0.
@experimental
typedef QueryPhaseSink = void Function(QueryPhases phases);

/// Calls [sink] without letting it change the query's outcome: an exception
/// from the sink goes to the current zone, never to the caller.
@internal
void emitQueryPhases(QueryPhaseSink sink, QueryPhases phases) {
  try {
    sink(phases);
  } catch (e, st) {
    Zone.current.handleUncaughtError(e, st);
  }
}
