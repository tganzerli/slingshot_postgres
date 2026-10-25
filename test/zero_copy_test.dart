/// Smoke test for the zero-copy read API (ABI MINOR 3).
///
/// Validates that the 5 new symbols (get_row_count, get_col_count,
/// get_field_name, get_raw_value, get_raw_length) are reachable via
/// PostgresBinding. Does NOT exercise them against a real PGresult —
/// the contract is "if the symbols resolve, the binding is healthy."
/// Integration with libpq happens in poc_zero_copy.dart against a
/// running Postgres container.
library;

import 'package:slingshot_postgres/src/bindings/postgres_binding.dart';
import 'package:slingshot_postgres/src/native/postgres_lib_loader.dart';
import 'package:test/test.dart';

void main() {
  test('PostgresBinding eagerly resolves the 5 zero-copy read symbols', () {
    try {
      final lib = loadNativeDb();
      final binding = PostgresBinding(lib);

      // PostgresBinding factory uses eager lookupFunction; missing symbols
      // would throw before reaching here.
      expect(binding.getRowCount, isA<Function>());
      expect(binding.getColCount, isA<Function>());
      expect(binding.getFieldName, isA<Function>());
      expect(binding.getRawValue, isA<Function>());
      expect(binding.getRawLength, isA<Function>());
    } on StateError catch (e) {
      markTestSkipped('Native library not built: $e');
    }
  });
}
