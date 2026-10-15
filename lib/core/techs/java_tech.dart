import 'dart:io';
import 'dart:ui';

import 'package:path/path.dart' as p;

import '../installed_apps.dart';
import '../installers.dart';
import '../models.dart';
import '../stack_file.dart';
import '../semver.dart';
import '../sys.dart';
import 'tech.dart';

/// JDKs from the usual installers, IntelliJ's ~/.jdks, SDKMAN and Android Studio.
class JavaTech extends TechAdapter {
  @override
  final info = const TechInfo(id: 'java', name: 'Java', kind: TechKind.toolchain, color: Color(0xFFE76F00), monogram: 'J', logo: 'assets/tech/java.svg');

  @override
  Future<TechSnapshot?> detect(ScanContext ctx) async {
    final candidates = <(String, String, bool)>[]; // path, source, removable
    void addChildren(String root, String source, {bool removable = false}) {
      for (final d in Sys.subdirs(root)) {
        candidates.add((d.path, source, removable));
      }
    }

    if (Sys.isWindows) {
      final pf = Sys.env['ProgramFiles'] ?? r'C:\Program Files';
      for (final vendor in ['Java', 'Eclipse Adoptium', 'Microsoft', 'Zulu', 'Amazon Corretto', 'BellSoft', 'Semeru']) {
        addChildren(p.join(pf, vendor), vendor);
      }
      candidates.add((p.join(pf, 'Android', 'Android Studio', 'jbr'), 'Android Studio', false));
    } else {
      addChildren('/Library/Java/JavaVirtualMachines', 'System');
      candidates.add(('/Applications/Android Studio.app/Contents/jbr', 'Android Studio', false));
    }
    addChildren(p.join(Sys.home, '.jdks'), 'IntelliJ', removable: true);
    addChildren(p.join(Sys.home, '.sdkman', 'candidates', 'java'), 'SDKMAN', removable: true);

    final javaHome = Sys.env['JAVA_HOME'];
    final activeHome = await _activeJavaHome();
    final items = <InstalledItem>[];
    final apps = await InstalledApps.load();
    _uninstallers.clear();
    for (final (path, source, inUserFolder) in candidates) {
      final home = Sys.fileExists(p.join(path, 'Contents', 'Home', 'release')) ? p.join(path, 'Contents', 'Home') : path;
      final release = Sys.readText(p.join(home, 'release'));
      if (release == null) continue;
      final version = RegExp(r'JAVA_VERSION="([^"]+)"').firstMatch(release)?[1] ?? p.basename(path);
      final vendor = RegExp(r'IMPLEMENTOR="([^"]+)"').firstMatch(release)?[1];
      final isActive = [javaHome, activeHome].any((h) => h != null && p.equals(p.normalize(h).toLowerCase(), p.normalize(home).toLowerCase()));
      // JDKs from an installer are removed with that installer, matched by the folder it recorded.
      final id = 'java:${home.toLowerCase()}';
      if (!inUserFolder && source != 'Android Studio') {
        final uninstall = InstalledApps.uninstall(InstalledApps.at(apps, path) ?? InstalledApps.at(apps, home), title: 'Uninstall JDK $version');
        if (uninstall != null) _uninstallers[id] = uninstall;
      }
      final removable = inUserFolder || _uninstallers.containsKey(id);
      items.add(
        InstalledItem(
          id: id,
          version: version,
          label: 'JDK $version',
          path: path,
          group: source == 'Android Studio' ? 'Bundled' : 'Versions',
          isGlobal: isActive,
          usageTracked: false,
          removable: removable,
          removeHint: removable
              ? null
              : source == 'Android Studio'
              ? 'Part of Android Studio. It goes away when Android Studio is removed.'
              : 'Its installer isn\'t listed in Installed apps, so Stackyard can\'t remove it safely.',
          installedAt: Sys.modified(path),
          details: {'Source': source, if (vendor != null) 'Vendor': vendor, if (isActive) 'Active': 'Yes'},
        ),
      );
    }
    if (items.isEmpty) return null;
    items.sort((a, b) => compareVersions(b.version, a.version));

    final snap = TechSnapshot(managerLabel: 'JDKs on this machine', items: items);
    for (final project in ctx.projects) {
      final pin = project.pins['java'];
      if (pin == null) continue;
      snap.projects.add(project);
      final v = bestMatch(items.map((i) => i.version), pin.raw.split('-').first);
      items.where((i) => i.version == v).firstOrNull?.usedBy.add(project.toUsage());
    }
    return snap;
  }

  @override
  PlannedChange? planInstallFromStack(StackItem item) {
    final major = int.tryParse(item.version);
    final cmd = major == null ? null : Installers.jdk(major);
    return cmd == null ? null : PlannedChange(title: 'Install JDK $major', commands: [cmd]);
  }

  @override
  String get stackInstallHint => Sys.isWindows ? 'Only JDK 11, 17, 21 and 25 can be installed automatically.' : 'Needs Homebrew (brew.sh).';

  /// Uninstallers for JDKs that came from an installer, by item id.
  final _uninstallers = <String, CommandSpec>{};

  @override
  PlannedChange? planRemove(InstalledItem item) {
    if (_uninstallers[item.id] case final uninstall?) {
      return PlannedChange(
        title: 'Uninstall ${item.title}',
        commands: [uninstall],
        warning: item.isGlobal ? 'This is the Java that runs when you type "java". Builds that need it will stop working.' : null,
      );
    }
    return super.planRemove(item);
  }

  Future<String?> _activeJavaHome() async {
    final java = Sys.which('java');
    if (java == null) return null;
    try {
      final r = await Process.run(java, ['-XshowSettings:properties', '-version']).timeout(const Duration(seconds: 10));
      return RegExp(r'java\.home = (.+)').firstMatch('${r.stderr}${r.stdout}')?[1]?.trim();
    } catch (_) {
      return null;
    }
  }
}
