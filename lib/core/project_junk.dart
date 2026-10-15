import 'dart:io';

import 'package:path/path.dart' as p;

import 'models.dart';

/// A folder inside a project that its tools rebuild on their own, so removing it
/// only costs a slower next build.
class _Rule {
  const _Rule(this.rel, this.rebuilt, {this.types = const {}});

  /// Path inside the project, with forward slashes.
  final String rel;

  /// How it comes back, shown to the user ("npm install").
  final String rebuilt;

  /// Only for projects of these types (any of them). Empty means every project.
  final Set<String> types;
}

const _rules = [
  // Flutter / Dart
  _Rule('build', 'the next flutter build or run', types: {'flutter', 'dart'}),
  _Rule('.dart_tool', 'flutter pub get', types: {'flutter', 'dart'}),
  // Android, inside Flutter / React Native apps or on its own
  _Rule('android/.gradle', 'the next Android build', types: {'flutter', 'node'}),
  _Rule('android/build', 'the next Android build', types: {'flutter', 'node'}),
  _Rule('android/app/build', 'the next Android build', types: {'flutter', 'node'}),
  _Rule('.gradle', 'the next Gradle build', types: {'android'}),
  _Rule('app/build', 'the next Gradle build', types: {'android'}),
  // iOS / macOS CocoaPods
  _Rule('ios/Pods', 'pod install (runs with the next iOS build)', types: {'flutter', 'node'}),
  _Rule('macos/Pods', 'pod install (runs with the next macOS build)', types: {'flutter'}),
  // JavaScript
  _Rule('node_modules', 'installing packages again (npm install)', types: {'node'}),
  _Rule('.next', 'the next Next.js build or dev run', types: {'node'}),
  _Rule('.nuxt', 'the next Nuxt build or dev run', types: {'node'}),
  _Rule('.svelte-kit', 'the next SvelteKit build or dev run', types: {'node'}),
  _Rule('.turbo', 'the next Turborepo run', types: {'node'}),
  _Rule('.parcel-cache', 'the next Parcel build', types: {'node'}),
  _Rule('.angular/cache', 'the next Angular build', types: {'node'}),
  _Rule('.expo', 'the next Expo start', types: {'node'}),
  // Python
  _Rule('.venv', 'creating the environment again and installing packages', types: {'python'}),
  _Rule('venv', 'creating the environment again and installing packages', types: {'python'}),
  _Rule('.pytest_cache', 'the next test run', types: {'python'}),
  _Rule('.mypy_cache', 'the next type check', types: {'python'}),
  _Rule('.ruff_cache', 'the next lint', types: {'python'}),
  // .NET and Java
  _Rule('bin', 'the next dotnet build', types: {'dotnet'}),
  _Rule('obj', 'the next dotnet build', types: {'dotnet'}),
  _Rule('target', 'the next Maven build', types: {'java'}),
];

/// Finds the rebuildable folders in a project. Only real folders count: links
/// are skipped so nothing outside the project is ever touched.
List<InstalledItem> findBuildFolders(Project project) {
  final seen = <String>{};
  final found = <InstalledItem>[];
  for (final rule in _rules) {
    if (rule.types.isNotEmpty && !rule.types.any(project.types.contains)) continue;
    final path = p.joinAll([project.path, ...rule.rel.split('/')]);
    final key = p.normalize(path).toLowerCase();
    if (!seen.add(key)) continue;
    if (FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.directory) continue;
    found.add(
      InstalledItem(
        id: 'junk:$key',
        version: rule.rel,
        label: rule.rel,
        path: path,
        group: project.name,
        installedAt: _modified(path),
        details: {'Comes back with': rule.rebuilt},
      ),
    );
  }
  // Native Android projects keep their output in ./build too. (In a JavaScript
  // project ./build can be the app you ship, so it's left alone.)
  final nativeAndroid = project.types.contains('android') && !project.types.any({'flutter', 'dart', 'node'}.contains);
  if (nativeAndroid) {
    final path = p.join(project.path, 'build');
    final key = p.normalize(path).toLowerCase();
    if (seen.add(key) && FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.directory) {
      found.add(
        InstalledItem(
          id: 'junk:$key',
          version: 'build',
          label: 'build',
          path: path,
          group: project.name,
          installedAt: _modified(path),
          details: const {'Comes back with': 'the next Gradle build'},
        ),
      );
    }
  }
  return found;
}

DateTime? _modified(String path) {
  try {
    return FileStat.statSync(path).modified;
  } catch (_) {
    return null;
  }
}

/// A project and the folders in it that can be cleaned.
class ProjectCleanup {
  ProjectCleanup(this.project, this.folders);
  final Project project;
  final List<InstalledItem> folders;

  int get bytes => folders.fold(0, (s, f) => s + (f.sizeBytes ?? 0));
  bool get measured => folders.every((f) => f.sizeBytes != null);

  /// Not worked on for this long: cleaning costs nothing day to day.
  static const idleAfter = Duration(days: 90);
  bool get isIdle => DateTime.now().difference(project.lastModified) > idleAfter;
}
