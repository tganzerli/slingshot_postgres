/// Several Extended statements in one round-trip (ABI MINOR 8).
library;

import '../decoder/postgres_result_row.dart';
import 'param.dart';

/// One statement of [PostgresBatchExecutor.executeBatch]: the SQL with
/// positional placeholders (`$1`, `$2`, …) and its parameters.
final class PgBatchQuery {
  const PgBatchQuery(this.sql, [this.params = const []]);

  final String sql;
  final List<Param> params;
}

/// Capability: run several independent Extended statements in one network
/// round-trip and get every result set back.
///
/// Implemented by `PostgresQueryExecutor`. It is a separate interface, not a
/// member of `PostgresQueryExecutorContract`, so wrapping executors keep
/// compiling; a wrapper that wants the round-trip saving implements it and
/// forwards. Helpers that take any executor (for example
/// `orbiter_postgres`'s `queryBatch`) check for it and otherwise run the
/// statements one after the other.
abstract interface class PostgresBatchExecutor {
  /// Sends [queries] together (after the transaction's pending BEGIN or
  /// session reset, if any) and returns one result set per query, in order.
  /// The caller releases every returned set.
  ///
  /// The statements must not depend on each other's results. The first one
  /// that fails aborts the rest: a `QueryFailedException` names it, with the
  /// server's message (and its SQLSTATE when the native library sends the
  /// batch; the sequential fallback for older libraries reports what
  /// `execute` reports), and the sets already read are released.
  /// A transaction around the batch stays open (aborted on error) and is the
  /// caller's to end; nothing is rolled back for it.
  ///
  /// With `PoolConfig.statementCacheSize` > 0, each statement goes through
  /// the connection's statement cache. An empty list returns an empty list.
  Future<List<PostgresResultSet>> executeBatch(List<PgBatchQuery> queries,
      {bool binaryResult = false});
}
