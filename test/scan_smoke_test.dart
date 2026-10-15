// Scans the real machine and prints what it finds.
// Run with: flutter test test/scan_smoke_test.dart --dart-define=SMOKE=true
// ignore_for_file: avoid_print
@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:stackyard/core/project_scanner.dart';
import 'package:stackyard/core/registry.dart';
import 'package:stackyard/core/settings_defaults.dart';
import 'package:stackyard/core/sys.dart';
import 'package:stackyard/core/techs/tech.dart';

void main() {
  test(
    'scan this machine',
    () async {
      final roots = defaultProjectRoots();
      print('Roots: $roots');
      final sw = Stopwatch()..start();
      final projects = ProjectScanner.scanSync(roots);
      print('Projects: ${projects.length} in ${sw.elapsedMilliseconds} ms');
      for (final pr in projects) {
        print(
          '  ${pr.name} ${pr.types} pins=${pr.pins.map((k, v) => MapEntry(k, v.raw))} '
          'build=${pr.buildInfo} deps=${pr.deps.map((k, v) => MapEntry(k, v.effective))}',
        );
      }
      final ctx = ScanContext(projects);
      for (final tech in buildRegistry()) {
        final snap = await tech.detect(ctx);
        if (snap == null) continue;
        print('\n== ${tech.info.name}  (${snap.managerLabel})');
        for (final item in snap.items) {
          if (item.group == 'Versions' ||
              item.group == 'Emulators' ||
              item.group == 'Platforms' ||
              item.group == 'NDK' ||
              item.group == 'System' ||
              item.group == 'Caches') {
            final size = item.isCache ? '' : ' ${(await Sys.dirSize(item.path) / 1e9).toStringAsFixed(2)} GB';
            print(
              '  [${item.group}] ${item.title} -> ${item.status.name}$size '
              '${item.usedBy.map((u) => u.name + (u.note != null ? ' (${u.note})' : '')).toList()}',
            );
          } else {
            print('  [${item.group}] ${item.title} -> ${item.status.name}');
          }
        }
        for (final n in snap.notes) {
          print('  ! $n');
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
    skip: !const bool.fromEnvironment('SMOKE'),
  );
}
