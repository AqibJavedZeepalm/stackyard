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

/// Python from the py launcher, pyenv(-win) and uv.
class PythonTech extends TechAdapter {
  @override
  final info = const TechInfo(id: 'python', name: 'Python', kind: TechKind.toolchain, color: Color(0xFF3776AB), monogram: 'Py', logo: 'assets/tech/python.svg');

  @override
  Future<TechSnapshot?> detect(ScanContext ctx) async {
    final items = <InstalledItem>[];
    final managers = <String>{};
    final seen = <String>{};
    final stale = <(String, String, String?)>[]; // tag, folder, registry key
    final apps = await InstalledApps.load();
    _uninstallers.clear();

    void add(String version, String dir, String source, {bool global = false, bool removable = true, String? hint, List<String> extraPaths = const []}) {
      if (!seen.add(dir.toLowerCase())) return;
      items.add(
        InstalledItem(
          id: 'python:${dir.toLowerCase()}',
          version: version,
          path: dir,
          extraPaths: extraPaths,
          isGlobal: global,
          removable: removable,
          removeHint: hint,
          installedAt: Sys.modified(dir),
          details: {'Source': source},
        ),
      );
    }

    // pyenv / pyenv-win
    for (final root in [p.join(Sys.home, '.pyenv', 'pyenv-win', 'versions'), p.join(Sys.home, '.pyenv', 'versions')]) {
      for (final d in Sys.subdirs(root)) {
        managers.add('pyenv');
        add(p.basename(d.path), d.path, 'pyenv');
      }
    }

    // uv-managed interpreters: cpython-3.12.7-windows-x86_64-none
    for (final root in [p.join(Sys.appData, 'uv', 'python'), p.join(Sys.home, '.local', 'share', 'uv', 'python')]) {
      final dirs = Sys.subdirs(root);
      for (final d in dirs) {
        final m = RegExp(r'^(\w+)-(\d+\.\d+\.\d+)').firstMatch(p.basename(d.path));
        if (m == null || Sys.linkTarget(d.path) != null) continue;
        managers.add('uv');
        // uv also keeps alias links like cpython-3.11-... pointing at the newest patch.
        final here = Sys.canonical(d.path);
        final aliases = [
          for (final other in Sys.entries(root))
            if (Sys.linkTarget(other) case final target?)
              if (Sys.canonical(target) == here) other,
        ];
        add(m[2]!, d.path, 'uv', extraPaths: aliases);
      }
    }
    // Windows py launcher: " -V:3.13 *   C:\...\python.exe". Runs last: uv and
    // pyenv register their Pythons here too, and they already know they own them.
    final py = Sys.isWindows ? Sys.which('py') : null;
    if (py != null) {
      final out = await Sys.run(py, ['-0p']) ?? '';
      for (final m in RegExp(r'-V:(\S+)\s+(\*)?\s*(.+python\.exe)', caseSensitive: false).allMatches(out)) {
        final exe = m[3]!.trim();
        final dir = p.dirname(exe);
        final isDefault = m[2] == '*';
        // "-V:Astral/CPython3.11.17" is registered under HKCU\Software\Python\Astral\CPython3.11.17.
        final tag = m[1]!;
        final registryKey = tag.contains('/') ? 'HKCU\\Software\\Python\\${tag.replaceFirst('/', '\\')}' : null;
        // Store Pythons are app-execution aliases: they report as links that
        // don't "exist", so only treat it as gone when nothing is there at all.
        if (FileSystemEntity.typeSync(exe, followLinks: false) == FileSystemEntityType.notFound) {
          stale.add((tag, dir, registryKey));
          continue;
        }
        final where = Sys.canonical(dir);
        final known = items.indexWhere((i) => Sys.canonical(i.path) == where);
        if (known >= 0) {
          if (registryKey != null) items[known].details['Registry'] = registryKey;
          if (isDefault) items[known] = _asGlobal(items[known]);
          continue;
        }
        final store = dir.contains('WindowsApps');
        final exact = (await Sys.run(m[3]!.trim(), ['--version']))?.replaceFirst('Python ', '') ?? m[1]!;
        final minor = exact.split('.').take(2).join('.');
        // Removed with its own uninstaller (python.org) or as a Store app, never by deleting files.
        final uninstall = store
            ? InstalledApps.storeUninstall('PythonSoftwareFoundation.Python.$minor', 'Uninstall Python $exact (Microsoft Store)')
            : InstalledApps.uninstall(apps.where((a) => a['DisplayName']!.startsWith('Python $exact (')).firstOrNull, title: 'Uninstall Python $exact');
        if (uninstall != null) _uninstallers['python:${dir.toLowerCase()}'] = uninstall;
        add(
          exact,
          dir,
          store ? 'Microsoft Store' : 'python.org installer',
          global: isDefault,
          removable: uninstall != null,
          hint: uninstall != null ? null : 'Its installer isn\'t listed in Installed apps, so Stackyard can\'t remove it safely.',
        );
      }
      if (out.isNotEmpty) managers.add('py launcher');
    }
    if (items.isEmpty) return null;
    items.sort((a, b) => compareVersions(b.version, a.version));

    final snap = TechSnapshot(managerLabel: managers.join(' + '), items: items);
    for (final (tag, dir, key) in stale) {
      snap.problem('Windows still lists Python $tag, but its files at $dir are gone. Commands like "py" may pick this broken entry.', [
        if (key != null)
          NoteFix(
            'Remove the broken entry',
            PlannedChange(
              title: 'Remove the broken Python $tag entry',
              commands: [
                CommandSpec(title: 'Remove it from the py launcher', executable: 'reg.exe', arguments: ['delete', key, '/f']),
              ],
              warning: 'Only removes Windows\' record of it. No files are touched.',
            ),
            recommended: true,
          ),
      ]);
    }
    final global = items.where((i) => i.isGlobal).firstOrNull;
    final versions = items.map((i) => i.version);
    for (final project in ctx.projects.where((pr) => pr.types.contains('python'))) {
      snap.projects.add(project);
      final pin = project.pins['python'];
      if (pin == null) {
        global?.usedBy.add(project.toUsage(note: 'No pin, uses default Python'));
        continue;
      }
      if (pin.exact) {
        final v = bestMatch(versions, pin.raw);
        final item = items.where((i) => i.version == v).firstOrNull;
        if (item != null) {
          item.usedBy.add(project.toUsage());
        } else {
          final minor = RegExp(r'^\d+\.\d+').firstMatch(pin.raw)?[0];
          final install = minor == null ? null : Installers.python(minor);
          snap.problem('${project.name} wants Python ${pin.raw}, which isn\'t installed.', [
            if (install != null) NoteFix('Install Python $minor', PlannedChange(title: 'Install Python $minor', commands: [install]), recommended: true),
          ]);
        }
      } else if (global != null && satisfies(global.version, pin.raw.replaceAll(',', ' '))) {
        global.usedBy.add(project.toUsage(note: 'requires-python ${pin.raw}'));
      }
    }
    return snap;
  }

