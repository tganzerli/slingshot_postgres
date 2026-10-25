/// Tests for the Repository + UnitOfWork layer.
/// Most cases require Docker Postgres up; the unit test against a fake
/// PostgresQueryExecutorContract runs unconditionally.
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

Future<void> _resetTable(PostgresQueryExecutorContract exec) async {
  await exec.execute('DROP TABLE IF EXISTS produto');
  await exec.execute('''
    CREATE TABLE produto (
      id int4 PRIMARY KEY,
      codigo_barras text NOT NULL,
      descricao text NOT NULL,
      preco_unitario float8 NOT NULL
    )
  ''');
}

class _FakeExecutor implements PostgresQueryExecutorContract {
  final List<String> log = [];
  final List<List<Param>> paramsLog = [];

  @override
  Future<PostgresResultSet> execute(
    String sql, {
    List<Param> params = const [],
    bool binaryResult = false,
  }) async {
    log.add(sql);
    paramsLog.add(params);
    return PostgresResultSet.empty();
  }
}

/// Repository that opts in to the parameter path (Extended Query Protocol) for
/// `findById` only — leaves the other CRUDs on the string path. Used
/// to exercise the per-method opt-in pattern.
class _Mix {
  final int id;
  const _Mix(this.id);
}

class _MixedTierRepository extends PostgresRepository<_Mix, int> {
  _MixedTierRepository(PostgresQueryExecutorContract exec)
      : super(exec, (r) => _Mix(r.getInt('id')!));
  @override
  String get tableName => 'mix';
  @override
  String get idColumn => 'id';
  @override
  String selectAllSql() => 'SELECT id FROM mix ORDER BY id';
  @override
  String selectByIdSql(int id) =>
      throw StateError('use selectByIdSqlParams');
  @override
  String insertSql(_Mix entity) =>
      'INSERT INTO mix (id) VALUES (${entity.id})';
  @override
  String updateSql(_Mix entity) =>
      'UPDATE mix SET id=${entity.id} WHERE id=${entity.id}';
  @override
  String deleteSql(int id) => 'DELETE FROM mix WHERE id=$id';

  // Parameter-path override only for findById.
  @override
  SqlStmt selectByIdSqlParams(int id) =>
      ('SELECT id FROM mix WHERE id = \$1', [Param.int4(id)]);
}

