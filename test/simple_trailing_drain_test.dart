/// A multi-statement string sent through the Simple Query Protocol must not
/// block the isolate while the server produces the results after the first.
///
/// The worker used to notify as soon as the first result was complete
/// (`!PQisBusy`); when a later statement's output overflowed the server's
/// send buffer, that first result arrived early and the Dart side waited for
/// the rest inside a blocking `PQgetResult`, on the isolate's own thread and
/// outside the query timeout. The worker now drains every result before it
/// notifies, so the wait happens off the isolate and under the deadline.
library;

import 'dart:async';
import 'dart:ffi' as ffi;

import 'package:slingshot/slingshot.dart' show ConnectionLostException;
import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:slingshot_postgres/src/bindings/postgres_binding.dart';
import 'package:slingshot_postgres/src/native/postgres_lib_loader.dart';
import 'package:slingshot_postgres/src/postgres/postgres_query_executor.dart';
import 'package:test/test.dart';

const _connInfo =
    'host=localhost port=5432 dbname=teste user=postgres password=123';

/// A short head result, then a statement whose output (64 KB) overflows the
/// server's send buffer, so the head reaches the client before the rest.
const _headThenBig = "SELECT 1 AS head; SELECT repeat('x', 64000)";

bool _canLoadNative() {
  try {
    loadNativeDb();
    return true;
  } on StateError {
    return false;
  }
}

PostgresBinding _binding() {
  final b = PostgresBinding(loadNativeDb());
  b.initDartApi(ffi.NativeApi.initializeApiDLData);
  return b;
}

/// Runs [body] while a 10 ms periodic timer records the largest gap between
/// ticks — how long the event loop stood still.
Future<Duration> _maxEventLoopGap(Future<void> Function() body) async {
  final sw = Stopwatch()..start();
  var last = Duration.zero;
  var maxGap = Duration.zero;
  final timer = Timer.periodic(const Duration(milliseconds: 10), (_) {
    final now = sw.elapsed;
    final gap = now - last;
    if (gap > maxGap) maxGap = gap;
    last = now;
  });
  try {
    await body();
  } finally {
    timer.cancel();
  }
  final tail = sw.elapsed - last;
  return tail > maxGap ? tail : maxGap;
}

