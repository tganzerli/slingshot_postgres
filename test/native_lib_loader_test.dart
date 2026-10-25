/// Smoke test: confirms that `loadNativeDb()` resolves the shared library
/// and that `PostgresBinding` maps the expected ABI MAJOR 2 surface.
///
/// Does NOT connect to Postgres — it only validates that the ABI surface
/// is reachable. Skips gracefully if the library has not been built yet.
library;

import 'package:slingshot_postgres/src/bindings/postgres_binding.dart';
import 'package:slingshot_postgres/src/native/postgres_lib_loader.dart';
import 'package:test/test.dart';

void main() {
  test('loadNativeDb resolves library and PostgresBinding maps MAJOR 2 symbols',
      () {
    try {
      final lib = loadNativeDb();
      final binding = PostgresBinding(lib);

      // Closures captured from the FFI lookups — non-null by construction.
      // Any missing symbol would have thrown from `PostgresBinding(lib)`.
      expect(binding.initDartApi, isA<Function>());
      expect(binding.connect, isA<Function>());
      expect(binding.pollResult, isA<Function>());
      expect(binding.closeDb, isA<Function>());

      // ABI MAJOR 2 pool primitives.
      expect(binding.poolCreate, isA<Function>());
      expect(binding.poolAcquire, isA<Function>());
      expect(binding.poolRelease, isA<Function>());
      expect(binding.poolSubmitQuery, isA<Function>());
      expect(binding.poolSubmitPipeline, isA<Function>());
      expect(binding.poolCancel, isA<Function>());
      expect(binding.poolDestroy, isA<Function>());

      // ABI MINOR 1 (2026-05-23) — Extended Query Protocol.
      expect(binding.poolSubmitQueryParams, isA<Function>(),
          reason: 'pool_submit_query_params must be exported (ABI MINOR 1).');
    } on StateError catch (e) {
      // Library not built yet — skip without failing.
      markTestSkipped('Native library not built: $e');
    }
  });
}
