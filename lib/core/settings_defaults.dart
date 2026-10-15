import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'project_scanner.dart';
import 'sys.dart';

/// Folders where developers usually keep projects; only existing ones are used.
List<String> defaultProjectRoots() {
  final home = Sys.home;
  final candidates = <String>[
    p.join(home, 'Projects'),
    p.join(home, 'projects'),
    p.join(home, 'dev'),
    p.join(home, 'Developer'),
    p.join(home, 'code'),
    p.join(home, 'src'),
    p.join(home, 'source', 'repos'),
    p.join(home, 'StudioProjects'),
    p.join(home, 'AndroidStudioProjects'),
    p.join(home, 'Documents', 'GitHub'),
    p.join(home, 'Desktop'),
  ];
  if (Platform.isWindows) {
    for (final drive in ['C', 'D', 'E', 'F']) {
      for (final name in ['Projects', 'projects', 'dev', 'src', 'code', 'repos', 'workspace']) {
        candidates.add('$drive:\\$name');
      }
    }
  }
  final seen = <String>{};
  return [
    for (final c in candidates)
      if (Directory(c).existsSync() && seen.add(Directory(c).resolveSymbolicLinksSync().toLowerCase())) c,
  ];
}

/// Home folders that never hold projects (or are too big to search on first run).
const _notProjects = {'library', 'applications', 'music', 'movies', 'pictures', 'public', 'downloads', 'appdata', 'onedrive', 'videos', 'saved games', 'contacts', 'favorites', 'links', 'searches'};

/// Folders that hold projects, with how many each holds: the usual places and
/// every folder in the home folder, searched [depth] levels down. A folder is
/// left out when another one already covers the same projects. Runs off the UI isolate.
Future<List<(String, int)>> findProjectFolders({String? home, List<String>? usual, int depth = 4}) {
  home ??= Sys.home;
  final homeDir = home;
  final usualDirs = usual ?? defaultProjectRoots();
  return Isolate.run(() {
    final seen = <String>{};
    final candidates = <String>[];
    void consider(String path) {
      try {
        if (seen.add(Directory(path).resolveSymbolicLinksSync().toLowerCase())) candidates.add(path);
      } catch (_) {}
    }

    usualDirs.forEach(consider);
    try {
      for (final e in Directory(homeDir).listSync()) {
        final name = p.basename(e.path);
        final lower = name.toLowerCase();
        // SDKs (fvm, flutter, google-cloud-sdk…) ship sample packages that aren't your projects.
        if (name.startsWith('.') || _notProjects.contains(lower) || lower.startsWith('onedrive') || skipFolderNames.contains(lower) || lower.contains('sdk') || _isFlutterSdk(e.path)) continue;
        if (FileSystemEntity.isDirectorySync(e.path)) consider(e.path);
      }
    } catch (_) {}

    final counts = {for (final c in candidates) c: ProjectScanner.scanSync([c], maxDepth: depth).length}..removeWhere((_, n) => n == 0);
    bool inside(String child, String parent) => p.isWithin(Directory(parent).resolveSymbolicLinksSync().toLowerCase(), Directory(child).resolveSymbolicLinksSync().toLowerCase());
    // ~/Documents and ~/Documents/GitHub: keep the narrower one when it has every project.
    final keep = counts.keys.where((c) {
      for (final other in counts.keys) {
        if (other == c) continue;
        if (inside(c, other) && counts[other]! > counts[c]!) return false; // the parent holds more
        if (inside(other, c) && counts[other]! >= counts[c]!) return false; // a child holds them all
      }
      return true;
    });
    return [for (final c in keep) (c, counts[c]!)]..sort((a, b) => b.$2.compareTo(a.$2));
  });
}

/// A Flutter SDK checkout (it's full of example packages).
bool _isFlutterSdk(String path) =>
    Directory(p.join(path, 'packages', 'flutter_tools')).existsSync() || Directory(p.join(path, 'flutter', 'packages', 'flutter_tools')).existsSync();
