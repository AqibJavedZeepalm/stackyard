import 'dart:convert';
import 'dart:ui';

import 'package:http/http.dart' as http;

import '../models.dart';
import '../semver.dart';
import 'tech.dart';

/// A JS framework that only exists inside projects' node_modules.
class FrameworkTech extends TechAdapter {
  FrameworkTech({required this.package, required String name, required Color color, required String monogram, String? logo, LogoTint logoTint = LogoTint.none})
    : info = TechInfo(id: 'npm:$package', name: name, kind: TechKind.framework, color: color, monogram: monogram, logo: logo, logoTint: logoTint);

  final String package;

  @override
  final TechInfo info;

  List<VersionOption>? _versions;

  @override
  Future<TechSnapshot?> detect(ScanContext ctx) async {
    final users = ctx.projects.where((pr) => pr.deps.containsKey(package)).toList();
    if (users.isEmpty) return null;

    final byVersion = <String, InstalledItem>{};
    for (final project in users) {
      final dep = project.deps[package]!;
      final installed = dep.installed != null;
      final key = dep.effective;
      final item = byVersion.putIfAbsent(
        key,
        () => InstalledItem(
          id: '$id:$key',
          version: key.replaceFirst(RegExp(r'^[\^~=v]'), ''),
          label: installed ? key : '$key (not installed)',
          path: '',
          group: installed ? 'Versions' : 'Declared only',
          removable: false,
          removeHint: '$name lives in each project\'s node_modules. Change or remove it per project.',
        ),
      );
      item.usedBy.add(project.toUsage(note: installed ? null : 'Run ${project.packageManager ?? 'npm'} install'));
    }
    final items = byVersion.values.toList()..sort((a, b) => compareVersions(b.version, a.version));
    final snap = TechSnapshot(managerLabel: 'Found in ${users.length} project${users.length == 1 ? '' : 's'}', items: items);
    snap.projects.addAll(users);
    return snap;
  }

  String get name => info.name;

  @override
  String? projectVersion(Project project) => project.deps[package]?.effective;

  @override
  Future<List<VersionOption>> availableVersions() async {
    if (_versions != null) return _versions!;
    final res = await http
        .get(Uri.parse('https://registry.npmjs.org/${package.replaceAll('/', '%2F')}'), headers: {'Accept': 'application/vnd.npm.install-v1+json'})
        .timeout(const Duration(seconds: 15));
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final latest = data['dist-tags']?['latest'] as String?;
    final versions = (data['versions'] as Map<String, dynamic>).keys.where((v) => !(Ver.tryParse(v)?.isPrerelease ?? true) && !v.contains('-')).toList()
      ..sort((a, b) => compareVersions(b, a));
    // Keep the newest patch of each minor so the list stays short.
    final seenMinor = <String>{};
    final out = <VersionOption>[];
    for (final v in versions) {
      final parsed = Ver.tryParse(v)!;
      if (!seenMinor.add('${parsed.part(0)}.${parsed.part(1)}')) continue;
      out.add(VersionOption(version: v, isLatest: v == latest));
      if (out.length >= 40) break;
    }
    return _versions = out;
  }

  @override
  Future<String?> latestVersion() async => (await availableVersions()).where((v) => v.isLatest).firstOrNull?.version;
}
