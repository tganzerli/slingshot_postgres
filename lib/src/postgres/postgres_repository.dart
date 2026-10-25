/// Generic Postgres [Repository] base.
///
/// Two parallel CRUD-template families:
///
/// **String-only path (default, fast path)** (required overrides). Returns a plain
/// `String`. Values are inlined into SQL via standard interpolation.
///   * `selectAllSql()`, `selectByIdSql(K id)`, `insertSql(T entity)`,
///     `updateSql(T entity)`, `deleteSql(K id)`.
///
/// **Parameter path — Extended Query Protocol** (optional overrides; default
/// returns `null`). Returns a [SqlStmt] tuple `(sql, params)` with `$1`,
/// `$2`, … placeholders bound separately from the SQL text. When a
/// `*SqlParams` method returns non-null, **it takes precedence** over
/// its string-only sibling — and SQL injection through bound parameters
/// becomes structurally impossible (libpq sends values as separate
/// wire-format fields, never substituted into the SQL string).
///   * `selectAllSqlParams()`, `selectByIdSqlParams(K id)`,
///     `insertSqlParams(T entity)`, `updateSqlParams(T entity)`,
///     `deleteSqlParams(K id)`.
///
/// **When to use the parameter path:** any value that originates outside the
/// program (user form input, HTTP query string, third-party API). For
/// values the program itself synthesises (auto-generated UUIDs,
/// computed totals, internal IDs), the string path is safe and faster.
///
/// The parameter path is not a throughput gain over the string path; its
/// win is security and ergonomics for parameter binding.
library;

import 'package:slingshot_core/slingshot_core.dart';
import '../decoder/postgres_result_row.dart';
import 'param.dart';
import 'postgres_query_executor.dart';

/// Base class for Postgres-backed [Repository]s.
///
/// Concrete subclasses override the string methods. They MAY
/// override the matching `*SqlParams` method to opt into Extended
/// Query Protocol per-operation (mix and match — e.g. `findById`
/// param-bound because the id comes from an HTTP path, while
/// `findAll` stays string-only because it has no inputs).
///
/// Example (string path only — values are internal, no external input):
/// ```dart
/// class CounterRepository extends PostgresRepository<Counter, int> {
///   CounterRepository(PostgresQueryExecutorContract exec) : super(exec, _fromRow);
///   @override String get tableName => 'counter';
///   @override String get idColumn => 'id';
///   @override
///   String selectByIdSql(int id) =>
///     'SELECT id, value FROM counter WHERE id = $id';
///   // ... other string overrides
/// }
/// ```
///
/// Example (mix: parameter path for id-by-input, string path elsewhere):
/// ```dart
/// class UserRepository extends PostgresRepository<User, int> {
///   UserRepository(PostgresQueryExecutorContract exec) : super(exec, _fromRow);
///   @override String get tableName => 'users';
///   @override String get idColumn => 'id';
///
///   // id comes from an HTTP path → bind as param (untrusted).
///   @override
///   SqlStmt selectByIdSqlParams(int id) => (
///     'SELECT id, name FROM users WHERE id = \$1',
///     [Param.int4(id)],
///   );
///
///   // The string method is still required as fallback — base class falls through
///   // to it if `*SqlParams` returns null. Provide a sensible no-op.
///   @override
///   String selectByIdSql(int id) =>
///     throw StateError('use selectByIdSqlParams');
///
///   // No external input → the string path is fine.
///   @override
///   String selectAllSql() => 'SELECT id, name FROM users';
/// }
/// ```
abstract class PostgresRepository<T, K> implements Repository<T, K> {
  final PostgresQueryExecutorContract _exec;
  final T Function(PostgresResultRow) _fromRow;

  PostgresRepository(this._exec, this._fromRow);

  /// Table the repository targets. Used for diagnostics; SQL is provided
  /// by the concrete overrides below.
  String get tableName;

  /// Primary-key column. Used for diagnostics; concrete SQL still must
  /// reference the column explicitly.
  String get idColumn;

  // ── String-only (required) ──

  String selectAllSql();
  String selectByIdSql(K id);
  String insertSql(T entity);
  String updateSql(T entity);
  String deleteSql(K id);

  // ── Extended Query Protocol (optional opt-in) ──

  /// Override to use Extended Query Protocol for `findAll`. When
  /// non-null, takes precedence over [selectAllSql].
  SqlStmt? selectAllSqlParams() => null;

  /// Override to use Extended Query Protocol for `findById`. Recommended
  /// when [id] originates outside the program (user input, HTTP path,
  /// etc.). When non-null, takes precedence over [selectByIdSql].
  SqlStmt? selectByIdSqlParams(K id) => null;

  /// Override to use Extended Query Protocol for `insert`. Recommended
  /// when any field of [entity] originates outside the program. When
  /// non-null, takes precedence over [insertSql].
  SqlStmt? insertSqlParams(T entity) => null;

  /// Override to use Extended Query Protocol for `update`. Recommended
  /// when any field of [entity] originates outside the program. When
  /// non-null, takes precedence over [updateSql].
  SqlStmt? updateSqlParams(T entity) => null;

  /// Override to use Extended Query Protocol for `delete`. Recommended
  /// when [id] originates outside the program. When non-null, takes
  /// precedence over [deleteSql].
  SqlStmt? deleteSqlParams(K id) => null;

  // ── CRUD impl ──

  Future<PostgresResultSet> _run(SqlStmt? params, String Function() fallback) {
    if (params != null) {
      return _exec.execute(params.$1, params: params.$2);
    }
    return _exec.execute(fallback());
  }

  @override
  Future<List<T>> findAll() async {
    final rs = await _run(selectAllSqlParams(), selectAllSql);
    return [for (final row in rs.rows) _fromRow(row)];
  }

  @override
  Future<T?> findById(K id) async {
    final rs = await _run(selectByIdSqlParams(id), () => selectByIdSql(id));
    if (rs.rowCount == 0) return null;
    return _fromRow(rs.row(0));
  }

  @override
  Future<void> insert(T entity) async {
    await _run(insertSqlParams(entity), () => insertSql(entity));
  }

  @override
  Future<void> update(T entity) async {
    await _run(updateSqlParams(entity), () => updateSql(entity));
  }

  @override
  Future<void> delete(K id) async {
    await _run(deleteSqlParams(id), () => deleteSql(id));
  }
}
