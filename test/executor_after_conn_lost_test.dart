/// An executor that has raised [ConnectionLostException] must refuse every
/// later dispatch.
///
/// The native worker reconnects the slot while classifying the failure, and
/// the slot stays leased (`connection_reconnect_test.dart`, "Same slot, no
/// release/acquire in between"). Without the guard, the next statement on
/// the same executor reaches the fresh session in autocommit: a write made
/// "inside" a unit of work is committed at once, and the later `commit()`
/// still reports that nothing was committed.
///
/// Requires Docker Postgres (`docker/postgres/`); skipped otherwise.
library;

import 'dart:ffi' as ffi;

import 'package:slingshot/slingshot.dart';
import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:slingshot_postgres/src/bindings/postgres_binding.dart';
import 'package:slingshot_postgres/src/native/postgres_lib_loader.dart';
import 'package:slingshot_postgres/src/postgres/postgres_query_executor.dart';
import 'package:test/test.dart';

const _connInfo =
    'host=localhost port=5432 dbname=teste user=postgres password=123';

const _kill = 'SELECT pg_terminate_backend(pg_backend_pid())';

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

Future<int> _probeCount(PostgresConnectionPool pool) {
  return withPostgresConnection(pool, (e) async {
    final rs =
        await e.execute('SELECT count(*)::int4 AS n FROM conn_lost_probe');
    try {
      return rs.rows.first.getInt('n')!;
    } finally {
      rs.release();
    }
  });
}

/// Kills the backend behind [e]. The head of the kill statement is the
/// server's own FATAL, so the loss is reported on the kill itself.
Future<void> _killBackend(PostgresQueryExecutorContract e) async {
  await expectLater(e.execute(_kill), throwsA(isA<ConnectionLostException>()));
}

