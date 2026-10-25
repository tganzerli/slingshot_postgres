# slingshot_postgres — Examples

Runnable demos of the public API. Each file is self-contained; read in
order or jump to the pattern you need.

## Prerequisites

- Postgres reachable at `localhost:5432`, database `teste`, user `postgres`, password `123`. Adjust the `_connInfo` constant at the top of each file if your setup differs.
- Native library `libnative_db.{dylib,so,dll}` available where the resolver looks (see the package README for the 6-path search order).

## Reading order

| # | File | What it shows |
|--:|------|---------------|
| 0 | `main.dart` | Smallest possible end-to-end: open pool → run one SELECT inside a transaction → close. Pub.dev's primary demo. |
| 1 | `01_simple_query.dart` | `ResultSet` metadata inspection (column names, OIDs, [PostgresType]) and typed value access (`getInt`, `getString`, `getDateTime`). |
| 2 | `02_transaction.dart` | `withTransaction` + `PostgresRepository`-based CRUD + rollback-on-exception. Uses the `produto` entity defined in `produto.dart`. |
| 3 | `03_pipeline_oltp.dart` | Bulk INSERT via `withPipelinedTransaction` — N statements in a single network round-trip. **Experimental:** rows are discarded. |
| 4 | `04_diagnostics.dart` | Per-transaction timings via `withTransactionInstrumented` + `TxDiagnostics`. Requires `PoolConfig.instrumentationEnabled = true`. **Experimental.** |
| 5 | `05_tls.dart` | TLS with `verify-full` and a client certificate, built with `PostgresConnInfo` / `SslMode`. Needs a PostgreSQL with TLS; see "Local PostgreSQL with TLS" in the package README. |

## Running

```bash
dart pub get
dart run example/main.dart
dart run example/01_simple_query.dart
dart run example/02_transaction.dart
dart run example/03_pipeline_oltp.dart
dart run example/04_diagnostics.dart
dart run example/05_tls.dart <certs-dir>
```

Each example creates the tables it needs (`produto`, `evento`, `counter`) with `DROP TABLE IF EXISTS` first, so they are idempotent.

## Supporting files

- `produto.dart` — sample entity used by `02_transaction.dart`.
- `produto_repository.dart` — concrete `PostgresRepository<Produto, int>` for the same example.

## What's NOT in the examples

- **Isolate worker pool** (`IsolateWorkerPool`) — `@Deprecated` since ABI MAJOR 2. The native thread/conn pool inside `PostgresConnectionPool` is the recommended way to get parallelism.
- **Prepared statements with parameter binding** — the ergonomic API is not exposed yet (tracked as the `prepared-statements-binary-format` task in the project repo). The current v1 inlines values into SQL strings; do not expose CRUD repositories to untrusted input.
- **LISTEN-NOTIFY / replication** — out of scope for v1.
