/// The native library exports exactly the public ABI listed in
/// `native/exports.txt`, and none of its internals (the vendored Dart API DL
/// copy, the pool workers), and the list matches the functions declared in the
/// public headers. Loads the library only; no database needed.
library;

import 'dart:io';
import 'dart:isolate';

import 'package:slingshot_postgres/src/native/postgres_lib_loader.dart';
import 'package:test/test.dart';

/// The package root, found from the package URI so the test does not depend on
/// the directory `dart test` runs from.
final Uri _packageRoot = Isolate.resolvePackageUriSync(
  Uri.parse('package:slingshot_postgres/'),
)!
    .resolve('../');

/// Symbols that are defined in the library but must stay local to it.
const _internal = [
  'Dart_InitializeApiDL',
  'Dart_PostCObject_DL',
  'FindFunctionPointer',
  'native_pool_worker_main',
  'native_pool_worker_reset',
  'native_pool_free_slot_payload',
];

/// Names of the functions declared in the public headers (`native/include/*.h`,
/// not the vendored `include/dart/`), with comments, preprocessor lines and
/// typedefs stripped first.
Set<String> _declaredInPublicHeaders() {
  final headers = Directory.fromUri(_packageRoot.resolve('native/include/'))
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.h'))
      .map((f) => f.readAsStringSync())
      .join('\n')
      .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
      .replaceAll(RegExp(r'//[^\n]*'), '')
      .replaceAll(RegExp(r'^\s*#.*$', multiLine: true), '')
      .replaceAll(RegExp(r'typedef[^;]*;'), '');
  return RegExp(r'\b([A-Za-z_]\w*)\s*\([^;{]*\)\s*;')
      .allMatches(headers)
      .map((m) => m.group(1)!)
      .toSet();
}

void main() {
  final exportsFile = File.fromUri(_packageRoot.resolve('native/exports.txt'));
  final exported = exportsFile
      .readAsLinesSync()
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty && !l.startsWith('#'))
      .toList();

  test('exports.txt lists exactly the functions of the public headers', () {
    expect(exported, isNotEmpty);
    expect(exported.toSet(), equals(_declaredInPublicHeaders()));
  });

  test('the PostgreSQL library exports every name in exports.txt', () {
    final lib = loadNativeDb(checkAbi: false);
    final missing = exported.where((n) => !lib.providesSymbol(n)).toList();
    expect(missing, isEmpty, reason: 'listed but not exported');
  });

  test('the PostgreSQL library keeps its internals local', () {
    final lib = loadNativeDb(checkAbi: false);
    final leaked = _internal.where(lib.providesSymbol).toList();
    expect(leaked, isEmpty, reason: 'internal symbols visible to dlsym');
  });
}
