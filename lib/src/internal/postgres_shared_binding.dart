/// Per-isolate singleton holder for [PostgresBinding].
///
/// The public API of `slingshot_postgres` (`PostgresConnectionPool`,
/// `withTransaction`, etc.) hides FFI from consumers. Internally, all of
/// these need access to a configured [PostgresBinding] (which wraps
/// `libnative_db` symbols + initialised Dart Native API). Constructing
/// that binding manually is exactly what the public API removes — consumer
/// shouldn't import `PostgresBinding` nor call `loadNativeDb` directly.
///
/// This singleton resolves the binding lazily on the first call. Each
/// Dart isolate gets its own instance (Dart statics are per-isolate by
/// nature). Within a given isolate the binding is created once and
/// reused — including the one-time call to `Dart_InitializeApiDL`,
/// which must happen exactly once per isolate before any
/// `Dart_PostCObject_DL` from a native thread.
///
/// Marked `@internal` (via `package:meta`) so external consumers of the
/// package don't accidentally depend on the helper — they should only
/// touch `PostgresConnectionPool` and the rest of the public surface.
library;

import 'dart:ffi' as ffi;

import 'package:meta/meta.dart';

import '../bindings/postgres_binding.dart';
import '../native/postgres_lib_loader.dart';

@internal
class SharedBinding {
  static PostgresBinding? _instance;

  /// Resolves the per-isolate singleton [PostgresBinding].
  ///
  /// Idempotent: subsequent calls return the same instance. The first
  /// call:
  /// 1. Locates and opens `libnative_db.{dylib,so,dll}` via the
  ///    resolver in `lib/src/postgres_lib_loader.dart`.
  /// 2. Validates the ABI version (MAJOR mismatch is fatal).
  /// 3. Calls `Dart_InitializeApiDL` so native threads can post to
  ///    Dart Native Ports.
  ///
  /// Throws [StateError] if the native library cannot be located or
  /// if the Dart Native API fails to initialise.
  static PostgresBinding instance() {
    final cached = _instance;
    if (cached != null) return cached;

    final lib = loadNativeDb();
    final binding = PostgresBinding(lib);
    if (binding.initDartApi(ffi.NativeApi.initializeApiDLData) != 0) {
      throw StateError(
        'Failed to initialize Dart Native API '
        '(Dart_InitializeApiDL returned non-zero). '
        'This is unrecoverable in the current isolate.',
      );
    }
    _instance = binding;
    return binding;
  }

  /// Replaces the cached instance — strictly for tests that need to
  /// inject a custom binding. Not part of the public API; callers must
  /// import `package:slingshot_postgres/src/_internal/...` explicitly.
  ///
  /// Pass `null` to clear the cache (next [instance] call will re-resolve
  /// from scratch).
  @visibleForTesting
  static void debugSet(PostgresBinding? binding) {
    _instance = binding;
  }

  /// Whether a binding has already been resolved in this isolate.
  @visibleForTesting
  static bool get debugHasInstance => _instance != null;
}