void main() {
  if (!_canLoadNative()) {
    test('skipped (native library not built)', () {
      markTestSkipped('libnative_db not available');
    });
    return;
  }

  group('executor after a lost connection (requires Docker Postgres)', () {
    late PostgresConnectionPool pool;

    setUp(() async {
      // maxSize 1: the control case below must get the very slot the
      // worker reconnected.
      pool = PostgresConnectionPool.withBinding(
        _binding(),
        const PoolConfig(connInfo: _connInfo, minSize: 1, maxSize: 1),
      );
      await pool.start();
      await withPostgresConnection(pool, (e) async {
        (await e.execute('DROP TABLE IF EXISTS conn_lost_probe')).release();
        (await e.execute('CREATE TABLE conn_lost_probe (id int4)')).release();
      });
    });

    tearDown(() async {
      await withPostgresConnection(pool, (e) async {
        (await e.execute('DROP TABLE IF EXISTS conn_lost_probe')).release();
      });
      await pool.close();
    });

    test('a write after the loss is refused and never committed', () async {
      final uow = PostgresUnitOfWork(pool);
      addTearDown(uow.close);
      await uow.begin();
      final e = uow.executor;
      (await e.execute('INSERT INTO conn_lost_probe VALUES (1)')).release();
      await _killBackend(e);

      await expectLater(e.execute('INSERT INTO conn_lost_probe VALUES (2)'),
          throwsA(isA<ConnectionLostException>()));

      // The case this file exists for: before the guard, this statement
      // ran in autocommit on the reconnected session and was stored.
      await expectLater(e.execute('INSERT INTO conn_lost_probe VALUES (3)'),
          throwsA(isA<ConnectionLostException>()));
      await expectLater(
          e.execute(r'INSERT INTO conn_lost_probe VALUES ($1)',
              params: const [Param.int4(4)]),
          throwsA(isA<ConnectionLostException>()),
          reason: 'the Extended path is guarded too');

      await expectLater(uow.commit(), throwsA(isA<ConnectionLostException>()));
      expect(uow.isActive, isFalse);

      expect(await _probeCount(pool), 0,
          reason: 'nothing written in or after the lost transaction');
    });

    test('executeMultiRead and executePipeline are refused after the loss',
        () async {
      final leased = await pool.acquire();
      try {
        final e = PostgresQueryExecutor(pool.binding, leased.raw);
        ConnectionLostException? lost;
        try {
          (await e.execute(_kill)).release();
        } on ConnectionLostException catch (err) {
          lost = err;
        }
        expect(lost, isNotNull);
        expect(lost!.sql, _kill);
        expect(e.connectionLost, isTrue);

        // The refusal rethrows the original loss: its message names the
        // statement that was lost, not the one refused.
        await expectLater(e.executeMultiRead(const ['SELECT 1', 'SELECT 2']),
            throwsA(same(lost)));
        await expectLater(
            e.executePipeline(const ['INSERT INTO conn_lost_probe VALUES (5)']),
            throwsA(same(lost)));
        await expectLater(e.execute('SELECT 3'), throwsA(same(lost)));
      } finally {
        await leased.release();
      }
      expect(await _probeCount(pool), 0);
    });

    test('a server FATAL on the statement itself is reported as the loss',
        () async {
      final leased = await pool.acquire();
      try {
        final e = PostgresQueryExecutor(pool.binding, leased.raw);
        // The head of this statement is the server's own FATAL: the
        // statement did not run, so the loss is reported right here,
        // and the slot comes back reconnected.
        await expectLater(
            e.execute(_kill), throwsA(isA<ConnectionLostException>()));
        expect(e.connectionLost, isTrue);
      } finally {
        await leased.release();
      }
      await withPostgresConnection(pool, (e) async {
        final rs = await e.execute('SELECT 1 AS n');
        try {
          expect(rs.rows.first.getInt('n'), 1);
        } finally {
          rs.release();
        }
      });
    });

    test('a statement that ran before the link dropped is not the loss',
        () async {
      final leased = await pool.acquire();
      try {
        final e = PostgresQueryExecutor(pool.binding, leased.raw);
        // The INSERT is committed before the kill (the COMMIT closes the
        // implicit transaction of the multi-statement string): reporting
        // a lost connection here would invite a retry that writes twice.
        // The kill's FATAL surfaces as the trailing error, and the loss
        // is reported on the next exchange.
        await expectLater(
            e.execute('INSERT INTO conn_lost_probe VALUES (8); COMMIT; $_kill'),
            throwsA(isA<QueryFailedException>()));
        expect(e.connectionLost, isFalse);
        await expectLater(
            e.execute('SELECT 1'), throwsA(isA<ConnectionLostException>()));
        expect(e.connectionLost, isTrue);
      } finally {
        await leased.release();
      }
      expect(await _probeCount(pool), 1, reason: 'the INSERT ran');
    });

    test('withPostgresConnection: the same executor refuses after the loss',
        () async {
      await withPostgresConnection(pool, (e) async {
        await _killBackend(e);
        await expectLater(
            e.execute('SELECT 1'), throwsA(isA<ConnectionLostException>()));
        await expectLater(e.execute('INSERT INTO conn_lost_probe VALUES (6)'),
            throwsA(isA<ConnectionLostException>()));
      });
      expect(await _probeCount(pool), 0);
    });

    test('the reconnected slot serves the next lease normally', () async {
      final uow = PostgresUnitOfWork(pool);
      addTearDown(uow.close);
      await uow.begin();
      await _killBackend(uow.executor);
      await expectLater(uow.executor.execute('SELECT 1'),
          throwsA(isA<ConnectionLostException>()));
      await expectLater(
          uow.rollback(), throwsA(isA<ConnectionLostException>()));

      // A new executor on the (only) slot is not affected by the old one.
      await withTransaction(pool, (e) async {
        (await e.execute('INSERT INTO conn_lost_probe VALUES (7)')).release();
      });
      expect(await _probeCount(pool), 1);
    });
  });
}