/// Whether backend [pid] has left `pg_stat_activity`, polled from a pool of
/// its own for up to ~2 s: the server reaps a backend asynchronously after
/// its socket closes.
Future<bool> _backendGone(PostgresBinding b, int pid) async {
  final observer = PostgresConnectionPool.withBinding(
    b,
    const PoolConfig(connInfo: _connInfo, minSize: 1, maxSize: 1),
  );
  await observer.start();
  try {
    for (var i = 0; i < 20; i++) {
      final leased = await observer.acquire();
      try {
        final rs = await PostgresQueryExecutor(b, leased.raw).execute(
            'SELECT count(*)::int4 AS n FROM pg_stat_activity WHERE pid = $pid');
        final n = rs.row(0).getInt('n');
        rs.release();
        if (n == 0) return true;
      } finally {
        await leased.release();
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return false;
  } finally {
    await observer.close();
  }
}

void main() {
  if (!_canLoadNative()) {
    test('skipped (native library not built)', () {
      markTestSkipped('libnative_db not available');
    });
    return;
  }

  final b = _binding();
  late PostgresConnectionPool pool;
  var reachable = true;

  setUp(() async {
    pool = PostgresConnectionPool.withBinding(
      b,
      const PoolConfig(connInfo: _connInfo, minSize: 1, maxSize: 1),
    );
    try {
      await pool.start();
    } catch (_) {
      reachable = false;
    }
  });

  tearDown(() async {
    if (reachable) await pool.close();
  });

  test('the event loop keeps running while trailing results are produced',
      () async {
    if (!reachable) return markTestSkipped('Postgres not reachable');
    final leased = await pool.acquire();
    try {
      final exec = PostgresQueryExecutor(b, leased.raw);
      int? head;
      final gap = await _maxEventLoopGap(() async {
        final rs = await exec.execute('$_headThenBig; SELECT pg_sleep(0.5)');
        head = rs.row(0).getInt('head');
        rs.release();
      });
      expect(head, 1, reason: 'execute returns the head result');
      expect(gap, lessThan(const Duration(milliseconds: 150)),
          reason: 'the isolate must not wait for pg_sleep (gap was $gap)');
    } finally {
      await leased.release();
    }
  });

  test('the query timeout covers the trailing results', () async {
    if (!reachable) return markTestSkipped('Postgres not reachable');
    final leased = await pool.acquire();
    try {
      final exec = PostgresQueryExecutor(b, leased.raw,
          timeout: const Duration(milliseconds: 300));
      final sw = Stopwatch()..start();
      await expectLater(
        exec.execute('$_headThenBig; SELECT pg_sleep(5)'),
        throwsA(isA<QueryTimeoutException>()),
      );
      expect(sw.elapsed, lessThan(const Duration(milliseconds: 1500)),
          reason: 'the timeout must fire long before the 5 s sleep');
    } finally {
      await leased.release();
    }
  });

  test('an error after a large discarded result still surfaces', () async {
    if (!reachable) return markTestSkipped('Postgres not reachable');
    final leased = await pool.acquire();
    try {
      final exec = PostgresQueryExecutor(b, leased.raw);
      await expectLater(
        exec.execute('$_headThenBig; SELECT * FROM trailing_drain_missing'),
        throwsA(isA<QueryFailedException>().having((e) => e.toString(),
            'message', contains('trailing_drain_missing'))),
      );
      final rs = await exec.execute('SELECT 2 AS n');
      expect(rs.row(0).getInt('n'), 2,
          reason: 'the connection is clean for the next dispatch');
      rs.release();
    } finally {
      await leased.release();
    }
  });

  // COPY is unsupported here. In a COPY state libpq returns a new
  // PGRES_COPY_* result on every PQgetResult and never NULL; draining on
  // the worker would spin forever, past the deadline, holding the slot.
  // The worker reconnects at once and reports the session as lost, so the
  // old backend is not left in COPY holding its locks. "At once" is checked
  // from a second pool while the slot is still leased: with a reset
  // deferred to the slot's next query, the old backend would still be
  // alive there.
  final copies = {
    'TO STDOUT': 'COPY (SELECT 1) TO STDOUT',
    'FROM STDIN': 'COPY trailing_drain_copy FROM STDIN',
  };
  for (final copy in copies.entries) {
    for (final multiRead in [false, true]) {
      for (final withTimeout in [false, true]) {
        test(
            'COPY ${copy.key} resets the slot at once '
            '(multiRead: $multiRead, timeout: $withTimeout)', () async {
          if (!reachable) return markTestSkipped('Postgres not reachable');
          final leased = await pool.acquire();
          late int oldPid;
          try {
            var exec = PostgresQueryExecutor(b, leased.raw);
            (await exec.execute('CREATE TABLE IF NOT EXISTS '
                    'trailing_drain_copy (n int)'))
                .release();
            final pidRs = await exec.execute('SELECT pg_backend_pid() AS p');
            oldPid = pidRs.row(0).getInt('p')!;
            pidRs.release();
            exec = PostgresQueryExecutor(b, leased.raw,
                timeout: withTimeout ? const Duration(seconds: 2) : null);
            await expectLater(
              multiRead
                  ? exec.executeMultiRead([copy.value])
                  : exec.execute(copy.value),
              throwsA(isA<ConnectionLostException>()),
            );
            // Slot still leased: nothing has run on it since the failure.
            expect(await _backendGone(b, oldPid), isTrue,
                reason: 'the old backend must be gone before the slot is '
                    'used again, not left in COPY');
          } finally {
            await leased.release();
          }
          final again = await pool.acquire();
          try {
            final rs = await PostgresQueryExecutor(b, again.raw)
                .execute('SELECT pg_backend_pid() AS p');
            expect(rs.row(0).getInt('p'), isNot(oldPid),
                reason: 'the slot runs on a new backend');
            rs.release();
          } finally {
            await again.release();
          }
        }, timeout: const Timeout(Duration(seconds: 20)));
      }
    }
  }

  tearDownAll(() async {
    final p = PostgresConnectionPool.withBinding(
      b,
      const PoolConfig(connInfo: _connInfo, minSize: 1, maxSize: 1),
    );
    try {
      await p.start();
    } catch (_) {
      return;
    }
    final leased = await p.acquire();
    try {
      (await PostgresQueryExecutor(b, leased.raw)
              .execute('DROP TABLE IF EXISTS trailing_drain_copy'))
          .release();
    } finally {
      await leased.release();
      await p.close();
    }
  });
}
