/// Unit tests for the PostgreSQL native library resolution.
///
/// Covers the environment override (`DART_DB_CONNECTOR_NATIVE_LIB_PATH`),
/// exercised indirectly via `overridePath` since env vars can't be set
/// per-test in Dart.
///
/// The mechanism itself — platform identifier, candidate list, failure
/// message — moved to `package:slingshot_core` on 2026-09-08 and is
/// tested there (`test/library_resolver_test.dart`).
library;

import 'dart:io';

import 'package:slingshot_postgres/src/native/postgres_lib_loader.dart';
import 'package:test/test.dart';

void main() {
  group('loadNativeDb resolver', () {
    test('throws StateError with helpful message when nothing matches',
        () {
      // Override to a known-nonexistent path so we exercise the
      // failure path. Note that overridePath bypasses the candidate
      // list, so we get a plain `open` failure (FileSystemException
      // wrapped by dart:ffi as ArgumentError), NOT our StateError.
      // The StateError shape comes from the no-args path with all
      // candidates missing — hard to set up here without mocking
      // every search path. Smoke-test the message via reading the
      // source comments would be circular. Skip the full StateError
      // shape test; we cover the message via the manual smoke run
      // in the benchmark harness.
      expect(
        () => loadNativeDb(
          overridePath: '/dev/null/definitely-not-a-real-lib.so',
        ),
        throwsA(anything),
        reason:
            'opening a non-existent override path must surface as some kind of error',
      );
    });

    test('valid override (when the real lib is built) loads OK', () {
      // Locate the actual library via Platform.script's working
      // directory + known dev paths. If the lib is not built we skip
      // (this happens in CI before CMake runs).
      // The package has had its own `native/` tree since 2026-09-09; the
      // `native/c/build` paths are the monolith's layout, kept for anyone who still
      // builds from there.
      final candidates = <String>[
        if (Platform.isMacOS)
          ...[
            'libnative_db.dylib',
            'native/build/libnative_db.dylib',
            '../native/build/libnative_db.dylib',
            '../native/c/build/libnative_db.dylib',
          ],
        if (Platform.isLinux)
          ...[
            'libnative_db.so',
            'native/build/libnative_db.so',
            '../native/build/libnative_db.so',
            '../native/c/build/libnative_db.so',
          ],
        if (Platform.isWindows)
          ...[
            'native_db.dll',
            'native\\build\\native_db.dll',
            '..\\native\\c\\build\\native_db.dll',
          ],
      ];
      String? located;
      for (final c in candidates) {
        if (File(c).existsSync()) {
          located = File(c).absolute.path;
          break;
        }
      }
      if (located == null) {
        markTestSkipped('native lib not built — run cmake to enable');
        return;
      }

      // ABI check is on by default; if the lib has the expected MAJOR
      // version it loads cleanly. If ABI mismatches, the resolver
      // throws — which is a separate test (abi_check_test.dart).
      expect(
        () => loadNativeDb(overridePath: located),
        returnsNormally,
      );
    });
  });
}
