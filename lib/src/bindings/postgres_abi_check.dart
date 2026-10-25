/// Runtime ABI validation between the loaded native_db library and this
/// Dart package.
///
/// Calls the C function `native_db_abi_version()` and compares the result
/// against [kExpectedAbiMajor] / [kExpectedAbiMinor]. Behavior follows the
/// policy below:
///
///   - MAJOR mismatch                       -> throw StateError (fatal)
///   - linked MINOR >= expected MINOR       -> OK (forward-compat)
///   - linked MINOR <  expected MINOR       -> warn on stderr (non-blocking)
///
/// Any change here must be paired with a corresponding update to
/// `native/include/native_db.h`.
library;

import 'dart:ffi' as ffi;
import 'dart:io' show stderr;

typedef _AbiVersionNative = ffi.Int64 Function();
typedef _AbiVersionDart = int Function();

const int _kAbiMajorShift = 32;
const int _k32BitMask = 0xFFFFFFFF;

/// Reads `native_db_abi_version()` from [lib] and compares against the
/// expected major/minor. Throws [StateError] on MAJOR mismatch.
///
/// Returns a tuple `(major, minor)` of the linked library (useful for
/// telemetry/logging). The function is idempotent and cheap (~100ns).
({int major, int minor}) assertAbiCompatible(
  ffi.DynamicLibrary lib, {
  required int expectedMajor,
  required int expectedMinor,
}) {
  final fn = lib.lookupFunction<_AbiVersionNative, _AbiVersionDart>(
      'native_db_abi_version');
  final packed = fn();
  final major = (packed >> _kAbiMajorShift) & _k32BitMask;
  final minor = packed & _k32BitMask;

  if (major != expectedMajor) {
    throw StateError(
      'ABI mismatch: native library reports MAJOR=$major MINOR=$minor, '
      'but Dart package expects MAJOR=$expectedMajor MINOR=$expectedMinor. '
      'MAJOR mismatch is FATAL — rebuild '
      'packages/slingshot_postgres/native/ or update the Dart package '
      '(kExpectedAbiMajor in lib/src/bindings/_postgres_abi_constants.dart).',
    );
  }

  if (minor < expectedMinor) {
    stderr.writeln(
      '[slingshot] WARNING: linked native library reports '
      'MINOR=$minor but Dart package expects MINOR>=$expectedMinor. '
      'Some features may be unavailable; consider rebuilding '
      'packages/slingshot_postgres/native/.',
    );
  }

  return (major: major, minor: minor);
}
