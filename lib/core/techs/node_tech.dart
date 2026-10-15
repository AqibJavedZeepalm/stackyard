import 'dart:convert';
import 'dart:ui';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../installed_apps.dart';
import '../models.dart';
import '../stack_file.dart';
import '../semver.dart';
import '../sys.dart';
import 'tech.dart';

enum _Manager { nvm, fnm, volta }

class NodeTech extends TechAdapter {
  @override
  final info = const TechInfo(id: 'node', name: 'Node.js', kind: TechKind.toolchain, color: Color(0xFF5FA04E), monogram: 'N', logo: 'assets/tech/node.svg');

  _Manager? _manager;
  String? _managerExe;
  List<VersionOption>? _releases;

  /// macOS / Linux nvm: a shell function, so it's run as `bash -c '. nvm.sh && nvm …'`.
  String? _nvmSh;

  /// The command that runs `nvm`/`fnm`/`volta` with [args].
  CommandSpec _managerCommand(String title, List<String> args, {bool needsAdmin = false}) => _nvmSh != null && _manager == _Manager.nvm
      ? CommandSpec(title: title, executable: _managerExe!, arguments: ['-c', '. "\$1" && nvm ${args.join(' ')}', 'bash', _nvmSh!])
      : CommandSpec(title: title, executable: _managerExe!, arguments: args, needsAdmin: needsAdmin);

  /// nvm is installed but a Node.js installer copy sits where its link must go.
  bool _nvmBlocked = false;

