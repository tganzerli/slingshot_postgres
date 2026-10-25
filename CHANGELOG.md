# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/). The package follows semver; the native library
(`libnative_db`) carries its own ABI version, `MAJOR.MINOR`, checked at load time: a different MAJOR is fatal, an
older MINOR than the Dart side expects is a warning.

## 0.1.5

First release on pub.dev. Depends on `slingshot` (the contract package, formerly `slingshot_core`) from pub.dev,
`^1.0.3`, instead of by `git`. No API or ABI change; the native library is the one shipped since 0.1.0. An app
that installs this version from pub.dev must not also take `orbiter_postgres` 0.1.4 or older by `git`, which
brings the connector by `git`: use `orbiter_postgres` 0.1.5 or newer.

## 0.1.4

Renamed from `dart_db_connector_postgres` to `slingshot_postgres`; the repository moved with it. No API change: only the package
name, the library import (`package:slingshot_postgres/slingshot_postgres.dart`) and the dependency key change. Depends on `slingshot_core`, the
renamed contract package.

The environment variable `DART_DB_CONNECTOR_NATIVE_LIB_PATH`, which overrides where the native library is
loaded from, keeps its name: renaming it would change behavior.

## 0.1.3

Consumed by `git` reference to the tag `v0.1.3`. Native ABI `2.6`, same native library as `0.1.0`.

### Added

- Full-text search types decode as `String`: `tsvector` (OID 3614), `tsquery` (3615) and `regconfig` (3734), and
  `typeOf` reports `PostgresType.text`. Text results return the server's text form; binary results rebuild the same
  text from the binary structure, so both formats agree (`'a':1A 'b'`, `'jo':* & 'sil':*`). The exception is
  `regconfig` in binary results, which carries only the configuration OID and decodes to it as a decimal `String`
  (`'3748'` for `simple`); text results return the name. `PostgresOid` gains `tsvector`, `tsquery` and `regconfig`.
  These columns used to come back as raw bytes (`Uint8List`); a `::text` cast in the query keeps working.

### Tests

- `full_text_search_test.dart`: a generated `tsvector` column with a GIN index, queried with
  `to_tsquery('simple', $1)` and `Param.text`, ranked with `ts_rank`, through `withTransaction`, in both result
  formats; the GIN index serves the parameterised predicate.

## 0.1.2

Consumed by `git` reference to the tag `v0.1.2`. Native ABI `2.6`, same native library as `0.1.0`.

### Added

- `PostgresConnectionPool.takeAcquireStats()` returns a `PoolAcquireStats` with what `acquire()` saw since the
  previous call (connections handed out, total and maximum wait in microseconds, largest waiter queue on arrival,
  and `acquire()` calls that hit `acquireTimeout`) and resets it. It covers every path that borrows a connection,
  `withTransaction` and `PostgresUnitOfWork` included. Counted only with `PoolConfig.instrumentationEnabled`;
  otherwise all zero. Per pool, so per isolate. A timed-out call counts only in `timeouts`.

### Tests

- `tls_integration_test.dart` reads the certificates only from `TLS_PG_CERTS`; it no longer defaults to a
  directory outside the package, and its skip message says what the directory must contain.

## 0.1.1

Consumed by `git` reference to the tag `v0.1.1`. Native ABI `2.6`, same native library as `0.1.0`.

### Fixed

- `name` (OID 19) and `"char"` (OID 18) columns now decode as `String` in both text and binary results,
  and `typeOf` reports `PostgresType.text` for them. They used to come back as raw bytes, which hit every
  catalog query (`pg_class.relname`, `pg_roles.rolname`, `pg_class.relkind`). A `"char"` byte with the high
  bit set reads as `\ooo` in both formats, as the server renders it in text mode since PostgreSQL 15. Code
  that worked around it with `::text` keeps working.
- `execute` with several statements in one string (no parameters, text results, so the simple query protocol)
  now throws `QueryFailedException` with the server message when any statement fails, not only the first.
  An error from the second statement on used to be dropped: inside a transaction it surfaced on the next query
  as "current transaction is aborted"; outside one, the whole string was rolled back and `execute` returned
  normally. On success the result of the first statement is still the one returned.

### Documentation

- README: "Local PostgreSQL with TLS", the points where a local `verify-full` setup usually goes wrong (SAN, server
  key ownership, `pg_hba.conf`, client certificates per role, client key mode, CI).
- `example/05_tls.dart` and `example/README.md` no longer point to a directory that is not part of this
  repository; the certificates directory is now a required argument.

## 0.1.0

First public release, consumed by `git` reference to the tag `v0.1.0`. Native ABI `2.6`.

### Included

- Native connection pool (`PostgresConnectionPool`, `PoolConfig`): one libpq connection per native thread,
  completions through Dart native ports, acquire timeout, optional instrumentation, graceful `close()` that
  waits for borrowed connections.
- Reconnection of a pooled connection whose link to the server was lost.
- Session reset when a connection returns to the pool (`sessionResetQuery`, default `DISCARD ALL`), with a
  rollback first for a connection returned inside a transaction; or deferred to the first statement of the next
  borrow (`deferSessionReset`, opt-in).
- Transactions: `withTransaction`, `withTransactionOn`, `withPipelinedTransaction`,
  `withTransactionInstrumented`; `withPostgresConnection` for autocommit work. The `BEGIN` of a transaction is
  deferred and sent together with its first statement.
- `PostgresUnitOfWork` and `PostgresRepository<T, K>` over the contracts of `dart_db_connector_core` 1.0.1.
- Extended Query protocol with typed parameters (`Param`), text and binary result decoding, `numeric` as
  `PostgresNumeric`, in-place reads through `PostgresResultSet` / `PostgresResultRow`.
- TLS through any libpq parameter, or `PostgresConnInfo` with an explicit `SslMode`; libpq's startup error
  message in `NativePoolStartupException`; credentials masked in every exception.
- Pre-built native library for `linux-x64`, `linux-arm64`, `macos-x64` and `macos-arm64` in `lib/_native/`.

### ABI history (MAJOR 2)

| MINOR | Adds |
|---|---|
| 0 | Native thread-per-connection pool: `pool_create`, `pool_acquire`, `pool_release`, `pool_submit_query`, `pool_submit_pipeline`, `pool_cancel`, `pool_destroy` |
| 1 | `pool_submit_query_params`: Extended Query protocol with bound parameters |
| 2 | Several reads in one round trip |
| 3 | Reconnection policy for a lost link |
| 4 | libpq's message for a failed `pool_create` |
| 5 | A statement prefix (the deferred `BEGIN`) in the same Extended pipeline |
| 6 | N statement prefixes under one Sync, and the transaction status without a round trip |
