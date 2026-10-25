/// PostgreSQL connection pool — Dart facade over the native pool.
///
/// ABI MAJOR 2 (2026-05-20): the pool is now a thin wrapper over the
/// C-side `native_pool_t` (`native/c/include/native_pool.h`). The C
/// pool owns the connections, the worker threads, and the libpq I/O
/// loop. The Dart side keeps a gate (`_inUse` counter + waiter queue)
/// so it never invokes the blocking `pool_acquire` — instead it calls
/// `pool_acquire(0)` once it knows a conn is free. That call is a true
/// non-blocking probe only because the native pool is created with a
/// default acquire timeout of 0 (`timeout_ms == 0` means "use the pool
/// default" in `native_pool.c`). This avoids deadlocking the isolate's
/// event loop when the pool is briefly over-subscribed.
///
/// Gate invariant: a unit of `_inUse` always has an owner. `_release`
/// hands the unit straight to the oldest waiter it wakes (the counter is
/// not touched), and every exit of `acquire()` that does not return a
/// connection gives the unit back through `_returnSlot()`.
///
/// Public surface (`PoolConfig`, `PostgresConnectionPool`,
/// `PooledConnection`, `PoolExhaustedException`) is preserved from
/// MAJOR 1 modulo the removal of `PoolConfig.onConnectionOpen`, which
/// no longer maps cleanly onto the C pool's eager-allocation model.
/// Callers that previously ran PREPARE on each fresh conn should now
/// submit those statements through the regular execute path.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:ffi' as ffi;

import 'package:slingshot/slingshot.dart'
    show ConnectionLostException, QueryFailedException;
import 'package:meta/meta.dart';

import '../internal/postgres_shared_binding.dart';
import '../bindings/postgres_binding.dart';
import '../native/postgres_native_pool.dart';
import '../postgres/postgres_query_executor.dart';
import '../postgres/session_reset.dart';

const String _defaultResetQuery = 'DISCARD ALL';

/// Static configuration for [PostgresConnectionPool].
///
/// Bundles the libpq connection string with sizing and timeout knobs.
/// `maxSize` is the effective concurrency ceiling — the native pool
/// eagerly allocates that many connections at startup and never grows
/// beyond it. `acquireTimeout` bounds how long [PostgresConnectionPool.acquire]
/// blocks when every connection is checked out.
///
/// Example:
/// ```dart
/// const config = PoolConfig(
///   connInfo: 'host=localhost port=5432 dbname=app user=app password=secret',
///   maxSize: 16,
///   acquireTimeout: Duration(seconds: 5),
/// );
/// final pool = PostgresConnectionPool(config);
/// ```
class PoolConfig {
  /// libpq connection string passed to `pool_create`.
  /// Example: `'host=localhost port=5432 dbname=teste user=postgres password=123'`.
  ///
  /// TLS goes here too (`sslmode`, `sslrootcert`, `sslcert`, `sslkey`).
  /// Without `sslmode`, libpq uses `prefer`, which never checks the server
  /// certificate; `PostgresConnInfo` builds the string with the mode as an
  /// explicit choice.
  final String connInfo;

  /// Minimum connections to keep warm. Currently informational only
  /// — the native pool eagerly allocates `maxSize` conns at startup
  /// (per `native/c/src/native_pool.c`). Kept on the config surface
  /// for API stability and future warm-up policies.
  final int minSize;

  /// Maximum connections held by the pool. Matches `maxSize` passed
  /// to `pool_create`.
  final int maxSize;

  /// Maximum time `acquire()` waits when every conn is checked out. The
  /// waiting happens in the Dart gate; it is not forwarded to the native
  /// pool, whose default is 0 so the probe never blocks.
  final Duration acquireTimeout;

  /// When true, [PostgresConnectionPool.acquire] times the wait and
  /// records queue depth, so downstream diagnostics
  /// (`pool-diagnostics-instrumentation`) can detect contention. Each
  /// borrow carries its own values ([PooledConnection.acquireWaitUs],
  /// [PooledConnection.queueDepthAtAcquire]), and the pool accumulates
  /// them for [PostgresConnectionPool.takeAcquireStats].
  /// Overhead is ≤2% TPS.
  final bool instrumentationEnabled;

