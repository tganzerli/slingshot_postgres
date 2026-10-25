/// Sample `PostgresRepository` for [Produto].
///
/// String-only overrides — the default fast path. Values are
/// inlined into SQL; safe here because the example app populates them
/// internally. For an HTTP/CLI app receiving untrusted input, the
/// matching `*SqlParams` overrides (Extended Query Protocol)
/// should be added — see `PostgresRepository`'s docstring for the
/// mix-and-match pattern.
library;

import 'package:slingshot_postgres/slingshot_postgres.dart';

import 'produto.dart';

class ProdutoRepository extends PostgresRepository<Produto, int> {
  ProdutoRepository(PostgresQueryExecutorContract exec)
      : super(
          exec,
          (r) => Produto(
            r.getInt('id')!,
            r.getString('codigo_barras')!,
            r.getString('descricao')!,
            r.getDouble('preco_unitario')!,
          ),
        );

  @override
  String get tableName => 'produto';

  @override
  String get idColumn => 'id';

  @override
  String selectAllSql() =>
      'SELECT id, codigo_barras, descricao, preco_unitario '
      'FROM produto ORDER BY id';

  @override
  String selectByIdSql(int id) =>
      'SELECT id, codigo_barras, descricao, preco_unitario '
      'FROM produto WHERE id = $id';

  @override
  String insertSql(Produto p) =>
      "INSERT INTO produto (id, codigo_barras, descricao, preco_unitario) "
      "VALUES (${p.id}, '${p.codigoBarras}', '${p.descricao}', ${p.precoUnitario})";

  @override
  String updateSql(Produto p) =>
      "UPDATE produto SET codigo_barras='${p.codigoBarras}', "
      "descricao='${p.descricao}', preco_unitario=${p.precoUnitario} "
      "WHERE id=${p.id}";

  @override
  String deleteSql(int id) => 'DELETE FROM produto WHERE id=$id';
}
