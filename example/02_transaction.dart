// ignore_for_file: file_names — numbered prefix is intentional for didactic ordering.

/// 02 — Transaction + Repository pattern.
///
/// End-to-end flow combining a [PostgresRepository] subclass (see
/// `produto_repository.dart`) with [withTransaction] for safe
/// commit/rollback. The `body` callback gets a [PostgresQueryExecutorContract] pinned
/// to the transaction's connection; the helper handles the lifecycle.
///
/// Throws inside `body` are rolled back automatically and re-thrown.
///
/// Run (with Postgres up at localhost:5432, dbname=teste):
///   dart run example/02_transaction.dart
library;

import 'package:slingshot_postgres/slingshot_postgres.dart';

import 'produto.dart';
import 'produto_repository.dart';

const _connInfo =
    'host=localhost port=5432 dbname=teste user=postgres password=123';

Future<void> main() async {
  final pool = PostgresConnectionPool(
    const PoolConfig(connInfo: _connInfo, maxSize: 4),
  );
  await pool.start();

  try {
    // DDL — recreate the produto table.
    await withTransaction<void>(pool, (exec) async {
      await exec.execute('DROP TABLE IF EXISTS produto');
      await exec.execute('''
        CREATE TABLE produto (
          id              int4 PRIMARY KEY,
          codigo_barras   text NOT NULL,
          descricao       text NOT NULL,
          preco_unitario  float8 NOT NULL
        )
      ''');
    });
    print('[ok] table produto created');

    // Insert via repository, all in one transaction.
    await withTransaction<void>(pool, (exec) async {
      final repo = ProdutoRepository(exec);
      await repo.insert(const Produto(1, '7891', 'Cafe', 12.5));
      await repo.insert(const Produto(2, '7892', 'Acucar', 4.9));
      await repo.insert(const Produto(3, '7893', 'Leite', 6.2));
    });
    print('[ok] 3 produtos inseridos');

    // Read back via repository.
    final produtos = await withTransaction<List<Produto>>(pool, (exec) async {
      return ProdutoRepository(exec).findAll();
    });
    print('[ok] produtos persistidos:');
    for (final p in produtos) {
      print('  $p');
    }

    // Demonstrate rollback on exception.
    try {
      await withTransaction<void>(pool, (exec) async {
        final repo = ProdutoRepository(exec);
        await repo.insert(const Produto(4, '7894', 'Suco', 8.0));
        throw StateError('simulated business-rule failure after the insert');
      });
    } on StateError catch (e) {
      print('[ok] rollback funcionou — rethrew: ${e.message}');
    }

    final finalCount = await withTransaction<int>(pool, (exec) async {
      return (await ProdutoRepository(exec).findAll()).length;
    });
    assert(finalCount == 3, 'rollback failed: count=$finalCount');
    print('[ok] count final = $finalCount (rollback descartou o insert do produto 4)');
  } finally {
    await pool.close();
  }
}