  /// Command sent on a connection when it is returned to the pool, before
  /// the slot is reissued, so that session state set by one borrower does
  /// not reach the next one: `SET` and `set_config(..., false)` values,
  /// `search_path`, `SET ROLE`, temporary tables, `LISTEN`, session advisory
  /// locks. `null` turns the reset off.
  ///
  /// The default, `DISCARD ALL`, also deallocates statements prepared with
  /// SQL `PREPARE`. Code that prepares once per connection and executes on
  /// later borrows must pass `null` and keep its own session hygiene.
  ///
  /// A connection returned inside a transaction is rolled back first. The
  /// reset costs one round-trip per release. If it fails for any other
  /// reason, the slot is still returned and the failure is not raised,
  /// because [PooledConnection.release] runs from `finally` blocks; a broken
  /// reset command therefore stops cleaning the session silently.
  final String? sessionResetQuery;

  /// Defers the session reset from the release to the first statement of
  /// the connection's next borrow, where it rides the same round-trip
  /// (2026-10-10). The reset is the decomposed equivalent of `DISCARD
  /// ALL`, wrapped in `BEGIN … COMMIT` so that a failure of the statement
  /// it travels with does not undo it.
  ///
  /// Requires [sessionResetQuery] to keep its default; any other value
  /// makes [PostgresConnectionPool.start] throw [ArgumentError].
  ///
  /// Behaviour differences from the reset on release:
  /// - session advisory locks and `LISTEN` registrations survive until the
  ///   next borrow instead of ending at release;
  /// - a connection returned inside a transaction is still rolled back at
  ///   release (it would otherwise hold its locks while idle);
  /// - pipelines ([PostgresQueryExecutor.executePipeline]) and, with a
  ///   native library older than ABI MINOR 6, parameterised statements
  ///   still pay the reset as a round-trip of its own, before the
  ///   statement. With such a library the reset also falls back to
  ///   release time.
  final bool deferSessionReset;

  const PoolConfig({
    required this.connInfo,
    this.minSize = 2,
    this.maxSize = 10,
    this.acquireTimeout = const Duration(seconds: 5),
    this.instrumentationEnabled = false,
    this.sessionResetQuery = _defaultResetQuery,
    this.deferSessionReset = false,
  })  : assert(minSize >= 0),
        assert(maxSize >= minSize),
        assert(maxSize > 0);
}

/// Thrown when [PostgresConnectionPool.acquire] cannot obtain a
/// connection within [PoolConfig.acquireTimeout].
///
/// Indicates sustained over-subscription: every connection is in use
/// and no waiter slot opened up in time. The pool stays usable —
/// callers can retry, back off, or raise `maxSize`.
class PoolExhaustedException implements Exception {
  final Duration timeout;
  PoolExhaustedException(this.timeout);

  @override
  String toString() =>
      'PoolExhaustedException: no connection available within $timeout';
}

/// Contention seen by [PostgresConnectionPool.acquire] since the previous
/// [PostgresConnectionPool.takeAcquireStats] call.
///
/// Counted per pool, and a pool lives in one isolate, so these are per
/// isolate: summing across isolates is up to the caller. All zero when
/// [PoolConfig.instrumentationEnabled] is false.
class PoolAcquireStats {
  /// Connections handed out by `acquire()`.
  final int acquires;

  /// Sum of the time each of the [acquires] waited, in microseconds.
  final int waitTotalUs;

  /// Longest of those waits, in microseconds.
  final int waitMaxUs;

  /// Largest waiter queue found on arrival by an `acquire()` that got a
  /// connection (0 on the fast path).
  final int queueDepthMax;

  /// `acquire()` calls that threw [PoolExhaustedException]. They waited
  /// [PoolConfig.acquireTimeout]; they are not part of [acquires],
  /// [waitTotalUs], [waitMaxUs] or [queueDepthMax].
  final int timeouts;

  const PoolAcquireStats({
    this.acquires = 0,
    this.waitTotalUs = 0,
    this.waitMaxUs = 0,
    this.queueDepthMax = 0,
    this.timeouts = 0,
  });

  /// Mean wait in microseconds, or 0 when nothing was acquired.
  double get waitMeanUs => acquires == 0 ? 0 : waitTotalUs / acquires;

  @override
  String toString() => 'PoolAcquireStats(acquires: $acquires, '
      'waitTotalUs: $waitTotalUs, waitMaxUs: $waitMaxUs, '
      'queueDepthMax: $queueDepthMax, timeouts: $timeouts)';
}

