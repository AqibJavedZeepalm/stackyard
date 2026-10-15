import 'dart:ui';

import 'package:path/path.dart' as p;

import '../models.dart';
import '../semver.dart';
import '../sys.dart';
import 'tech.dart';

/// Gradle wrapper distributions (~/.gradle/wrapper/dists) and caches.
class GradleTech extends TechAdapter {
  @override
  final info = const TechInfo(
    id: 'gradle',
    name: 'Gradle',
    kind: TechKind.toolchain,
    color: Color(0xFF209BC4),
    monogram: 'G',
    logo: 'assets/tech/gradle.svg',
    logoTint: LogoTint.foreground,
  );

  @override
  Future<TechSnapshot?> detect(ScanContext ctx) async {
    final home = Sys.env['GRADLE_USER_HOME'] ?? p.join(Sys.home, '.gradle');
    if (!Sys.dirExists(home)) return null;
    final items = <InstalledItem>[];

    for (final d in Sys.subdirs(p.join(home, 'wrapper', 'dists'))) {
      final name = p.basename(d.path); // gradle-8.10.2-all
      final m = RegExp(r'^gradle-(.+?)-(all|bin)$').firstMatch(name);
      items.add(
        InstalledItem(
          id: 'gradle:$name',
          version: m?[1] ?? name,
          label: m == null ? name : 'Gradle ${m[1]} (${m[2]})',
          path: d.path,
          installedAt: Sys.modified(d.path),
          details: {'Distribution': name},
        ),
      );
    }
    for (final (folder, label) in [('caches', 'Dependency and build caches'), ('daemon', 'Daemon logs'), ('native', 'Native libraries')]) {
      final path = p.join(home, folder);
      if (!Sys.dirExists(path)) continue;
      items.add(
        InstalledItem(
          id: 'gradle:cache:$folder',
          version: folder,
          label: label,
          path: path,
          group: 'Caches',
          isCache: true,
          details: {'Note': 'Gradle downloads or rebuilds this on the next build.'},
        ),
      );
    }
    if (items.isEmpty) return null;
    items.sort((a, b) => compareVersions(b.version, a.version));

    final snap = TechSnapshot(managerLabel: home, items: items);
    for (final project in ctx.projects) {
      final dist = project.buildInfo['gradle'];
      if (dist == null) continue;
      snap.projects.add(project);
      final item = items.where((i) => i.details['Distribution'] == dist).firstOrNull;
      if (item != null) {
        item.usedBy.add(project.toUsage());
      } else {
        snap.info.add('${project.name} uses $dist, which Gradle downloads on its next build.');
      }
    }
    return snap;
  }

  @override
  String? projectVersion(Project project) => project.buildInfo['gradle']?.replaceFirst('gradle-', '');
}
