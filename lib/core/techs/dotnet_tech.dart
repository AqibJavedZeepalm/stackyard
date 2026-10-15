import 'dart:ui';

import 'package:path/path.dart' as p;

import '../installed_apps.dart';
import '../installers.dart';
import '../models.dart';
import '../stack_file.dart';
import '../semver.dart';
import '../sys.dart';
import 'tech.dart';

/// .NET SDKs reported by `dotnet --list-sdks`.
class DotnetTech extends TechAdapter {
  @override
  final info = const TechInfo(
    id: 'dotnet',
    name: '.NET SDK',
    kind: TechKind.toolchain,
    color: Color(0xFF512BD4),
    monogram: '.N',
    logo: 'assets/tech/dotnet.svg',
    logoTint: LogoTint.brand,
  );

  @override
  Future<TechSnapshot?> detect(ScanContext ctx) async {
    final dotnet = Sys.which('dotnet');
    if (dotnet == null) return null;
    final out = await Sys.run(dotnet, ['--list-sdks']) ?? '';
    final items = <InstalledItem>[];
    final apps = await InstalledApps.load();
    _uninstallers.clear();
    for (final m in RegExp(r'^(\S+)\s+\[(.+)\]\s*$', multiLine: true).allMatches(out)) {
      final version = m[1]!;
      final dir = p.join(m[2]!, version);
      // Each SDK has its own entry, "Microsoft .NET SDK 8.0.403 (x64)". SDKs that came
      // with Visual Studio don't, and must stay: removing them would break Visual Studio.
      final uninstall = InstalledApps.uninstall(
        apps.where((a) => a['DisplayName']!.startsWith('Microsoft .NET SDK $version (')).firstOrNull,
        title: 'Uninstall .NET SDK $version',
      );
      if (uninstall != null) _uninstallers['dotnet:$version'] = uninstall;
      items.add(
        InstalledItem(
          id: 'dotnet:$version',
          version: version,
          path: dir,
          removable: uninstall != null,
          removeHint: uninstall != null
              ? null
              : Sys.isWindows
              ? 'Installed with Visual Studio. Remove it with the Visual Studio Installer so Visual Studio keeps working.'
              : 'Installed by Microsoft\'s .NET installer into a system folder. Remove it with Microsoft\'s dotnet-uninstall tool.',
          installedAt: Sys.modified(dir),
        ),
      );
    }
    if (items.isEmpty) return null;
    items.sort((a, b) => compareVersions(b.version, a.version));
    // Without a global.json, dotnet uses the newest SDK.
    final newest = items.first;
    items[0] = InstalledItem(
      id: newest.id,
      version: newest.version,
      path: newest.path,
      isGlobal: true,
      removable: newest.removable,
      removeHint: newest.removeHint,
      installedAt: newest.installedAt,
    );

    final snap = TechSnapshot(managerLabel: 'dotnet CLI', items: items);
    for (final project in ctx.projects.where((pr) => pr.types.contains('dotnet'))) {
      snap.projects.add(project);
      final pin = project.pins['dotnet'];
      final rollForward = project.buildInfo['rollForward'];
      final allowPrerelease = project.buildInfo['allowPrerelease'];
      final version = resolveDotnetSdk(
        items.map((i) => i.version),
        pin?.raw,
        rollForward: rollForward,
        allowPrerelease: allowPrerelease == null ? null : allowPrerelease == 'true',
      );
      final target = items.where((i) => i.version == version).firstOrNull;
      if (target != null) {
        final asks = [?pin?.raw, if (rollForward != null) 'rollForward $rollForward', if (allowPrerelease != null) 'allowPrerelease $allowPrerelease'];
        target.usedBy.add(project.toUsage(note: asks.isEmpty ? 'No global.json, uses newest' : 'global.json ${asks.join(', ')} → $version'));
      } else if (pin != null) {
        final policy = rollForward?.toLowerCase() ?? 'patch';
        final later = switch (policy) {
          'patch' || 'latestpatch' => ' (or a later patch)',
          'feature' || 'latestfeature' => ' (or a later feature band)',
          'minor' || 'latestminor' => ' (or a later minor version)',
          'major' || 'latestmajor' => ' (or a later version)',
          _ => '',
        };
        // The installers bring the newest SDK of a major version, which only fits
        // when global.json lets dotnet move past the requested feature band.
        final crossesBands = ['feature', 'minor', 'major'].any(policy.contains);
        final cmd = crossesBands ? Installers.dotnetSdk(pin.raw) : null;
        snap.problem('${project.name} needs .NET SDK ${pin.raw}$later, which isn\'t installed.', [
          if (cmd != null) NoteFix(cmd.title, PlannedChange(title: cmd.title, commands: [cmd]), recommended: true),
        ]);
      }
    }
    return snap;
  }