/// A borrowed connection from a [PostgresConnectionPool].
///
/// Returned by [PostgresConnectionPool.acquire] and must be returned
/// via [release] — preferably from a `try`/`finally` to avoid leaking
/// a slot. Holding past `release()` is undefined behaviour: the slot
/// goes back to the pool and may be reissued to another caller.
///
/// Example:
/// ```dart
/// final leased = await pool.acquire();
/// try {
///   // use leased.raw via the binding
/// } finally {
///   await leased.release();
/// }
/// ```
class PooledConnection {
  /// Underlying native handle. In ABI MAJOR 2 this is a
  /// `native_conn_t*`, not a raw `PGconn*` — pass to
  /// `PostgresBinding.poolSubmitQuery` / `.pollResult` /
  /// `.poolCancel`. The Dart-side type stays `Pointer<Void>` so the
  /// existing test surface keeps compiling.
  final ffi.Pointer<ffi.Void> raw;

  /// Time waited in [PostgresConnectionPool.acquire] before this
  /// connection was obtained, in microseconds. Null when
  /// [PoolConfig.instrumentationEnabled] is false.
  final int? acquireWaitUs;

  /// Length of the waiter queue at the moment `acquire()` was called.
  /// Null when [PoolConfig.instrumentationEnabled] is false; 0 on the
  /// fast path.
  final int? queueDepthAtAcquire;

  final PostgresConnectionPool _pool;
  bool _released = false;

  PooledConnection._(
    this.raw,
    this._pool, {
    this.acquireWaitUs,
    this.queueDepthAtAcquire,
  });

  /// Returns the connection to the pool. Idempotent.
  /// Returns the connection to the pool, after resetting its session with
  /// [PoolConfig.sessionResetQuery]. Idempotent, and never throws.
  Future<void> release() async {
    if (_released) return;
    _released = true;
    try {
      await _pool._resetSession(raw);
    } finally {
      _pool._release(raw);
    }
  }

  bool get isReleased => _released;
}

/// Pool of native conns served by a single C-side `native_pool_t`.
///
/// Lifecycle: construct → `start()` → use `acquire()` / `release()` →
/// `close()`.
///
/// Usage (recommended):
/// ```dart
/// final pool = PostgresConnectionPool(PoolConfig(connInfo: '...'));
/// await pool.start();
/// final c = await pool.acquire();
/// try {
///   // ... use c ...
/// } finally {
///   await c.release();
/// }
/// await pool.close();
/// ```
///
/// The FFI binding is resolved automatically via a per-isolate
/// `SharedBinding` singleton — consumers never need to call
/// `loadNativeDb()` or instantiate `PostgresBinding` themselves.
class PostgresConnectionPool {
  final PoolConfig config;
  final PostgresBinding _binding;

  NativePool? _nativePool;
  int _inUse = 0;

  /// Pending acquires waiting for a release. Drained FIFO so a
  /// long-blocked caller eventually wins.
  final Queue<Completer<void>> _waiters = Queue();

  bool _closed = false;

  /// Completes once `pool_destroy` has run (set by [close]).
  Completer<void>? _drained;

  // Read and cleared by takeAcquireStats(); only touched when
  // config.instrumentationEnabled is true.
  int _statAcquires = 0;
  int _statWaitTotalUs = 0;
  int _statWaitMaxUs = 0;
  int _statQueueDepthMax = 0;
  int _statTimeouts = 0;

  /// Default constructor — resolves the FFI binding internally from
  /// the per-isolate `SharedBinding` singleton. This is the only
  /// constructor consumers of the public API should use.
  PostgresConnectionPool(this.config) : _binding = SharedBinding.instance();

  /// Internal constructor that accepts an explicit [PostgresBinding].
  /// Used by tests, benchmark harnesses, and the in-isolate worker of
  /// the (deprecated) `IsolateWorkerPool`. Not part of the public API.
  @internal
  PostgresConnectionPool.withBinding(this._binding, this.config);

  /// Underlying [PostgresBinding] — internal accessor for code paths
  /// that need direct FFI access (e.g. `PostgresQueryExecutor`,
  /// `withTransaction`). Not part of the public API.
  @internal
  PostgresBinding get binding => _binding;

  /// Total connections currently managed by the C pool. Constant
  /// (`config.maxSize`) once [start] has run.
  int get currentSize => _nativePool == null ? 0 : config.maxSize;

  /// Connections currently checked out by consumers.
  int get borrowed => _inUse;

  /// Connections currently idle in the C pool (eligible for
  /// `pool_acquire(0)`).
  int get idle => _nativePool == null ? 0 : config.maxSize - _inUse;

