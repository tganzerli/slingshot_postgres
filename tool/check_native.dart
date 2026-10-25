// Loads the native library the way the package does at run time and checks
// its ABI against the Dart side. Used by CI after building the library for a
// platform, and handy when a consumer reports a load failure.
//
//   dart run tool/check_native.dart
//   DART_DB_CONNECTOR_NATIVE_LIB_PATH=/abs/libnative_db.so dart run tool/check_native.dart
// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'package:slingshot_postgres/src/bindings/_postgres_abi_constants.dart';
import 'package:slingshot_postgres/src/native/postgres_lib_loader.dart';

void main() {
  loadNativeDb();
  print('libnative_db loaded, ABI $kExpectedAbiMajor.$kExpectedAbiMinor compatible');
}
