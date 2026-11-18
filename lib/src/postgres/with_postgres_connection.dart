/// Non-transactional counterpart of [withTransaction]: runs a body on a pooled
/// PostgreSQL connection WITHOUT opening a transaction.
///
/// Use this for read-only / autocommit work where a transaction's BEGIN +
/// COMMIT round-trips would be pure overhead. A single read costs one
/// round-trip here; inside [withTransaction] it costs up to three (BEGIN +
/// statement + COMMIT — and on the Extended Query path the BEGIN-piggyback
/// does not fuse, so all three are paid). For atomicity across statements,
/// use [withTransaction] instead.
///
/// The [PostgresQueryExecutorContract] passed to [body] runs each statement in the server's
/// autocommit mode. Result sets read inside [body] must be fully consumed
/// (and `release()`d) before [body] returns — the connection goes back to the
/// pool on return.
///
/// SECURITY: for untrusted values use `execute(sql, params: …)` (Extended
/// Query Protocol) inside the body, never string interpolation.
///
/// Note on fan-out: for N reads in one logical request, prefer a single
/// `executeMultiRead([...])` inside one [withPostgresConnection] over N
/// separate calls — N acquire/release cycles churn the pool under load.
library;

import '../pool/postgres_connection_pool.dart';
import 'postgres_query_executor.dart';

/// Runs [body] over a connection acquired from [pool], with no transaction,
/// and always releases the connection. Returns [body]'s value.
Future<T> withPostgresConnection<T>(
  PostgresConnectionPool pool,
  Future<T> Function(PostgresQueryExecutorContract exec) body,
) async {
  final leased = await pool.acquire();
  try {
    return await body(PostgresQueryExecutor(pool.binding, leased.raw,
        statementCache: pool.statementCacheEnabled));
  } finally {
    await leased.release();
  }
}
