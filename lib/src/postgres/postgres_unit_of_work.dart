/// Postgres-backed [UnitOfWork] implementation.
///
/// Pins a single [PooledConnection] for the lifetime of a transaction,
/// issues `COMMIT` / `ROLLBACK` as SQL, and exposes a
/// [PostgresQueryExecutor] over the same connection while the
/// transaction is active. The `BEGIN` is deferred and
/// fused into the first statement of the body to save one round-trip;
/// see [PostgresUnitOfWork.begin].
library;

import 'package:slingshot/slingshot.dart';
import '../pool/postgres_connection_pool.dart';
import 'postgres_query_executor.dart';

/// Postgres-backed [UnitOfWork] over a [PostgresConnectionPool].
///
/// Acquires a single [PooledConnection] on [begin], pins it for the
/// transaction's lifetime, defers `BEGIN` into the first body statement,
/// issues `COMMIT` / `ROLLBACK` as plain SQL, and releases the
/// connection back to the pool on terminal transitions. Most callers
/// should use [withTransaction] instead — it wraps the full lifecycle.
///
/// Example:
/// ```dart
/// final uow = PostgresUnitOfWork(pool);
/// await uow.begin();
/// try {
///   await UserRepository(uow.executor).insert(user);
///   await uow.commit();
/// } catch (_) {
///   await uow.rollback();
///   rethrow;
/// } finally {
///   await uow.close();
/// }
/// ```
class PostgresUnitOfWork implements UnitOfWork<PostgresQueryExecutorContract> {
  final PostgresConnectionPool _pool;

  PooledConnection? _leased;
  PostgresQueryExecutor? _executor;
  bool _active = false;

  /// Builds a unit of work over the given pool. The binding is resolved
  /// internally from the pool — consumers no longer need to pass it
  /// explicitly.
  PostgresUnitOfWork(this._pool);

  @override
  bool get isActive => _active;

  @override
  PostgresQueryExecutorContract get executor {
    final e = _executor;
    if (e == null || !_active) {
      throw TransactionStateError(
          'No active transaction; call begin() before executor.');
    }
    return e;
  }

  @override
  Future<void> begin() async {
    if (_active) {
      throw TransactionStateError(
          'Transaction already active; nested begin() is not supported.');
    }
    final leased = await _pool.acquire();
    // The BEGIN is deferred and fused into the first
    // statement of the body (`BEGIN;<sql>` in one round-trip via the
    // Simple Protocol). On the Extended path it rides the same libpq
    // pipeline as the statement (ABI MINOR 5), or goes standalone with an
    // older library. A body
    // that never executes anything still opens+closes the transaction:
    // commit()/rollback()/close() call execute('COMMIT'|'ROLLBACK'),
    // which the executor fuses with the pending BEGIN. This removes one
    // round-trip per transaction versus the previous eager BEGIN.
    _leased = leased;
    _executor =
        PostgresQueryExecutor(_pool.binding, leased.raw, deferredBegin: true);
    _active = true;
  }

  @override
  Future<void> commit() async {
    if (!_active) {
      throw TransactionStateError(
          'No active transaction; commit() without begin().');
    }
    if (_executor!.connectionLost) {
      // Nothing to commit over a dead socket, and pretending otherwise
      // would be the one thing this driver must never do: report a
      // commit it cannot have performed.
      await _releaseConnection();
      throw const ConnectionLostException(sql: 'COMMIT');
    }
    try {
      (await _executor!.execute('COMMIT')).release();
    } finally {
      await _releaseConnection();
    }
  }

  @override
  Future<void> rollback() async {
    if (!_active) {
      throw TransactionStateError(
          'No active transaction; rollback() without begin().');
    }
    if (_executor!.connectionLost) {
      // ABI MINOR 3: skip the wire ROLLBACK. Until 2026-09-11 this line
      // sent `ROLLBACK` over a socket already known to be dead, which
      // could only fail. The server performs the rollback itself when
      // it notices the dropped connection — what the caller needs to
      // know is that nothing was committed, and that is already true.
      await _releaseConnection();
      throw const ConnectionLostException(sql: 'ROLLBACK');
    }
    try {
      (await _executor!.execute('ROLLBACK')).release();
    } finally {
      await _releaseConnection();
    }
  }

  @override
  Future<void> close() async {
    if (!_active) return;
    // `close()` is the best-effort path and must not throw. A lost
    // connection just means there is no ROLLBACK worth attempting;
    // previously this swallowed the resulting exception instead, which
    // worked but paid a round-trip to a dead socket to learn what the
    // executor already knew.
    if (!_executor!.connectionLost) {
      try {
        (await _executor!.execute('ROLLBACK')).release();
      } catch (_) {
        // best-effort
      }
    }
    await _releaseConnection();
  }

  Future<void> _releaseConnection() async {
    final leased = _leased;
    _leased = null;
    _executor = null;
    _active = false;
    if (leased != null) {
      await leased.release();
    }
  }
}