  @override
  PlannedChange? planInstallFromStack(StackItem item) {
    final cmd = Installers.dotnetSdk(item.version);
    return cmd == null ? null : PlannedChange(title: 'Install .NET SDK ${item.version.split('.').first}', commands: [cmd]);
  }

  @override
  String get stackInstallHint => 'Needs Homebrew (brew.sh).';

  /// Uninstallers for SDKs that have their own Installed-apps entry, by item id.
  final _uninstallers = <String, CommandSpec>{};

  @override
  PlannedChange? planRemove(InstalledItem item) {
    final uninstall = _uninstallers[item.id];
    if (uninstall == null) return super.planRemove(item);
    return PlannedChange(
      title: 'Uninstall .NET SDK ${item.version}',
      commands: [uninstall],
      warning: item.usedBy.isEmpty ? null : '${item.usedBy.length} project(s) build with this SDK.',
    );
  }
}

/// The SDK `dotnet` picks from [installed] for a global.json that asks for
/// [version] (null when it names none), or null when dotnet would fail.
/// Follows dotnet's own resolver: SDK versions are x.y.znn, where z is the
/// feature band and nn the patch.
/// https://learn.microsoft.com/dotnet/core/tools/global-json#matching-rules
String? resolveDotnetSdk(Iterable<String> installed, String? version, {String? rollForward, bool? allowPrerelease}) {
  final want = version == null ? null : Ver.tryParse(version);
  // dotnet rejects anything but a full version like 8.0.302.
  if (version != null && (want == null || want.parts.length < 3)) return null;
  final policy = (rollForward ?? (want == null ? 'latestMajor' : 'patch')).toLowerCase();
  // Prereleases count unless global.json says no, and always when it asks for one.
  final prerelease = (allowPrerelease ?? true) || (want?.pre.isNotEmpty ?? false);
  final sdks = [
    for (final s in installed)
      if (Ver.tryParse(s) case final v? when prerelease || v.pre.isEmpty) (s, v),
  ];
  int band(Ver v) => v.part(2) ~/ 100;
  bool sameBand(Ver a, Ver b) => a.part(0) == b.part(0) && a.part(1) == b.part(1) && band(a) == band(b);
  String? newest(Iterable<(String, Ver)> list) => list.isEmpty ? null : list.reduce((a, b) => a.$2 >= b.$2 ? a : b).$1;

  // No version: dotnet ignores the policy and takes the newest SDK (checked against dotnet 8 and 9).
  if (want == null) return newest(sdks);
  if (policy == 'patch' || policy == 'disable') {
    final exact = sdks.where((s) => s.$2.compareTo(want) == 0).firstOrNull;
    if (exact != null || policy == 'disable') return exact?.$1;
  }
  final fits = sdks.where((s) {
    final v = s.$2;
    if (v < want) return false;
    return switch (policy) {
      'patch' || 'latestpatch' => sameBand(v, want),
      'feature' || 'latestfeature' => v.part(0) == want.part(0) && v.part(1) == want.part(1),
      'minor' || 'latestminor' => v.part(0) == want.part(0),
      'major' || 'latestmajor' => true,
      _ => false,
    };
  }).toList();
  if (fits.isEmpty) return null;
  if (policy.startsWith('latest') || policy == 'patch') return newest(fits);
  // feature, minor and major take the nearest band that has an SDK, then its newest patch.
  final nearest = fits.reduce((a, b) => a.$2 <= b.$2 ? a : b).$2;
  return newest(fits.where((s) => sameBand(s.$2, nearest)));
}