  /// Pending `acquire()` calls waiting on a free connection.
  int get pending => _waiters.length;

  bool get isClosed => _closed;

  /// Returns the contention [acquire] saw since the previous call and resets
  /// it. Reading and resetting are one synchronous step, so no `acquire()`
  /// falls between them. Also works after [close], for a last read.
  ///
  /// All zero unless [PoolConfig.instrumentationEnabled] is true.
  PoolAcquireStats takeAcquireStats() {
    final stats = PoolAcquireStats(
      acquires: _statAcquires,
      waitTotalUs: _statWaitTotalUs,
      waitMaxUs: _statWaitMaxUs,
      queueDepthMax: _statQueueDepthMax,
      timeouts: _statTimeouts,
    );
    _statAcquires = 0;
    _statWaitTotalUs = 0;
    _statWaitMaxUs = 0;
    _statQueueDepthMax = 0;
    _statTimeouts = 0;
    return stats;
  }

  /// Underlying native pool. Exposed for tests and the FFI test
  /// harness; do not retain across [close].
  NativePool? get nativePool => _nativePool;

  /// Spawns the native pool (`pool_create`) with all `maxSize` conns
  /// + worker threads. Idempotent.
  Future<void> start() async {
    if (_closed) throw StateError('Pool is closed');
    if (_nativePool != null) return;
    if (config.deferSessionReset &&
        config.sessionResetQuery != _defaultResetQuery) {
      throw ArgumentError.value(
          config.sessionResetQuery,
          'sessionResetQuery',
          'deferSessionReset uses the built-in DISCARD ALL equivalent; '
              'a custom reset query cannot be deferred');
    }
    _nativePool = NativePool.create(
      binding: _binding,
      conninfo: config.connInfo,
      minSize: config.minSize,
      maxSize: config.maxSize,
      // The Dart gate does all the waiting; a zero default makes
      // `pool_acquire(0)` a true non-blocking probe (`native_pool.h`).
      acquireTimeout: Duration.zero,
    );
  }

  /// Acquires a connection. Gates Dart-side to keep `_inUse <=
  /// maxSize`, so the native `pool_acquire(0)` probe always succeeds
  /// immediately. Throws [PoolExhaustedException] on timeout and
  /// [StateError] if the pool is closed.
  Future<PooledConnection> acquire() async {
    if (_closed) throw StateError('Pool is closed');
    final pool = _nativePool;
    if (pool == null) {
      throw StateError('Pool not started — call start() first');
    }

    final instrumented = config.instrumentationEnabled;
    final stopwatch = instrumented ? (Stopwatch()..start()) : null;
    final initialDepth = instrumented ? _waiters.length : null;

    if (_inUse < config.maxSize) {
      _inUse++; // fast path: take one unit now
    } else {
      final completer = Completer<void>();
      _waiters.add(completer);
      final timer = Timer(config.acquireTimeout, () {
        if (!completer.isCompleted) {
          _waiters.remove(completer);
          if (instrumented) _statTimeouts++;
          completer
              .completeError(PoolExhaustedException(config.acquireTimeout));
        }
      });
      try {
        // On success `_release` handed this call its unit of `_inUse`.
        await completer.future;
      } finally {
        timer.cancel();
      }
    }

    // From here this call owns one unit of `_inUse`. Every exit that does
    // not hand out a PooledConnection must give it back via `_returnSlot()`.
    if (_closed) {
      _returnSlot();
      throw StateError('Pool is closed');
    }
    final ffi.Pointer<ffi.Void> conn;
    try {
      conn = pool.acquire(timeout: Duration.zero).ptr;
    } on Object catch (e) {
      _returnSlot();
      throw StateError('PostgresConnectionPool: native probe failed although '
          'the Dart gate had a free unit (borrowed=$_inUse, '
          'maxSize=${config.maxSize}): $e');
    }
    stopwatch?.stop();
    if (instrumented) {
      final waitUs = stopwatch!.elapsedMicroseconds;
      _statAcquires++;
      _statWaitTotalUs += waitUs;
      if (waitUs > _statWaitMaxUs) _statWaitMaxUs = waitUs;
      if (initialDepth! > _statQueueDepthMax) _statQueueDepthMax = initialDepth;
    }
    return PooledConnection._(
      conn,
      this,
      acquireWaitUs: stopwatch?.elapsedMicroseconds,
      queueDepthAtAcquire: initialDepth,
    );
  }

