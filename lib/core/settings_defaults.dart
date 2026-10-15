import 'dart:io';

import 'package:path/path.dart' as p;

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
