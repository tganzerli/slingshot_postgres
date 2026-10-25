/// Vertical-contract conformance — the check that the split into
/// per-DBMS packages cannot quietly become a split into divergent
/// architectures.
///
/// Two halves:
///
///  1. **Static.** `_staticConformance` below does not run; it only has to
///     compile. If a driver stops implementing `UnitOfWork<E>` or
///     `Repository<T, K>`, this file fails to compile and the divergence
///     is caught before it merges.
///
///  2. **Behavioural.** The battery in `package:slingshot_conformance`,
///     driven once per driver against a real database. Each driver skips
///     gracefully when its native lib or its server is unavailable, in
///     the same way the existing integration tests do.
///
/// MongoDB used to appear here in the static half. It moved to its own
/// package on 2026-09-08 and carries its own conformance file
/// (`packages/slingshot_mongo/test/contract_conformance_test.dart`),
/// which is the point of the split: the obligation travels with the driver.
library;

import 'dart:ffi' as ffi;

import 'package:slingshot_postgres/slingshot_postgres.dart';
import 'package:slingshot_postgres/src/bindings/postgres_binding.dart';
import 'package:slingshot_postgres/src/native/postgres_lib_loader.dart';
import 'package:test/test.dart';

import 'package:slingshot_conformance/slingshot_conformance.dart';

const _pgConnInfo =
    'host=localhost port=5432 dbname=teste user=postgres password=123';


/// Compile-time conformance. Never called — the assignments below are the
/// assertion, and the analyzer is the one that checks them.
// ignore: unused_element
void _staticConformance(
  PostgresUnitOfWork pg,
  PostgresRepository<Object, Object> pgRepo,
) {
  // PostgreSQL is the only driver left in this package. The other three assert
  // the same thing from their own packages: MySQL and SQLite since 2026-09-09,
  // MongoDB since 2026-09-08.
  final UnitOfWork<PostgresQueryExecutorContract> a = pg;
  final Repository<Object, Object> d = pgRepo;

  // Silence "unused local" without weakening the assignments above.
  <Object>[a, d];
}

void main() {
  test('every driver implements the shared contract (compile-time)', () {
    // The real assertion is that `_staticConformance` compiles; this test
    // exists so the file reports a passing case instead of an empty run.
    expect(UnitOfWork, isA<Type>());
    expect(Repository, isA<Type>());
  });

  _postgresConformance();
}

void _postgresConformance() {
  PostgresBinding? binding;
  try {
    binding = PostgresBinding(loadNativeDb());
    // Required before any query: the native worker posts its completion
    // through `Dart_PostCObject`, whose function pointer only exists
    // after this call. Skipping it crashes the process on the first
    // callback instead of raising — the `withBinding` constructor does
    // not do it for us.
    binding.initDartApi(ffi.NativeApi.initializeApiDLData);
  } on StateError {
    binding = null;
  }
  if (binding == null) {
    test('postgres conformance skipped', () {
      markTestSkipped('libnative_db not available');
    });
    return;
  }

  final b = binding;
  PostgresConnectionPool? pool;

  setUpAll(() async {
    pool = PostgresConnectionPool.withBinding(
      b,
      const PoolConfig(connInfo: _pgConnInfo, minSize: 1, maxSize: 2),
    );
    await pool!.start();
  });

  tearDownAll(() async => pool?.close());

  runUnitOfWorkConformance<PostgresQueryExecutorContract>(
    driver: 'postgres',
    open: () async => PostgresUnitOfWork(pool!),
  );
}