  @override
  PlannedChange? planInstallFromStack(StackItem item) {
    final minor = item.version.split('.').take(2).join('.');
    final cmd = Installers.python(minor);
    return cmd == null ? null : PlannedChange(title: 'Install Python $minor', commands: [cmd]);
  }

  @override
  String get stackInstallHint => 'Needs Homebrew (brew.sh).';

  /// Uninstallers for Pythons that came from an installer, by item id.
  final _uninstallers = <String, CommandSpec>{};

  /// Removing a uv/pyenv Python also unregisters it from the py launcher,
  /// so `py -0p` doesn't keep listing a Python that's gone.

  @override
  PlannedChange? planRemove(InstalledItem item) {
    if (_uninstallers[item.id] case final uninstall?) {
      return PlannedChange(
        title: 'Uninstall Python ${item.version}',
        commands: [uninstall],
        warning: item.usedBy.isEmpty ? null : '${item.usedBy.length} project(s) use this Python.',
      );
    }
    final base = super.planRemove(item);
    final key = item.details['Registry'];
    if (base == null || key == null) return base;
    return PlannedChange(
      title: base.title,
      recycle: base.recycle,
      commands: [
        CommandSpec(title: 'Unregister it from the py launcher', executable: 'reg', arguments: ['delete', key, '/f']),
      ],
    );
  }

  static InstalledItem _asGlobal(InstalledItem i) => InstalledItem(
    id: i.id,
    version: i.version,
    path: i.path,
    extraPaths: i.extraPaths,
    isGlobal: true,
    removable: i.removable,
    removeHint: i.removeHint,
    installedAt: i.installedAt,
    details: i.details,
  );
}