  @override
  Future<TechSnapshot?> detect(ScanContext ctx) async {
    final items = <InstalledItem>[];
    final managers = <String>[];
    final notes = <String>[];
    // Re-decided on every scan: a fix may have just removed a manager.
    _manager = null;
    _managerExe = null;
    _nvmSh = null;
    _systemNode = null;
    var nvmVersions = <String>[];
    String? blockedLink;

    // nvm-windows
    final nvmExe = Sys.which('nvm');
    final nvmSettings = Sys.readText(p.join(Sys.appData, 'nvm', 'settings.txt')) ?? '';
    String? setting(String key) => RegExp('^$key:\\s*(.+)\$', multiLine: true).firstMatch(nvmSettings)?[1]?.trim();
    final nvmRoot = Sys.env['NVM_HOME'] ?? setting('root');
    final nvmLink = Sys.env['NVM_SYMLINK'] ?? setting('path');
    if (nvmRoot != null && Sys.dirExists(nvmRoot)) {
      // Everything here comes from nvm's folders and settings.txt. Never run nvm.exe
      // just to look: some installs open an invisible prompt that disables whatever
      // window is in front (Stackyard's, right after launch) until nvm exits.
      for (final d in Sys.subdirs(nvmRoot)) {
        final name = p.basename(d.path);
        if (!RegExp(r'^v\d').hasMatch(name)) continue;
        nvmVersions.add(name.substring(1));
        items.add(_item(name.substring(1), d.path, 'nvm'));
      }
      // nvm switches versions by pointing a link at this folder. A Node.js from the
      // official installer sitting there instead blocks it completely.
      final blocked = nvmLink != null && Sys.dirExists(nvmLink) && Sys.linkTarget(nvmLink) == null;
      if (blocked) blockedLink = nvmLink;
      managers.add(nvmVersions.isEmpty ? 'nvm-windows (no versions)' : 'nvm-windows');
      if (!blocked && nvmExe != null) {
        _manager ??= _Manager.nvm;
        _managerExe ??= nvmExe;
      }
    }
    _nvmBlocked = blockedLink != null;

    // nvm on macOS / Linux: a shell function, so its versions are read from its folder.
    if (!Sys.isWindows) {
      final nvmHome = Sys.env['NVM_DIR'] ?? p.join(Sys.home, '.nvm');
      final nvmDir = p.join(nvmHome, 'versions', 'node');
      final nvmSh = [p.join(nvmHome, 'nvm.sh'), '/opt/homebrew/opt/nvm/nvm.sh', '/usr/local/opt/nvm/nvm.sh'].where(Sys.fileExists).firstOrNull;
      if (nvmSh != null) {
        _manager ??= _Manager.nvm;
        _managerExe ??= '/bin/bash';
        _nvmSh = nvmSh;
      }
      if (Sys.dirExists(nvmDir)) {
        managers.add('nvm');
        for (final d in Sys.subdirs(nvmDir)) {
          final name = p.basename(d.path);
          if (RegExp(r'^v\d').hasMatch(name)) items.add(_item(name.substring(1), d.path, 'nvm'));
        }
      }
    }

    // fnm
    final fnmDir = Sys.env['FNM_DIR'] ??
        (Sys.isWindows
            ? p.join(Sys.appData, 'fnm')
            : [
                p.join(Sys.env['XDG_DATA_HOME'] ?? p.join(Sys.home, '.local', 'share'), 'fnm'),
                p.join(Sys.home, 'Library', 'Application Support', 'fnm'),
                p.join(Sys.home, '.fnm'),
              ].firstWhere(Sys.dirExists, orElse: () => p.join(Sys.home, '.local', 'share', 'fnm')));
    final fnmVersions = p.join(fnmDir, 'node-versions');
    final fnmExe = Sys.which('fnm');
    // A fresh fnm has no versions folder yet but can still install.
    if (Sys.dirExists(fnmVersions) || fnmExe != null) {
      managers.add('fnm');
      if (fnmExe != null) {
        _manager ??= _Manager.fnm;
        _managerExe ??= fnmExe;
      }
      for (final d in Sys.subdirs(fnmVersions)) {
        final name = p.basename(d.path);
        if (!name.startsWith('v')) continue;
        items.add(_item(name.substring(1), d.path, 'fnm'));
      }
    }

    // Volta
    final voltaNode = p.join(Sys.env['VOLTA_HOME'] ?? (Sys.isWindows ? p.join(Sys.localAppData, 'Volta') : p.join(Sys.home, '.volta')), 'tools', 'image', 'node');
    if (Sys.dirExists(voltaNode)) {
      managers.add('Volta');
      final voltaExe = Sys.which('volta');
      if (voltaExe != null) {
        _manager ??= _Manager.volta;
        _managerExe ??= voltaExe;
      }
      for (final d in Sys.subdirs(voltaNode)) {
        items.add(_item(p.basename(d.path), d.path, 'Volta'));
      }
    }

    // The node that actually runs when you type `node`.
    final nodeOnPath = Sys.which('node');
    final apps = await InstalledApps.load();
    _nodeApp = apps.where((a) => a['DisplayName'] == 'Node.js').firstOrNull;
    _nvmApp = apps.where((a) => a['DisplayName']!.startsWith('NVM for Windows')).firstOrNull;
    String? active;
    if (nodeOnPath != null) {
      active = (await Sys.run(nodeOnPath, ['-v']))?.replaceFirst('v', '');
      final dir = p.dirname(nodeOnPath);
      final realDir = Sys.linkTarget(dir) ?? dir;
      // It may sit inside a version's folder (fnm: <version>/installation, nvm on macOS: <version>/bin).
      final match = items.where((i) => p.equals(i.path.toLowerCase(), realDir.toLowerCase()) || p.isWithin(i.path.toLowerCase(), realDir.toLowerCase())).firstOrNull;
      if (match == null && active != null) {
        final inProgramFiles = realDir.toLowerCase().contains('program files');
        // The official installer's copy is removed with its own uninstaller, not the Recycle Bin.
        final viaInstaller = inProgramFiles && _nodeUninstall() != null;
        // Only a folder that is a whole Node install (node, npm and its modules
        // together) can go; never a folder of other programs' shims.
        final wholeInstall = Sys.dirExists(p.join(realDir, 'node_modules', 'npm')) || Sys.dirExists(p.join(p.dirname(realDir), 'lib', 'node_modules', 'npm'));
        final homebrew = !Sys.isWindows && (realDir.startsWith('/opt/homebrew') || realDir.startsWith('/usr/local'));
        items.add(
          _systemNode = InstalledItem(
            id: 'node:${realDir.toLowerCase()}',
            version: active,
            label: '$active (system install)',
            path: realDir,
            group: 'System',
            isGlobal: true,
            removable: viaInstaller || (!inProgramFiles && wholeInstall && !homebrew),
            removeHint: homebrew
                ? 'Installed with Homebrew, which manages its files. Remove it with Homebrew.'
                : inProgramFiles && !viaInstaller
                ? 'Installed with the Node.js installer. Remove it from Windows Settings → Apps.'
                : !inProgramFiles && !wholeInstall
                ? '$realDir holds other programs too, so Stackyard won\'t remove it.'
                : null,
            installedAt: Sys.modified(realDir),
            details: {'Source': homebrew ? 'Homebrew' : 'Node.js installer', 'Binary': nodeOnPath},
          ),
        );
      }
    }
    if (items.isEmpty) return null;

    // Mark the active one global.
    final globalIdx = items.indexWhere((i) => i.isGlobal);
    if (globalIdx < 0 && active != null) {
      final i = items.indexWhere((i) => i.version == active);
      if (i >= 0) items[i] = _item(items[i].version, items[i].path, items[i].details['Manager']!, isGlobal: true);
    }

    items.sort((a, b) => compareVersions(b.version, a.version));
    final snap = TechSnapshot(managerLabel: managers.isEmpty ? 'Node.js installer' : managers.join(' + '), items: items, notes: notes);
    if (blockedLink != null) _explainNvmClash(snap, blockedLink, nvmVersions);
    // Fixes for projects that need another Node pick from the real release list.
    if (ctx.projects.any((pr) => pr.pins['node'] != null)) {
      try {
        await availableVersions().timeout(const Duration(seconds: 6));
      } catch (_) {
        // Offline: the problems still show, just without an install button.
      }
    }
    _link(snap, ctx);
    return snap;
  }