void main() {
  group('PostgresRepository (no Postgres)', () {
    test('insert/update/delete delegate to executor', () async {
      final fake = _FakeExecutor();
      final repo = ProdutoRepository(fake);
      await repo.insert(const Produto(1, '111', 'X', 1.0));
      await repo.update(const Produto(1, '111', 'X', 2.0));
      await repo.delete(1);

      expect(fake.log.length, 3);
      expect(fake.log[0], contains('INSERT INTO produto'));
      expect(fake.log[1], contains('UPDATE produto'));
      expect(fake.log[2], contains('DELETE FROM produto'));
    });

    test('findById returns null when result set is empty', () async {
      final fake = _FakeExecutor();
      final repo = ProdutoRepository(fake);
      final got = await repo.findById(42);
      expect(got, isNull);
      // String path (default): SQL string with inlined id; no params bound.
      expect(fake.log.single, contains('WHERE id = 42'));
      expect(fake.paramsLog.single, isEmpty);
    });

    test('Tier 2 override (*SqlParams) takes precedence over Tier 1',
        () async {
      // A repository that opts in to PS-binary only for findById
      // (e.g. id comes from an untrusted HTTP path) while keeping
      // String path elsewhere.
      final fake = _FakeExecutor();
      final repo = _MixedTierRepository(fake);

      await repo.findById(99);
      expect(fake.log.single, contains(r'WHERE id = $1'),
          reason: 'Tier 2 path should use \$1 placeholder, not literal');
      expect(fake.paramsLog.single.length, 1);
      expect(fake.paramsLog.single.single.oid, PostgresOid.int4);

      // findAll has no *Params override → falls back to the string path.
      fake.log.clear();
      fake.paramsLog.clear();
      await repo.findAll();
      expect(fake.log.single, equals('SELECT id FROM mix ORDER BY id'),
          reason: 'no Tier 2 override → Tier 1 string used');
      expect(fake.paramsLog.single, isEmpty);
    });
  });

  if (!_canLoadNative()) {
    test('skipped (native library not built)', () {
      markTestSkipped('libnative_db not available');
    });
    return;
  }

  group('PostgresUnitOfWork (requires Docker Postgres)', () {
    test('happy path: insert → commit → findAll', () async {
      final binding = _binding();
      final pool = await _freshPool(binding).catchError((Object e) {
        markTestSkipped('Postgres not reachable: $e');
        throw e;
      });

      try {
        // Setup
        final setup = PostgresUnitOfWork(pool);
        await setup.begin();
        await _resetTable(setup.executor);
        await setup.commit();

        // Insert
        final ins = PostgresUnitOfWork(pool);
        await ins.begin();
        final r1 = ProdutoRepository(ins.executor);
        await r1.insert(const Produto(1, '111', 'A', 10.0));
        await r1.insert(const Produto(2, '222', 'B', 20.0));
        await ins.commit();
        expect(ins.isActive, isFalse);

        // Read
        final read = PostgresUnitOfWork(pool);
        await read.begin();
        final all = await ProdutoRepository(read.executor).findAll();
        await read.commit();
        expect(all.map((p) => p.id), [1, 2]);
        expect(all[0].descricao, 'A');
      } finally {
        await pool.close();
      }
    });

    test('rollback discards mid-transaction writes', () async {
      final binding = _binding();
      final pool = await _freshPool(binding).catchError((Object e) {
        markTestSkipped('Postgres not reachable: $e');
        throw e;
      });

      try {
        final setup = PostgresUnitOfWork(pool);
        await setup.begin();
        await _resetTable(setup.executor);
        await setup.commit();

        final uow = PostgresUnitOfWork(pool);
        await uow.begin();
        await ProdutoRepository(uow.executor)
            .insert(const Produto(7, '777', 'temp', 7.0));
        await uow.rollback();

        final check = PostgresUnitOfWork(pool);
        await check.begin();
        final got = await ProdutoRepository(check.executor).findById(7);
        await check.commit();
        expect(got, isNull);
      } finally {
        await pool.close();
      }
    });

    test('nested begin throws TransactionStateError', () async {
      final binding = _binding();
      final pool = await _freshPool(binding).catchError((Object e) {
        markTestSkipped('Postgres not reachable: $e');
        throw e;
      });

      try {
        final uow = PostgresUnitOfWork(pool);
        await uow.begin();
        expect(uow.begin(), throwsA(isA<TransactionStateError>()));
        await uow.rollback();
      } finally {
        await pool.close();
      }
    });

    test('commit/rollback without begin throws', () async {
      final binding = _binding();
      final pool = await _freshPool(binding).catchError((Object e) {
        markTestSkipped('Postgres not reachable: $e');
        throw e;
      });

      try {
        final uow = PostgresUnitOfWork(pool);
        expect(uow.commit(), throwsA(isA<TransactionStateError>()));
        expect(uow.rollback(), throwsA(isA<TransactionStateError>()));
        expect(() => uow.executor, throwsA(isA<TransactionStateError>()));
      } finally {
        await pool.close();
      }
    });

    test('close() is idempotent and rolls back if active', () async {
      final binding = _binding();
      final pool = await _freshPool(binding).catchError((Object e) {
        markTestSkipped('Postgres not reachable: $e');
        throw e;
      });

      try {
        final setup = PostgresUnitOfWork(pool);
        await setup.begin();
        await _resetTable(setup.executor);
        await setup.commit();

        final uow = PostgresUnitOfWork(pool);
        await uow.begin();
        await ProdutoRepository(uow.executor)
            .insert(const Produto(9, '999', 'ghost', 99.0));
        await uow.close();
        expect(uow.isActive, isFalse);
        await uow.close(); // no-op

        final check = PostgresUnitOfWork(pool);
        await check.begin();
        final got = await ProdutoRepository(check.executor).findById(9);
        await check.commit();
        expect(got, isNull); // rolled back during close()
      } finally {
        await pool.close();
      }
    });
  });
}
