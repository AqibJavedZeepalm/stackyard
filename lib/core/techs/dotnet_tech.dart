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
      final target = pin == null ? items.first : items.where((i) => i.version == bestMatch(items.map((e) => e.version), pin.raw)).firstOrNull;
      target?.usedBy.add(project.toUsage(note: pin == null ? 'No global.json, uses newest' : null));
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
