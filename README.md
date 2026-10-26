# slingshot_postgres

[![pub package](https://img.shields.io/pub/v/slingshot_postgres.svg)](https://pub.dev/packages/slingshot_postgres)
[![pub points](https://img.shields.io/pub/points/slingshot_postgres)](https://pub.dev/packages/slingshot_postgres/score)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**A PostgreSQL driver for Dart backends that keeps database waits off your isolates: libpq through `dart:ffi`,
with the connection pool running in native threads.**

In a Dart server, the database driver is usually where the language's speed gets lost. This package moves the
expensive part out of the Dart VM: each pooled connection is owned by a native thread that talks to PostgreSQL
through `libpq`, the official client library, and completions come back through Dart native ports. A slow query
occupies an OS thread, never an isolate, so the event loop keeps serving requests under load. Your code sees an
idiomatic `async`/`await` API.

The design was measured against six other drivers (Dart, Go, Java, Node, Python and Rust) in a reproducible
benchmark suite. In a TPC-C workload it led every topology: **712.9 transactions per second** with one connection
and **1,790.2 with four**, against 383.1 and 1,126.5 for the incumbent pure-Dart driver on pub.dev. Behind the same
HTTP framework it served **1.55x to 4.31x** that driver's throughput on the four database-bound endpoints (three
with separated confidence intervals), with a p99 1.6x to 19x lower than Go's. These numbers come from the code
evaluated in the thesis (`dart_db_connector` 0.1.0, tag `tcc-baseline`) on an Apple M4; the method, the limitations
and the steps to reproduce them are in
[`RESULTS.md`](https://github.com/tganzerli/dart_db_connector/blob/main/benchmarks/RESULTS.md). Absolute values
depend on the host: what reproduces is the ordering, which at driver level held on a second, x86_64 machine, while
the HTTP results come from the M4 only.

## Features

- **Native pool, async API:** `PostgresConnectionPool` with acquire timeout, graceful `close()` and optional
  contention metrics for your dashboards.
- **Transactions your way:** `withTransaction`, libpq pipeline mode for bulk writes (`withPipelinedTransaction`),
  per-transaction diagnostics, and the `UnitOfWork`/`Repository` contract of
  [`slingshot`](https://pub.dev/packages/slingshot).
- **Zero-copy reads:** result rows are decoded in place from the native result, in text or binary format, with
  `numeric` kept exact.
- **Safe pooling:** session state (`SET`, `search_path`, temporary tables, advisory locks) is reset when a
  connection returns, so one request never leaks into the next.
- **TLS:** every libpq TLS mode, tested with `verify-full` and client certificates; passwords are masked in every
  exception.
- **Pre-built:** the native library ships in the package for Linux and macOS, x64 and arm64. You only install
  `libpq`.

## Install

```sh
dart pub add slingshot_postgres
```

The contract package, [`slingshot`](https://pub.dev/packages/slingshot), comes with it. The app needs `libpq` where
it runs (`apt install libpq5` or `brew install libpq`); see [Native library](#native-library) for AOT and Docker.

## Quickstart

```dart
import 'package:slingshot_postgres/slingshot_postgres.dart';

Future<void> main() async {
  final pool = PostgresConnectionPool(
    const PoolConfig(
      connInfo: 'host=localhost port=5432 dbname=app user=app password=secret',
      maxSize: 4,
    ),
  );
  await pool.start();
  try {
    final answer = await withTransaction<int>(pool, (exec) async {
      final rs = await exec.execute('SELECT 42::int4 AS answer');
      try {
        return rs.row(0).getInt('answer')!;
      } finally {
        rs.release();
      }
    });
    print(answer); // 42
  } finally {
    await pool.close();
  }
}
```

There is no binding to construct and no library to load by hand: the FFI binding is resolved internally, once
per isolate.

## The family

| Package | Role |
|---|---|
| [`slingshot`](https://pub.dev/packages/slingshot) | The contract every driver implements. |
| [`slingshot_postgres`](https://pub.dev/packages/slingshot_postgres) | This driver. |
| [`orbiter`](https://pub.dev/packages/orbiter) | HTTP backend framework, no database dependency. |
| [`orbiter_postgres`](https://pub.dev/packages/orbiter_postgres) | Kit for `orbiter` + this driver: one row-level-security transaction per request. |

MySQL, MongoDB and SQLite drivers exist in the project and are not published yet.

## Status

Experimental (pre-1.0). Native ABI `MAJOR 2 / MINOR 6`.

## API in detail

- **`PostgresConnectionPool`** and **`PoolConfig`**: the native pool, with an acquire timeout, optional
  instrumentation (`acquireWaitUs`, `queueDepthAtAcquire`) and a graceful `close()`. When no connection frees up
  within `PoolConfig.acquireTimeout`, `acquire()` throws **`PoolExhaustedException`** (carrying the `timeout`); the
  pool stays usable, so the caller can retry, back off or answer `503`.
- **Pool contention for periodic metrics.** With `PoolConfig.instrumentationEnabled`, the pool also accumulates
  what `acquire()` saw, on every path that borrows a connection (`withTransaction` and `PostgresUnitOfWork`
  included). `takeAcquireStats()` returns it as a `PoolAcquireStats` and resets it in the same step: connections
  handed out, total and maximum wait in microseconds, largest waiter queue on arrival, and `acquire()` calls that
  hit `acquireTimeout`. The values are per pool, so per isolate; summing across isolates is up to the caller.
  With instrumentation off the read is all zero.

  ```dart
  // every interval, in each isolate that owns a pool:
  final s = pool.takeAcquireStats();
  log('db.pool', {
    'acquires': s.acquires,
    'waitMeanUs': s.waitMeanUs,
    'waitMaxUs': s.waitMaxUs,
    'queueDepthMax': s.queueDepthMax,
    'timeouts': s.timeouts,
  });
  ```
- **Session reset on release.** `PoolConfig.sessionResetQuery` (default `DISCARD ALL`) runs when a connection
  goes back to the pool, so session state set by one borrower (`SET`, `set_config(..., false)`, `search_path`,
  temporary tables, `LISTEN`, session advisory locks) never reaches the next. A connection returned inside a
  transaction is rolled back first. `PoolConfig.deferSessionReset` moves the same reset to the first statement
  of the next borrow, saving its round trip; with it, session advisory locks and `LISTEN` live until that next
  borrow.
- **Transactions:** `withTransaction`, `withTransactionOn`, `withPipelinedTransaction` (libpq pipeline mode
  for bulk writes), `withTransactionInstrumented` with `TxDiagnostics`, and `withPostgresConnection` for
  autocommit work on one borrowed connection.
- **`PostgresUnitOfWork`** and **`PostgresRepository<T, K>`**, implementing the `UnitOfWork` and `Repository`
  contracts of `slingshot`.
- **Parameters:** `Param` (`Param.int4`, `Param.text`, `Param.timestamptz`, …, `Param.nullValue(oid)`) bound
  through the Extended Query protocol. A typed `NULL` takes its OID from **`PostgresOid`**, the built-in type
  OIDs: `Param.nullValue(PostgresOid.int4)`.
- **Results:** `PostgresResultSet` / `PostgresResultRow` read the native result in place; text and binary
  decoders for the common types, including `numeric` as `PostgresNumeric`. Decoding dispatches on
  **`PostgresType`**, a tag per OID; a column whose OID it does not know (an extension type, for instance) maps to
  `PostgresType.unknown` and comes back as the raw `Uint8List`, so the caller can decode it.
- **TLS:** any libpq TLS parameter in the connection string, or **`PostgresConnInfo`** with **`SslMode`** as an
  explicit choice (no default). Tested with `verify-full` and client certificates; a handshake failure reaches
  `NativePoolStartupException` with libpq's reason, and the password is masked in every exception. See
  [Local PostgreSQL with TLS](#local-postgresql-with-tls).

Not included yet: `LISTEN`/`NOTIFY` delivery, streaming replication, multi-host failover, Windows.

## Native library

The package ships the native library pre-built in `lib/_native/<os>-<arch>/` for `linux-x64`, `linux-arm64`,
`macos-x64` and `macos-arm64`. It links dynamically against `libpq`, which must be installed where the app
runs:

| Platform | Runtime package |
|---|---|
| Debian / Ubuntu | `apt install libpq5` |
| macOS | `brew install libpq` |

Windows is not supported (the native pool uses pthreads).

How the library is found, in order:

1. `DART_DB_CONNECTOR_NATIVE_LIB_PATH`, an absolute path that overrides everything else.
2. The directory of the running executable, or `lib/_native/<os>-<arch>/` next to it.
3. `package:slingshot_postgres/_native/<os>-<arch>/`, the pre-built copy shipped in this package. It
   resolves under `dart run` and `dart test` (JIT) only.
4. `/usr/local/lib`.

**AOT executables** (`dart compile exe`, container images) cannot resolve `package:` URIs at run time, so copy
the library next to the executable:

```dockerfile
FROM dart:stable AS build
WORKDIR /app
COPY . .
RUN dart pub get
RUN dart compile exe bin/server.dart -o /app/server
# Copy the pre-built library of the build platform from the resolved package.
RUN ROOT=$(grep -o '"rootUri": *"file://[^"]*slingshot_postgres[^"]*"' \
        .dart_tool/package_config.json | sed 's|.*file://||; s|"$||') \
    && ARCH=$(uname -m | sed 's/x86_64/x64/; s/aarch64/arm64/') \
    && cp "$ROOT/lib/_native/linux-$ARCH/libnative_db.so" /app/

FROM debian:stable-slim
RUN apt-get update && apt-get install -y --no-install-recommends libpq5 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/server /app/libnative_db.so /app/
ENTRYPOINT ["/app/server"]
```

The `grep` finds the package by name in `.dart_tool/package_config.json`. A copy of this recipe made before the
rename looks for `dart_db_connector_postgres`; change the name there when migrating.

## Local PostgreSQL with TLS

The connector speaks standard PostgreSQL TLS, so any server with `ssl=on` works. To develop and test with
`sslmode=verify-full`, these are the points where a local setup usually goes wrong.

**The host name must be in the server certificate.** `verify-full` checks the `host` of the connection against the
certificate's subjectAltName. With Docker Compose, a client in another container connects by the service name and a
client on the host by `localhost`, so the SAN needs both:

```bash
printf 'subjectAltName=DNS:postgres,DNS:localhost,IP:127.0.0.1\n' > server.ext
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 365 \
  -extfile server.ext -out server.crt
```

**The server key needs owner `postgres` and mode `0600`.** The server refuses any other, and a bind mount keeps the
owner from the host. Mount the files read-only elsewhere and copy them in the container's entrypoint:

```sh
#!/bin/sh
set -eu
mkdir -p /etc/pgtls
cp /tls-src/ca.crt /tls-src/server.crt /tls-src/server.key /tls-src/pg_hba.conf /etc/pgtls/
chown -R postgres:postgres /etc/pgtls
chmod 0600 /etc/pgtls/server.key
exec docker-entrypoint.sh postgres -c ssl=on \
  -c ssl_cert_file=/etc/pgtls/server.crt -c ssl_key_file=/etc/pgtls/server.key \
  -c ssl_ca_file=/etc/pgtls/ca.crt -c hba_file=/etc/pgtls/pg_hba.conf
```

**Refuse plain connections** in `pg_hba.conf`, so a misconfigured client fails instead of silently connecting
without TLS:

```
local    all  all        trust
hostssl  all  all  all   scram-sha-256
host     all  all  all   reject
```

**Client certificates are per role.** With `clientcert=verify-full` on a `hostssl` line, the server compares the
certificate's CN with the user name: each role that connects needs its own certificate.

**The client key must be private.** libpq refuses an `sslkey` that group or others can read; `chmod 0600` it.

**CI.** On GitHub Actions, service containers start before the job's steps, so certificates generated in a step
never reach them. Generate them in one step, start PostgreSQL with `docker run` in the next, and wait for it. Do not
bake a private key into an image.

Connecting:

```dart
final pool = PostgresConnectionPool(PoolConfig(
  connInfo: PostgresConnInfo(
    host: 'postgres', // must match the certificate's SAN
    port: 5432,
    database: 'app',
    user: 'app',
    password: 'secret',
    sslMode: SslMode.verifyFull,
    sslRootCert: 'certs/ca.crt',
  ).build(),
  maxSize: 4,
));
```

## Examples

`example/` has runnable programs against a local PostgreSQL: `main.dart`, `01_simple_query.dart`,
`02_transaction.dart`, `03_pipeline_oltp.dart`, `04_diagnostics.dart` and `05_tls.dart`. See
`example/README.md` for the reading order.

## Building the native library yourself

Only needed on an unsupported platform or to change the C code. Requires CMake ≥ 3.20, a C11 compiler and the
`libpq` headers (`apt install build-essential cmake libpq-dev` or `brew install cmake libpq`):

```bash
cmake -S native -B native/build
cmake --build native/build
export DART_DB_CONNECTOR_NATIVE_LIB_PATH=$PWD/native/build/libnative_db.so   # .dylib on macOS
```

## Tests

```bash
dart pub get
dart test
```

Tests that need a database expect PostgreSQL at `localhost:5432` (`dbname=teste user=postgres password=123`)
and skip when it, or the native library, is unavailable.

## Benchmarks and research

The project started as an MBA thesis in Software Engineering at the University of São Paulo (USP). The code
evaluated there, the cross-language benchmark suite (harnesses in six languages, Docker topologies, statistical
aggregation) and the results are public at
[tganzerli/dart_db_connector](https://github.com/tganzerli/dart_db_connector): see
[`benchmarks/RESULTS.md`](https://github.com/tganzerli/dart_db_connector/blob/main/benchmarks/RESULTS.md) and the
tag `tcc-baseline` for the evaluated state.

## License

MIT, see `LICENSE`.