  // ---- Installed-apps entries, for fixes that uninstall things properly ----

  Map<String, String>? _nodeApp;
  Map<String, String>? _nvmApp;
  InstalledItem? _systemNode;

  /// Removes the Node.js installer's copy with Windows' own uninstaller.
  CommandSpec? _nodeUninstall() => InstalledApps.uninstall(_nodeApp, title: 'Uninstall Node.js ${_nodeApp?['DisplayVersion'] ?? ''}'.trim());

  /// Removes NVM for Windows with its own uninstaller, without its questions.
  CommandSpec? _nvmUninstall() => InstalledApps.uninstall(_nvmApp, title: 'Uninstall NVM for Windows');

  /// nvm and the Node.js installer both want the same folder. Say so plainly and
  /// offer the fix that keeps everything working.
  void _explainNvmClash(TechSnapshot snap, String folder, List<String> nvmVersions) {
    final node = _systemNode?.version;
    final removeNvm = _nvmUninstall();
    final removeNode = _nodeUninstall();
    final nvmExe = Sys.which('nvm');
    final keepNode = removeNvm == null
        ? null
        : NoteFix(
            'Remove nvm, keep Node.js${node == null ? '' : ' $node'}',
            PlannedChange(
              title: 'Remove NVM for Windows',
              commands: [removeNvm],
              warning: 'Your Node.js${node == null ? '' : ' $node'}, your projects and your global npm packages stay exactly as they are.',
            ),
            recommended: nvmVersions.isEmpty,
          );
    if (nvmVersions.isEmpty) {
      snap.problem(
        'Two Node.js setups are clashing. NVM for Windows is installed but has no Node versions, and it can\'t work '
        'because the Node.js installer already uses $folder, the folder nvm needs. Removing nvm fixes this and '
        'changes nothing for your projects.',
        [?keepNode],
      );
      return;
    }
    final newest = ([...nvmVersions]..sort(compareVersions)).last;
    snap.problem(
      'nvm can\'t switch Node versions: the Node.js installer${node == null ? '' : '\'s Node $node'} sits in $folder, '
      'the folder nvm needs for switching.',
      [
        if (removeNode != null && nvmExe != null)
          NoteFix(
            'Let nvm manage Node',
            PlannedChange(
              title: 'Hand Node.js over to nvm',
              commands: [
                removeNode,
                CommandSpec(title: 'Switch to Node $newest with nvm', executable: nvmExe, arguments: ['use', newest], needsAdmin: true),
              ],
              warning: 'Removes the Node.js installer\'s copy, then makes nvm\'s Node $newest active. Your global npm packages stay.',
            ),
            recommended: true,
          ),
        ?keepNode,
      ],
    );
  }

  InstalledItem _item(String version, String path, String manager, {bool isGlobal = false}) => InstalledItem(
    id: 'node:${path.toLowerCase()}',
    version: version,
    path: path,
    isGlobal: isGlobal,
    installedAt: Sys.modified(path),
    details: {'Manager': manager},
  );

  void _link(TechSnapshot snap, ScanContext ctx) {
    final global = snap.items.where((i) => i.isGlobal).firstOrNull;
    final versions = snap.items.map((i) => i.version).toList();
    for (final project in ctx.projects.where((pr) => pr.types.contains('node'))) {
      final pin = project.pins['node'];
      InstalledItem? target;
      String? note;
      if (pin == null) {
        target = global;
        note = 'No pin, uses active Node';
      } else {
        final spec = _normalizeSpec(pin.raw, versions);
        if (pin.exact) {
          final v = spec == null ? null : bestMatch(versions, spec);
          target = snap.items.where((i) => i.version == v).firstOrNull;
          if (target == null) {
            final want = spec == null || spec == '*' ? null : spec;
            snap.problem('${project.name} wants Node ${pin.raw} (${pin.source}), which isn\'t installed.', [
              if (want != null && _managerExe != null) NoteFix('Install Node $want', planInstall(want)!, recommended: true),
            ]);
          }
        } else if (global != null && spec != null && satisfies(global.version, spec)) {
          target = global;
          note = 'engines ${pin.raw}, uses active Node';
        } else {
          // Offer the newest LTS that satisfies the range (the release list is fetched before linking).
          final fit = spec == null ? null : _releases?.where((r) => r.isLts && satisfies(r.version, spec)).firstOrNull?.version;
          final plan = fit != null && canInstall ? planInstall(fit) : null;
          snap.problem('${project.name} needs Node ${pin.raw}, but the active Node${global == null ? '' : ' (${global.version})'} doesn\'t match.', [
            if (plan != null) NoteFix(_managerExe == null ? 'Switch to Node $fit' : 'Install Node $fit', plan, recommended: true),
          ]);
        }
      }
      if (target != null) target.usedBy.add(project.toUsage(note: note));
      snap.projects.add(project);
    }
  }

  /// Turns nvm aliases into ranges we can match.
  String? _normalizeSpec(String raw, List<String> installed) {
    final s = raw.trim().toLowerCase();
    if (s == 'node' || s == 'latest' || s == 'current' || s == 'stable') return '*';
    if (s.startsWith('lts')) {
      final even = installed.where((v) => (Ver.tryParse(v)?.part(0) ?? 1).isEven).toList()..sort(compareVersions);
      return even.isEmpty ? null : even.last;
    }
    return s.replaceFirst(RegExp(r'^v'), '');
  }

  // ---- Upstream releases ----

  @override
  Future<List<VersionOption>> availableVersions() async {
    if (_releases != null) return _releases!;
    final res = await http.get(Uri.parse('https://nodejs.org/dist/index.json')).timeout(const Duration(seconds: 15));
    final list = jsonDecode(res.body) as List;
    String? latestLts;
    final out = <VersionOption>[];
    for (final r in list) {
      final version = (r['version'] as String).substring(1);
      final lts = r['lts'];
      if (lts != false && latestLts == null) latestLts = version;
      out.add(
        VersionOption(
          version: version,
          channel: lts != false ? 'LTS' : 'Current',
          date: DateTime.tryParse(r['date'] ?? ''),
          isLts: lts != false,
          isLatest: version == latestLts,
          note: lts != false ? 'LTS "$lts"' : null,
        ),
      );
    }
    return _releases = out;
  }

  @override
  Future<String?> latestVersion() async {
    final list = await availableVersions();
    return list.where((v) => v.isLts).firstOrNull?.version;
  }

  // ---- Actions ----

  // A version manager installs side by side; without one, the Node.js installer's
  // copy can still be updated in place. Offering to install nvm while a blocked nvm
  // is already there would be wrong.
  @override
  bool get canInstall => _managerExe != null || _systemNode != null || !_nvmBlocked;

  @override
  PlannedChange? planInstall(String version) {
    if (_managerExe == null && _systemNode != null && Sys.isWindows) {
      final current = _systemNode!.version;
      final release = _releases?.where((r) => r.version == version).firstOrNull;
      final isLatest = release?.isLatest ?? false;
      return PlannedChange(
        title: compareVersions(version, current) > 0 ? 'Update Node.js to $version' : 'Switch Node.js to $version',
        commands: [
          CommandSpec(
            title: 'Install Node.js $version',
            executable: 'winget',
            arguments: [
              'install',
              '--id',
              (release?.isLts ?? true) ? 'OpenJS.NodeJS.LTS' : 'OpenJS.NodeJS',
              '--exact',
              if (!isLatest) ...['--version', version],
              '--silent',
              '--accept-package-agreements',
              '--accept-source-agreements',
              '--disable-interactivity',
            ],
          ),
        ],
        warning: 'Replaces Node.js $current. Your projects and global npm packages stay.',
      );
    }
    if (_managerExe == null && !Sys.isWindows) {
      // macOS: fnm from Homebrew, with its default version on PATH.
      final brew = Sys.which('brew');
      if (brew == null) return null;
      final fnmDir = Sys.env['FNM_DIR'] ?? p.join(Sys.home, '.local', 'share', 'fnm');
      return PlannedChange(
        title: 'Install a Node version manager',
        commands: [CommandSpec(title: 'Install fnm with Homebrew', executable: brew, arguments: ['install', 'fnm'])],
        env: [EnvChange.set('FNM_DIR', fnmDir), EnvChange.prependPath(p.join(fnmDir, 'aliases', 'default', 'bin'))],
        envBlock: 'fnm',
        warning: 'Stackyard rescans when it\'s done, and you can then install Node versions here.',
      );
    }
    if (_managerExe == null) {
      return const PlannedChange(
        title: 'Install a Node version manager',
        commands: [
          CommandSpec(
            title: 'Install nvm for Windows',
            executable: 'winget',
            arguments: ['install', '--id', 'CoreyButler.NVMforWindows', '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements'],
          ),
        ],
        warning: 'Stackyard rescans when it\'s done, and you can then install Node versions here.',
      );
    }
    final args = switch (_manager!) {
      _Manager.nvm => ['install', version],
      _Manager.fnm => ['install', version],
      _Manager.volta => ['fetch', 'node@$version'],
    };
    return PlannedChange(
      title: 'Install Node.js $version',
      commands: [_managerCommand('Download Node.js $version', args)],
    );
  }

  @override
  PlannedChange? planRemove(InstalledItem item) {
    final uninstall = _nodeUninstall();
    if (item.id != _systemNode?.id || uninstall == null || !item.path.toLowerCase().contains('program files')) return super.planRemove(item);
    return PlannedChange(
      title: 'Uninstall Node.js ${item.version}',
      commands: [uninstall],
      warning: item.usedBy.isEmpty ? null : '${item.usedBy.length} project(s) use this Node.js and won\'t run until another version is installed.',
    );
  }

  /// A stack can list several Node versions; without a version manager they'd
  /// keep replacing each other, so import needs one.
  @override
  PlannedChange? planInstallFromStack(StackItem item) => _managerExe == null ? null : planInstall(item.version);

  @override
  String get stackInstallHint => 'Needs a Node version manager (nvm, fnm or Volta) to keep several versions side by side.';

  @override
  bool canSetGlobal(InstalledItem item) => _managerExe != null && !item.isGlobal && item.group == 'Versions';

  @override
  PlannedChange? planSetGlobal(InstalledItem item) {
    final posixNvm = _nvmSh != null && _manager == _Manager.nvm;
    final args = switch (_manager!) {
      // Unix nvm's "use" only lasts for one shell; the default alias is what new terminals get.
      _Manager.nvm => posixNvm ? ['alias', 'default', item.version] : ['use', item.version],
      _Manager.fnm => ['default', item.version],
      _Manager.volta => ['install', 'node@${item.version}'],
    };
    return PlannedChange(
      title: 'Make Node.js ${item.version} the active version',
      commands: [_managerCommand('Switch active Node', args, needsAdmin: _manager == _Manager.nvm)],
      warning: posixNvm && _systemNode != null
          ? 'nvm\'s default changes, but Node.js ${_systemNode!.version} in ${_systemNode!.path} comes first on your PATH, so terminals keep '
                'running it. Remove that one, or load nvm after it in your shell profile.'
          : posixNvm
          ? 'New terminals use it. Terminals already open keep their Node until you run "nvm use default".'
          : _manager == _Manager.nvm
          ? 'nvm-windows asks for administrator permission to switch versions.'
          : null,
    );
  }
}
