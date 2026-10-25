/// slingshot_postgres — PostgreSQL driver of the slingshot family for Dart Backend.
///
/// Stage: PoC. Public API is **minimal and evolving** — pin to commit
/// hashes rather than version ranges until a 1.0 milestone is published.
///
/// Three drivers share the same layered architecture over a native
/// thread-per-conn pool: **PostgreSQL** (`libpq`), **MySQL**
/// (`libmysqlclient`) and **SQLite** (`libsqlite3`). All reuse
/// the [Repository] and [UnitOfWork] contracts from
/// `package:slingshot`.
///
/// **MongoDB moved out on 2026-09-08** into `slingshot_mongo`, the
/// driver that proves the per-DBMS package split: a consumer that wants only
/// MongoDB no longer builds `libpq`, `libmysqlclient` or `libsqlite3`, and
/// the reverse holds too. The remaining three follow in their own cycle.
///
/// PostgreSQL surface (stable unless marked):
///   - Connection pool: [PostgresConnectionPool], [PooledConnection],
///     [PoolConfig], [PoolExhaustedException], [PoolAcquireStats].
///   - Result decoding: [PostgresResultSet], [PostgresResultRow], [PostgresType],
///     [PostgresOid].
///   - Parameter binding (ABI MINOR 1): [Param], [SqlStmt].
///   - Domain interfaces + errors: [Repository], [UnitOfWork],
///     [QueryFailedException], [QueryTimeoutException],
///     [TransactionStateError]. The query shape is per-driver, so the
///     Postgres executor contract ([PostgresQueryExecutorContract]) ships
///     with the Postgres vertical, not with the domain.
///   - Concrete impls: [PostgresUnitOfWork], [PostgresRepository].
///   - Transactional helpers: [withTransaction], [withTransactionOn].
///   - Isolate worker pool *(deprecated — prefer native thread/conn pool
///     of MAJOR 2)*: [IsolateWorkerPool], [WorkerPoolConfig].
///   - **`@experimental`** (contract may change before 1.0):
///     [withPipelinedTransaction], [withTransactionInstrumented],
///     `TxDiagnostics`, `PoolDiagnosticsSink`.
///
/// MySQL surface (simple protocol, string SQL — no bound
/// parameters in v1):
///   - Connection pool: [MysqlConnectionPool], [MysqlPooledConnection],
///     [MysqlPoolConfig], [MysqlPoolExhaustedException].
///   - Result decoding: [MysqlResultSet], [MysqlResultRow], [MysqlType].
///   - Concrete impls: [MysqlUnitOfWork], [MysqlRepository],
///     [MysqlQueryExecutor].
///   - Transactional helpers: [withMysqlTransaction],
///     [withMysqlTransactionOn].
///
/// What's NOT exported (internal — use `package:slingshot_postgres/src/...`
/// only if you accept ABI/internal churn):
///   - Low-level FFI binding (`PostgresBinding`) — subject to ABI change.
///   - Native library loader (`loadNativeDb`).
///   - Cross-isolate message types of `IsolateWorkerPool` (`QueryRequest`,
///     `QueryResult`, `QueryError`, `WorkerResponse`).
library;

export 'src/config/postgres_conninfo.dart' show PostgresConnInfo, SslMode;
export 'src/pool/postgres_connection_pool.dart'
    show
        PoolAcquireStats,
        PoolConfig,
        PoolExhaustedException,
        PooledConnection,
        PostgresConnectionPool;

export 'src/decoder/postgres_result_row.dart' show PostgresResultRow, PostgresResultSet;
export 'src/decoder/postgres_numeric.dart' show PostgresNumeric;
export 'src/decoder/postgres_type.dart' show PostgresType;
export 'src/decoder/postgres_oids.dart' show PostgresOid;


export 'package:slingshot/slingshot.dart'
    show
        QueryFailedException,
        QueryTimeoutException,
        Repository,
        TransactionStateError,
        UnitOfWork;
export 'src/postgres/postgres_query_executor.dart'
    show PostgresQueryExecutorContract;
export 'src/postgres/postgres_unit_of_work.dart' show PostgresUnitOfWork;
export 'src/postgres/postgres_repository.dart' show PostgresRepository;
export 'src/postgres/param.dart' show Param, SqlStmt;
export 'src/postgres/with_transaction.dart'
    show withPipelinedTransaction, withTransaction, withTransactionOn;
export 'src/postgres/with_postgres_connection.dart' show withPostgresConnection;
export 'src/postgres/with_transaction_instrumented.dart'
    show withTransactionInstrumented;
export 'src/pool/postgres_pool_diagnostics.dart' show TxDiagnostics, PoolDiagnosticsSink;

// ── MySQL driver — moved out (2026-09-09). It now ships as its own
//    package, `slingshot_mysql`, with its own libmysqlclient
//    build.

// ── MongoDB driver — moved out (2026-09-08). It now ships as its own
//    package, `slingshot_mongo`, with its own libmongoc build:
//    the first driver to prove the per-DBMS package split. ──

// ── SQLite driver — moved out (2026-09-09). It now ships as its own
//    package, `slingshot_sqlite`, with its own libsqlite3 build.
