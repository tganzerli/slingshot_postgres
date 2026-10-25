/// Tests for `withTransaction` / `withTransactionOn` helpers.
/// Integration cases require Docker Postgres; unit case against fake
/// UoW runs unconditionally.
library;

import 'dart:ffi' as ffi;

import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:slingshot_postgres/src/bindings/postgres_binding.dart';
import 'package:slingshot_postgres/src/native/postgres_lib_loader.dart';
import 'package:test/test.dart';

import '../example/produto.dart';
import '../example/produto_repository.dart';

const _connInfo =
    'host=localhost port=5432 dbname=teste user=postgres password=123';

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

Future<PostgresConnectionPool> _freshPool(PostgresBinding b) async {
  final pool = PostgresConnectionPool.withBinding(b, const PoolConfig(connInfo: _connInfo, minSize: 1, maxSize: 2),
  );
  await pool.start();
  return pool;
}

class _FakeExecutor implements PostgresQueryExecutorContract {
  final List<String> log = [];

  @override
  Future<PostgresResultSet> execute(
    String sql, {
    List<Param> params = const [],
    bool binaryResult = false,
  }) async {
    log.add(sql);
    return PostgresResultSet.empty();
  }
}

/// Records lifecycle events without touching the database. Used to
/// validate `withTransactionOn` shape.
class _FakeUnitOfWork implements UnitOfWork<PostgresQueryExecutorContract> {
  final List<String> events = [];
  final _FakeExecutor _exec = _FakeExecutor();
  bool _active = false;
  bool _willThrowOnCommit;

  _FakeUnitOfWork({bool throwOnCommit = false})
      : _willThrowOnCommit = throwOnCommit;

  @override
  bool get isActive => _active;

  @override
  PostgresQueryExecutorContract get executor {
    if (!_active) {
      throw TransactionStateError('not active');
    }
    return _exec;
  }

  @override
  Future<void> begin() async {
    events.add('begin');
    _active = true;
  }

  @override
  Future<void> commit() async {
    events.add('commit');
    if (_willThrowOnCommit) {
      _active = false;
      _willThrowOnCommit = false;
      throw StateError('commit failed');
    }
    _active = false;
  }

  @override
  Future<void> rollback() async {
    events.add('rollback');
    _active = false;
  }

  @override
  Future<void> close() async {
    events.add('close');
  }
}

void main() {
  group('withTransactionOn (no Postgres)', () {
    test('happy path: begin → body → commit → close, returns value', () async {
      final uow = _FakeUnitOfWork();
      final result = await withTransactionOn<int>(uow, (e) async {
        await e.execute('SELECT 1');
        return 42;
      });
      expect(result, 42);
      expect(uow.events, ['begin', 'commit', 'close']);
      expect(uow._exec.log, ['SELECT 1']);
    });

    test('body throws → rollback + rethrow', () async {
      final uow = _FakeUnitOfWork();
      await expectLater(
        withTransactionOn<void>(uow, (e) async {
          throw StateError('forced');
        }),
        throwsA(isA<StateError>()),
      );
      expect(uow.events, ['begin', 'rollback', 'close']);
    });

    test('body returns void is OK', () async {
      final uow = _FakeUnitOfWork();
      await withTransactionOn<void>(uow, (e) async {
        await e.execute('SELECT 1');
      });
      expect(uow.events, ['begin', 'commit', 'close']);
    });
  });

  if (!_canLoadNative()) {
    test('skipped (native library not built)', () {
      markTestSkipped('libnative_db not available');
    });
    return;
  }

  group('withTransaction (requires Docker Postgres)', () {
    test('rolled-back insert is not visible after exception', () async {
      final binding = _binding();
      final pool = await _freshPool(binding).catchError((Object e) {
        markTestSkipped('Postgres not reachable: $e');
        throw e;
      });

      try {
        // Setup table
        await withTransaction(pool, (e) async {
          await e.execute('DROP TABLE IF EXISTS produto');
          await e.execute('CREATE TABLE produto ('
              'id int4 PRIMARY KEY, codigo_barras text NOT NULL, '
              'descricao text NOT NULL, preco_unitario float8 NOT NULL)');
        });

        await expectLater(
          withTransaction(pool, (e) async {
            await ProdutoRepository(e)
                .insert(const Produto(99, '999', 'ghost', 9.0));
            throw StateError('forced abort');
          }),
          throwsA(isA<StateError>()),
        );

        // After rollback, row should not exist.
        final after = await withTransaction(pool, (e) async {
          return await ProdutoRepository(e).findById(99);
        });
        expect(after, isNull);
      } finally {
        await pool.close();
      }
    });
  });
}
