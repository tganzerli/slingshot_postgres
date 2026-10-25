# slingshot_postgres

PostgreSQL driver for Dart backends, built on `libpq` through `dart:ffi`.

Each pooled connection is owned by a native thread outside the Dart VM, and completions come back through
Dart native ports: a blocking database call occupies an OS thread, never an isolate, so the event loop stays
responsive under load. On top of that sits an idiomatic `async`/`await` API.

## Status

**Experimental, not on pub.dev yet.** Consumed by `git` reference to a tagged version (see
[Install](#install)). Native ABI `MAJOR 2 / MINOR 6`.

## Install

Depend on a tag of this repository. The package depends on
[`slingshot_core`](https://github.com/tganzerli/slingshot_core) the same way, so nothing else
is needed in your `pubspec.yaml`:

```yaml
dependencies:
  slingshot_postgres:
    git:
      url: https://github.com/tganzerli/slingshot_postgres
      ref: v0.1.4
```

### Native library

The tag ships the native library pre-built in `lib/_native/<os>-<arch>/` for `linux-x64`, `linux-arm64`,
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

## What is included

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
  contracts of `slingshot_core`.
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

## License

MIT, see `LICENSE`.
