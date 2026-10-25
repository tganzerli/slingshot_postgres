/// Resolves the native shared library of each driver that still lives in this
/// package, and validates its ABI.
///
/// The path-walking mechanism moved to `package:slingshot`
/// (`library_resolver.dart`) on 2026-09-08, when MongoDB became its own
/// package: a resolver that hard-codes one package name cannot serve more than
/// one package. What stays here is the per-driver data — filenames, the
/// environment variable, the ABI pair — for PostgreSQL, the only driver left
/// in this package. MySQL and SQLite moved out on 2026-09-09; MongoDB on
/// 2026-09-08.
/// MongoDB's equivalent now lives in `slingshot_mongo`.
///
/// Search order, the failure message and the `_native/<os>-<arch>/` layout are
/// documented on `openDriverLibrary`.
///
/// **Internal helper.** Consumers of `slingshot_postgres` should not call this
/// directly — `PostgresConnectionPool` (and every other public entry point)
/// resolves the binding internally via the per-isolate `SharedBinding`
/// singleton. The functions stay exported within the package source tree
/// because tests, benchmark harnesses, and the internal `IsolateWorkerPool`
/// worker still need direct access. The `@internal` annotation triggers an
/// analyzer warning if it leaks into external code.
library;

import 'dart:ffi' as ffi;

import 'package:slingshot/slingshot.dart';
import 'package:meta/meta.dart';

import '../bindings/_postgres_abi_constants.dart';
import '../bindings/postgres_abi_check.dart';

const _postgresNames = (
  macOS: 'libnative_db.dylib',
  linux: 'libnative_db.so',
  windows: 'native_db.dll',
);

const _envOverride = 'DART_DB_CONNECTOR_NATIVE_LIB_PATH';

@internal
ffi.DynamicLibrary loadNativeDb({
  String? overridePath,
  bool checkAbi = true,
}) {
  final lib =
      _openLibrary(_postgresNames, _envOverride, overridePath: overridePath);
  if (checkAbi) {
    assertAbiCompatible(
      lib,
      expectedMajor: kExpectedAbiMajor,
      expectedMinor: kExpectedAbiMinor,
    );
  }
  return lib;
}

/// Build directories checked last, so the in-repo CMake cycle keeps working.
/// The package owns its own `native/` tree since 2026-09-09; the `native/c`
/// entries are the monolith's layout, kept for a consumer that still points at
/// the old path.
const List<String> _devPaths = [
  'build',
  'native/build',
  '../native/build',
  'packages/slingshot_postgres/native/build',
  'native/c/build',
  '../native/c/build',
  'native/c/build-macos',
  '../native/c/build-macos',
];

const String _buildHint =
    'cmake -S packages/slingshot_postgres/native '
    '-B packages/slingshot_postgres/native/build && '
    'cmake --build packages/slingshot_postgres/native/build';

ffi.DynamicLibrary _openLibrary(
  LibNames names,
  String envOverride, {
  String? overridePath,
}) =>
    openDriverLibrary(
      names: names,
      envOverride: envOverride,
      packageName: 'slingshot_postgres',
      overridePath: overridePath,
      extraDevPaths: _devPaths,
      buildHint: _buildHint,
    );
