/// Convenience helpers that wrap [PostgresUnitOfWork] lifecycle in a
/// single call.
///
/// Usage (`binding` resolved internally):
/// ```dart
/// final result = await withTransaction(pool, (exec) async {
///   final repo = ProdutoRepository(exec);
///   await repo.insert(...);
///   return await repo.findAll();
/// });
/// ```
///
/// The helper handles `begin → body → commit | rollback → close` so
/// callers don't reproduce the 7-line `try/catch/finally` boilerplate
/// for every transaction. If [body] throws, the transaction is rolled
/// back and the original exception is rethrown.
library;

import 'package:slingshot/slingshot.dart';
import 'package:meta/meta.dart';

import '../pool/postgres_connection_pool.dart';
import 'postgres_query_executor.dart';
import 'postgres_unit_of_work.dart';

/// Runs [body] inside a new [PostgresUnitOfWork] on a connection
/// acquired from [pool]. Returns the value produced by [body] after a
/// successful commit. Rolls back and rethrows on exception.
///
/// Example:
/// ```dart
/// final users = await withTransaction(pool, (exec) async {
///   final repo = UserRepository(exec);
///   await repo.insert(User(id: 1, name: 'Ada'));
///   return await repo.findAll();
/// });
/// ```
Future<T> withTransaction<T>(
  PostgresConnectionPool pool,
  Future<T> Function(PostgresQueryExecutorContract exec) body,
) {
  return withTransactionOn<T>(PostgresUnitOfWork(pool), body);
}

/// Same lifecycle as [withTransaction] but uses a pre-built [uow].
/// Useful for tests that inject a fake [UnitOfWork], or for callers
/// who need to pre-configure the UoW before binding the body.
Future<T> withTransactionOn<T>(
  UnitOfWork<PostgresQueryExecutorContract> uow,
  Future<T> Function(PostgresQueryExecutorContract exec) body,
) async {
  await uow.begin();
  try {
    final result = await body(uow.executor);
    await uow.commit();
    return result;
  } catch (_) {
    await uow.rollback();
    rethrow;
  } finally {
    await uow.close();
  }
}

/// Runs [queries] inside a single Postgres pipeline:
/// `BEGIN; <queries[0]>; ...; <queries[N-1]>; COMMIT;` in **one**
/// network round-trip total (vs N+1 for the sequential [withTransaction]
/// pattern — the BEGIN is fused into the first statement, so it
/// no longer costs a dedicated round-trip; the COMMIT still does).
///
/// **v1 limitation:** result rows are NOT returned (libpq pipeline
/// mode + our watcher's counting strategy discard them). Best suited
/// for bulk writes (`INSERT`/`UPDATE`/`DELETE`) where command tags
/// suffice. For mixed read/write patterns where you need rows, use
/// the sequential [withTransaction].
///
/// This self-contained helper is the recommended path for a standalone
/// write batch. When you already hold an external transaction, calling
/// `executePipeline(writes)` inside [withTransaction] also persists
/// correctly (since 2026-07-29) — the pipeline no longer discards the
/// surrounding open transaction.
///
/// On any failure (libpq dispatch error, mid-pipeline error,
/// timeout), the entire pipeline aborts and propagates the exception.
///
/// Added in ABI MAJOR 1 MINOR 1.
@experimental
Future<void> withPipelinedTransaction(
  PostgresConnectionPool pool,
  List<String> queries, {
  Duration? timeout,
}) async {
  if (queries.isEmpty) return;
  final leased = await pool.acquire();
  try {
    final exec =
        PostgresQueryExecutor(pool.binding, leased.raw, timeout: timeout);
    await exec.executePipeline([
      'BEGIN',
      ...queries,
      'COMMIT',
    ]);
  } finally {
    await leased.release();
  }
}
