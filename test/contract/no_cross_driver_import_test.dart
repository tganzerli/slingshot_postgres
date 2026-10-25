/// Structural invariant: no driver reaches a file of another driver, and the contract
/// layer reaches none of them.
///
/// **What this test still guarantees, after 2026-09-09.** With one driver per package,
/// the first half has become almost a tautology: a package cannot import what it does
/// not declare in its `pubspec`. What remains valuable is the **second** half and the
/// scan guard: if someone reintroduces a file of another driver here, or makes the
/// common layer import a driver, the test still catches it. And the file floor (see the
/// test `the source tree was found`) keeps the suite from passing empty when run from
/// the wrong directory.
///
/// The property held by discipline until 2026-09-08, when an audit found the four
/// verticals already independent, with a single crossing point. That is why the three
/// migrations that followed were a matter of moving directories, not of untangling.
///
/// It is a deliberately textual check: it reads the `import` directives and never loads
/// the code, so it holds even on a machine without the native library built.
library;

import 'dart:io';

import 'package:test/test.dart';

const _drivers = {'postgres'};

/// Empty since 2026-09-09. It used to declare ownership of the generically named files
/// that belonged to Postgres while the rename was deferred. The rename has happened:
/// all of them now have the `postgres_` prefix or live under `lib/src/postgres/`, and
/// `_ownerOf` classifies them on its own.
const _postgresByFact = <String>{};

/// The one file that still knows more than one driver: the loader picks a
/// library and an ABI checker per driver, so it imports all three that remain
/// in this package. The path-walking mechanism it used to own moved to
/// `package:slingshot` when MongoDB left, which is why this list
/// shrinks rather than grows. Listed here so the exception stays visible and
/// countable instead of implicit.
const _knownHubs = {'postgres_lib_loader.dart'};

/// Returns the driver that owns [path], or `null` for the shared layer.
String? _ownerOf(String path) {
  final segments = path.split(Platform.pathSeparator);
  for (final driver in _drivers) {
    if (segments.contains(driver)) return driver;
  }
  final base = segments.last;
  if (_knownHubs.contains(base)) return null;
  for (final driver in _drivers) {
    if (base.startsWith('${driver}_') || base.startsWith('_${driver}_')) {
      return driver;
    }
  }
  if (_postgresByFact.contains(base)) return 'postgres';
  // The deprecated isolate worker pool is the pre-native-pool Postgres
  // path; it predates the per-driver directories.
  if (segments.contains('isolates')) return 'postgres';
  return null;
}

Iterable<String> _relativeImportsOf(File file) sync* {
  final pattern = RegExp("^import\\s+'([^']+)'", multiLine: true);
  for (final match in pattern.allMatches(file.readAsStringSync())) {
    final target = match.group(1)!;
    if (target.startsWith('dart:') || target.startsWith('package:')) continue;
    yield target;
  }
}

void main() {
  final libSrc = Directory('lib/src');

  final dartFiles = libSrc
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('the source tree was found', () {
    // Guards against the whole suite passing vacuously if it ever runs
    // from a different working directory.
    //
    // The floor tracks what is left in this package, and it shrinks as
    // drivers migrate out: 40 while the four shared it, 20 once MySQL and
    // SQLite left on 2026-09-09 and the tree came down to the 24 files that
    // are Postgres. It has to stay below the real count and above zero — the
    // point is catching an empty scan, not pinning a file count.
    expect(dartFiles.length, greaterThan(20));
  });

  test('no driver imports a file owned by another driver', () {
    final offenders = <String>[];
    for (final file in dartFiles) {
      final owner = _ownerOf(file.path);
      if (owner == null) continue;
      for (final imported in _relativeImportsOf(file)) {
        final resolved = Uri.file(file.parent.path)
            .resolve(imported)
            .toFilePath(windows: Platform.isWindows);
        final target = _ownerOf(resolved);
        if (target != null && target != owner) {
          offenders.add('${file.path} ($owner) → $imported ($target)');
        }
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('the shared contract layer imports no driver file', () {
    final offenders = <String>[];
    for (final file in dartFiles) {
      if (_ownerOf(file.path) != null) continue;
      if (_knownHubs.contains(file.uri.pathSegments.last)) continue;
      for (final imported in _relativeImportsOf(file)) {
        final resolved = Uri.file(file.parent.path)
            .resolve(imported)
            .toFilePath(windows: Platform.isWindows);
        final target = _ownerOf(resolved);
        if (target != null) {
          offenders.add('${file.path} (shared) → $imported ($target)');
        }
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });
}
