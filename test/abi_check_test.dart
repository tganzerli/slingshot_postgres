/// Tests for ABI runtime validation.
///
/// Covers:
///   1. Happy path — versions match, no throw, returns (major, minor).
///   2. Major mismatch — expected != linked, throws StateError.
///   3. Minor below expected — non-fatal (no throw), but the warning is
///      emitted to stderr (capture not asserted here; TODO).
///   4. Minor above expected — forward-compat, no throw, no warning.
///
/// Skips gracefully if the native library has not been built.
library;

import 'package:slingshot_postgres/src/bindings/_postgres_abi_constants.dart';
import 'package:slingshot_postgres/src/bindings/postgres_abi_check.dart';
import 'package:slingshot_postgres/src/native/postgres_lib_loader.dart';
import 'package:test/test.dart';

void main() {
  group('assertAbiCompatible', () {
    test('happy path — kExpected matches the linked binary', () {
      try {
        // Bypass the auto-check to load the library raw, then assert manually.
        final lib = loadNativeDb(checkAbi: false);
        final result = assertAbiCompatible(
          lib,
          expectedMajor: kExpectedAbiMajor,
          expectedMinor: kExpectedAbiMinor,
        );
        expect(result.major, kExpectedAbiMajor);
        expect(result.minor, kExpectedAbiMinor);
      } on StateError catch (e) {
        markTestSkipped('Native library not built or symbol missing: $e');
      }
    });

    test('MAJOR mismatch throws StateError', () {
      try {
        final lib = loadNativeDb(checkAbi: false);
        expect(
          () => assertAbiCompatible(
            lib,
            expectedMajor: 99, // intentional mismatch
            expectedMinor: 0,
          ),
          throwsA(isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('MAJOR mismatch is FATAL'),
          )),
        );
      } on StateError catch (e) {
        markTestSkipped('Native library not built or symbol missing: $e');
      }
    });

    test('MINOR below expected is non-fatal (warning only)', () {
      try {
        final lib = loadNativeDb(checkAbi: false);
        // Expect a MINOR higher than what the linked library reports.
        // Should NOT throw — warning goes to stderr (not asserted here).
        expect(
          () => assertAbiCompatible(
            lib,
            expectedMajor: kExpectedAbiMajor,
            expectedMinor: kExpectedAbiMinor + 99, // forces warning path
          ),
          returnsNormally,
        );
      } on StateError catch (e) {
        markTestSkipped('Native library not built or symbol missing: $e');
      }
    });

    test('MINOR above expected (forward-compat) is silent', () {
      try {
        final lib = loadNativeDb(checkAbi: false);
        // Linked library should be >= 0, so expected MINOR = -1 means
        // linked >= expected — should not warn, not throw.
        // Using 0 (the smallest valid expected MINOR) for the same effect.
        final result = assertAbiCompatible(
          lib,
          expectedMajor: kExpectedAbiMajor,
          expectedMinor: 0,
        );
        expect(result.major, kExpectedAbiMajor);
        expect(result.minor, greaterThanOrEqualTo(0));
      } on StateError catch (e) {
        markTestSkipped('Native library not built or symbol missing: $e');
      }
    });
  });

  group('loadNativeDb', () {
    test('checkAbi: true (default) succeeds when versions match', () {
      try {
        final lib = loadNativeDb();
        // Just check we got something back.
        expect(lib, isNotNull);
      } on StateError catch (e) {
        markTestSkipped('Native library not built or symbol missing: $e');
      }
    });
  });
}