  // Runs the session reset on a connection that is still checked out, so
  // the worker that owns it executes the command. Failures never escape:
  // a QueryFailedException is first taken as "returned inside a
  // transaction" (DISCARD ALL refuses to run there; the PG path exposes no
  // SQLSTATE to tell it apart), so it rolls back and retries once. A lost
  // connection is skipped, since the worker's reconnect opens a new session.
  Future<void> _resetSession(ffi.Pointer<ffi.Void> conn) async {
    final query = config.sessionResetQuery;
    if (query == null || _nativePool == null || _closed) return;
    final txStatus = _binding.poolConnTransactionStatus;
    if (config.deferSessionReset && txStatus != null) {
      return _deferReset(conn, txStatus(conn));
    }
    final exec =
        PostgresQueryExecutor(_binding, conn, applyDeferredReset: false);
    Future<void> run(String sql) async => (await exec.execute(sql)).release();
    try {
      await run(query);
    } on QueryFailedException {
      try {
        await run('ROLLBACK');
        await run(query);
      } on Object {
        // Best effort: the slot goes back either way.
      }
    } on ConnectionLostException {
      // The worker re-establishes the session on the next use.
    } on Object {
      // Best effort: the slot goes back either way.
    }
  }

  // Deferred mode: a connection left inside a transaction is rolled back
  // now — the reset that would end it only runs on the next borrow, and
  // an idle open transaction holds its locks. Then the connection is
  // marked; its next first statement carries the reset.
  Future<void> _deferReset(ffi.Pointer<ffi.Void> conn, int txStatus) async {
    if (txStatus == PgTransactionStatus.inTransaction ||
        txStatus == PgTransactionStatus.inError) {
      try {
        final exec =
            PostgresQueryExecutor(_binding, conn, applyDeferredReset: false);
        (await exec.execute('ROLLBACK')).release();
      } on Object {
        // Best effort, as the reset on release: a lost link opens a new
        // session anyway, and the mark below still resets the next borrow.
      }
    }
    DeferredSessionReset.mark(conn);
    _deferredMarked.add(conn);
  }

  // Connections this pool marked, unmarked when the native pool goes
  // away so a later pool reusing the address starts clean.
  final Set<ffi.Pointer<ffi.Void>> _deferredMarked = {};

  void _release(ffi.Pointer<ffi.Void> conn) {
    final pool = _nativePool;
    if (pool != null) {
      _binding.poolRelease(pool.ptr, conn);
    }
    if (!_closed && _waiters.isNotEmpty) {
      // Hand the unit straight to the oldest waiter: `_inUse` stays put, so
      // a newcomer that runs before the waiter resumes still sees the pool
      // full instead of taking the slot the waiter is about to probe.
      _waiters.removeFirst().complete();
      return;
    }
    _returnSlot();
  }

  /// Gives one unit of `_inUse` back. When the pool is closed and this was
  /// the last borrowed unit, it is also what finally destroys the native pool.
  void _returnSlot() {
    _inUse--;
    if (_closed && _inUse == 0) _destroyNative();
  }

  void _destroyNative() {
    for (final conn in _deferredMarked) {
      DeferredSessionReset.take(conn);
    }
    _deferredMarked.clear();
    _nativePool?.destroy();
    _nativePool = null;
    final drained = _drained;
    if (drained != null && !drained.isCompleted) drained.complete();
  }

  /// Closes the pool. New `acquire()` calls and pending waiters fail with
  /// [StateError].
  ///
  /// `pool_destroy` runs as soon as every borrowed connection has been
  /// released, never before: a native connection still held by a caller
  /// must not dangle. Completes once the native pool is gone. If a borrow
  /// is still outstanding after [timeout], throws [TimeoutException] and
  /// leaves the destroy armed for that borrow's release. Idempotent.
  Future<void> close({Duration timeout = const Duration(seconds: 5)}) async {
    if (!_closed) {
      _closed = true;
      while (_waiters.isNotEmpty) {
        _waiters.removeFirst().completeError(StateError('Pool is closed'));
      }
      _drained = Completer<void>();
      if (_inUse == 0) _destroyNative();
    }
    final drained = _drained!;
    if (drained.isCompleted) return;
    await drained.future.timeout(
      timeout,
      onTimeout: () => throw TimeoutException(
        'PostgresConnectionPool.close: $_inUse connection(s) still borrowed '
        'after $timeout; pool_destroy is deferred until they are released',
        timeout,
      ),
    );
  }
}
