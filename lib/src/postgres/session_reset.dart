import 'dart:ffi' as ffi;

import 'package:meta/meta.dart';

/// Deferred pool session reset (2026-10-10).
///
/// With `PoolConfig.deferSessionReset`, a released connection is only
/// marked here; the reset rides the first statement of the next
/// acquisition, so it costs no round-trip of its own. The executor looks
/// the connection up on its first dispatch and, if marked, prefixes
/// [prefix] to it.
///
/// The registry is per isolate, like the pools that fill it, and keyed by
/// the native connection address. Pools unmark their connections on close.
@internal
abstract final class DeferredSessionReset {
  /// `DISCARD ALL`, decomposed: `DISCARD ALL` refuses to run inside a
  /// transaction block or next to another statement (SQLSTATE 25001), so
  /// it cannot be fused. These are the statements the PostgreSQL docs
  /// list as its equivalent; each one is a single statement, so the list
  /// also fits the Extended path as N pipeline prefixes.
  static const List<String> statements = [
    'SET SESSION AUTHORIZATION DEFAULT',
    'RESET ALL',
    'DEALLOCATE ALL',
    'CLOSE ALL',
    'UNLISTEN *',
    'SELECT pg_advisory_unlock_all()',
    'DISCARD PLANS',
    'DISCARD SEQUENCES',
    'DISCARD TEMP',
  ];

  /// [statements] without what would drop statements prepared on the
  /// connection: `DEALLOCATE ALL` deallocates them and `DISCARD PLANS`
  /// throws their cached plans away (`PoolConfig.preservePreparedStatements`).
  /// Statements prepared with SQL `PREPARE` survive too.
  static const List<String> statementsPreservingPrepared = [
    'SET SESSION AUTHORIZATION DEFAULT',
    'RESET ALL',
    'CLOSE ALL',
    'UNLISTEN *',
    'SELECT pg_advisory_unlock_all()',
    'DISCARD SEQUENCES',
    'DISCARD TEMP',
  ];

  /// [statements] inside an explicit `BEGIN … COMMIT`.
  ///
  /// Without the explicit block the reset shares the implicit
  /// transaction of the statement it is fused into, and a failure of that
  /// statement undoes part of it: `RESET ALL`, `SET SESSION
  /// AUTHORIZATION`, `UNLISTEN` and `DISCARD TEMP` roll back, while
  /// `DEALLOCATE ALL`, `CLOSE ALL`, the advisory unlock and `DISCARD
  /// SEQUENCES` do not. A bare `COMMIT` after the statements would also
  /// work but logs "there is no transaction in progress" on every
  /// acquisition. Verified on PostgreSQL 16.15.
  static List<String> get prefix => full.prefix;

  /// The reset that also deallocates prepared statements: the decomposed
  /// `DISCARD ALL`, and `DISCARD ALL` itself when it runs on its own.
  static const ResetStatements full = ResetStatements._(_prefix, standalone);

  /// The reset that keeps prepared statements. It has no single-statement
  /// form, so on its own it runs as one simple-protocol string.
  static const ResetStatements preservingPrepared = ResetStatements._(
      _prefixPreservingPrepared, _standalonePreservingPrepared);

  static const List<String> _prefix = ['BEGIN', ...statements, 'COMMIT'];

  static const List<String> _prefixPreservingPrepared = [
    'BEGIN',
    ...statementsPreservingPrepared,
    'COMMIT',
  ];

  static const String _standalonePreservingPrepared =
      'BEGIN; SET SESSION AUTHORIZATION DEFAULT; RESET ALL; CLOSE ALL; '
      'UNLISTEN *; SELECT pg_advisory_unlock_all(); DISCARD SEQUENCES; '
      'DISCARD TEMP; COMMIT';

  /// Makes the prefix fail mid-way, whichever reset it carries. Tests only.
  @visibleForTesting
  static bool debugFailingPrefix = false;

  /// Makes the standalone form of the reset that keeps prepared
  /// statements fail mid-way, inside its `BEGIN`. Tests only: the full
  /// reset's standalone `DISCARD ALL` opens no transaction to recover.
  @visibleForTesting
  static bool debugFailingStandalone = false;

  /// Standalone reset, for the paths that cannot carry a prefix
  /// (pipeline, an Extended statement with a library older than ABI
  /// MINOR 6) and to recover after a failed fused reset.
  static const String standalone = 'DISCARD ALL';

  /// Pending connections, by native address: whether the reset keeps
  /// prepared statements.
  static final Map<int, bool> _pending = <int, bool>{};

  /// Marks [conn] so its next first dispatch carries the reset; with
  /// [preservePrepared], the one that keeps prepared statements.
  static void mark(ffi.Pointer<ffi.Void> conn,
          {bool preservePrepared = false}) =>
      _pending[conn.address] = preservePrepared;

  /// Removes the mark of [conn], returning the reset it was marked with,
  /// or null when it was not marked.
  static ResetStatements? take(ffi.Pointer<ffi.Void> conn) {
    if (_pending.isEmpty) return null;
    final preserve = _pending.remove(conn.address);
    if (preserve == null) return null;
    return preserve ? preservingPrepared : full;
  }

  /// Whether [conn] is marked. Tests only.
  @visibleForTesting
  static bool isPending(ffi.Pointer<ffi.Void> conn) =>
      _pending.containsKey(conn.address);
}

/// One flavour of the session reset: the statements fused as a prefix of
/// the next statement, and the string that runs it on its own.
@internal
final class ResetStatements {
  final List<String> _prefixStatements;

  final String _standalone;

  const ResetStatements._(this._prefixStatements, this._standalone);

  /// Runs the reset in a round-trip of its own. The one that keeps
  /// prepared statements is a `BEGIN … COMMIT` string: a failure inside
  /// it leaves the session in an aborted transaction, which the caller
  /// must roll back.
  String get standalone => DeferredSessionReset.debugFailingStandalone &&
          identical(this, DeferredSessionReset.preservingPrepared)
      ? 'BEGIN; RESET ALL; SELECT 1/0; DISCARD TEMP; COMMIT'
      : _standalone;

  /// The reset as N single statements inside `BEGIN … COMMIT`, ready to
  /// be fused before another statement. Same length with
  /// [DeferredSessionReset.debugFailingPrefix], with a statement in the
  /// middle that always fails, so tests can drive the recovery path.
  List<String> get prefix {
    if (!DeferredSessionReset.debugFailingPrefix) return _prefixStatements;
    final failing = List<String>.of(_prefixStatements);
    // Past `BEGIN`, halfway through the statements before `COMMIT`.
    failing[(_prefixStatements.length - 2) ~/ 2] = 'SELECT 1/0';
    return failing;
  }
}
