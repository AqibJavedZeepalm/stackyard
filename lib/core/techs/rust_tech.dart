import 'dart:convert';
import 'dart:ui';

import 'package:path/path.dart' as p;

import '../models.dart';
import '../semver.dart';
import '../sys.dart';
import 'tech.dart';

/// Rust toolchains installed with rustup, in RUSTUP_HOME (~/.rustup by default).
class RustTech extends TechAdapter {
  @override
  final info = const TechInfo(
    id: 'rust',
    name: 'Rust',
    kind: TechKind.toolchain,
    color: Color(0xFFDEA584),
    monogram: 'Rs',
    logo: 'assets/tech/rust.svg',
    logoTint: LogoTint.foreground,
  );

  /// The rustup home and program the last scan found.
  String? _home;
  String? _rustup;

  /// Projects whose toolchain comes from a `rustup override`, not a file.
  final _overrides = <String, String>{};

  @override
  String? projectVersion(Project project) => _overrides[project.path] ?? super.projectVersion(project);

  @override
  Future<TechSnapshot?> detect(ScanContext ctx) async {
    final home = Sys.env['RUSTUP_HOME'] ?? p.join(Sys.home, '.rustup');
    final toolchains = p.join(home, 'toolchains');
    if (!Sys.dirExists(toolchains)) return null;
    _home = home;
    _overrides.clear();
    // A Mac app started from the Dock may not have ~/.cargo/bin on PATH.
    final bundled = p.join(Sys.env['CARGO_HOME'] ?? p.join(Sys.home, '.cargo'), 'bin', Sys.isWindows ? 'rustup.exe' : 'rustup');
    _rustup = Sys.which('rustup') ?? (Sys.fileExists(bundled) ? bundled : null);

    final settings = Sys.readText(p.join(home, 'settings.toml')) ?? '';
    final names = [
      for (final dir in Sys.entries(toolchains))
        if (Sys.dirExists(dir)) p.basename(dir),
    ];
    String? setting(String key) => RegExp('^$key\\s*=\\s*"([^"]+)"', multiLine: true).firstMatch(settings)?[1];
    final defaultName = setting('default_toolchain');
    final defaultToolchain = defaultName == null ? null : matchToolchain(names, defaultName, host: setting('default_host_triple'));
    final host = setting('default_host_triple') ?? (defaultToolchain == null ? null : splitToolchain(defaultToolchain).$2);

    final items = <InstalledItem>[];
    for (final name in names) {
      final dir = p.join(toolchains, name);
      final linkedTo = Sys.linkTarget(dir);
      // "rustc 1.94.0 (4a4ef493e 2026-03-02)"; the name alone says only "stable" or "nightly".
      final rustc = await Sys.run(p.join(dir, 'bin', Sys.isWindows ? 'rustc.exe' : 'rustc'), ['--version']);
      final version = RegExp(r'^rustc (\S+)').firstMatch(rustc ?? '')?[1] ?? splitToolchain(name).$1;
      final isDefault = name == defaultToolchain;
      items.add(
        InstalledItem(
          id: 'rust:${name.toLowerCase()}',
          version: version,
          label: name,
          path: dir,
          isGlobal: isDefault,
          removable: _rustup != null,
          removeHint: _rustup != null ? null : 'Stackyard can\'t find rustup, which has to uninstall its own toolchains.',
          installedAt: Sys.modified(dir),
          details: {'Toolchain': name, 'Version': version, if (linkedTo != null) 'Linked to': linkedTo, if (isDefault) 'Default': 'Yes'},
        ),
      );
    }
    if (items.isEmpty) return null;
    items.sort((a, b) => compareVersions(b.version, a.version));

    final snap = TechSnapshot(managerLabel: _rustup == null ? home : 'rustup ($home)', items: items);
    InstalledItem? itemFor(String wanted) {
      final name = matchToolchain(names, wanted, host: host);
      return items.where((i) => i.label == name).firstOrNull;
    }

    final overrides = overridesIn(settings);
    final overridden = <String>{};
    for (final project in ctx.projects.where((pr) => pr.types.contains('rust'))) {
      snap.projects.add(project);
      // Like rustup: the closest folder with an override or a toolchain file wins
      // (the override when one folder has both), then the default.
      // rustup keeps overrides under a folder's real path, with links resolved.
      final dir = Sys.canonical(project.path);
      final override = _overrideFor(overrides, dir);
      final pin = project.pins['rust'];
      final pinDir = pin == null ? null : Sys.canonical(p.join(project.path, p.dirname(pin.source)));
      final overrideDir = override == null ? null : Sys.canonical(override.key);
      final useOverride = override != null && (pinDir == null || overrideDir!.length >= pinDir.length);
      final (wanted, note) = useOverride
          ? (override.value, overrideDir == dir ? 'rustup override' : 'rustup override on ${override.key}')
          : pin != null
          ? (pin.raw, null)
          : (null, 'No rust-toolchain file, uses the default toolchain');
      if (useOverride) {
        overridden.add(override.key);
        _overrides[project.path] = splitToolchain(override.value).$1;
      }
      if (wanted == null) {
        items.where((i) => i.isGlobal).firstOrNull?.usedBy.add(project.toUsage(note: note));
        continue;
      }
      // A `path` in the toolchain file is a toolchain outside rustup.
      if (p.isAbsolute(wanted)) continue;
      final item = itemFor(wanted);
      if (item != null) {
        item.usedBy.add(project.toUsage(note: note));
      } else {
        snap.info.add('${project.name} asks for the Rust toolchain $wanted, which isn\'t installed.');
      }
    }
    // Overrides on folders that aren't projects Stackyard found still keep their toolchain in use.
    for (final MapEntry(key: dir, value: wanted) in overrides.entries) {
      if (overridden.contains(dir) || !Sys.dirExists(dir)) continue;
      itemFor(wanted)?.usedBy.add(UsageRef(name: p.basename(dir), path: dir, kind: 'folder', note: 'rustup override'));
    }
    return snap;
  }

  @override
  PlannedChange? planRemove(InstalledItem item) {
    final name = item.details['Toolchain'];
    // Rust that Get tools installed is removed as a whole, with its variables.
    if (name == null) return super.planRemove(item);
    if (_rustup == null || _home == null) return null;
    return PlannedChange(
      title: 'Uninstall Rust ${item.title}',
      commands: [
        CommandSpec(title: 'Uninstall it with rustup', executable: _rustup!, arguments: ['toolchain', 'uninstall', name], environment: {'RUSTUP_HOME': _home!}),
      ],
      // The remove dialog already says when it's the default or in use.
      warning: item.details.containsKey('Linked to') ? 'Only rustup\'s link is removed. The folder it points to stays.' : null,
    );
  }

  /// Splits a rustup toolchain name into its channel (with any date) and host:
  /// "nightly-2024-05-01-x86_64-pc-windows-msvc" is ("nightly-2024-05-01", "x86_64-pc-windows-msvc").
  /// Names of linked toolchains don't follow the pattern and come back whole.
  static (String, String?) splitToolchain(String name) {
    final m = RegExp(r'^(stable|beta|nightly|\d+\.\d+(?:\.\d+)?(?:-beta(?:\.\d+)?)?)(-\d{4}-\d{2}-\d{2})?(?:-(.+))?$').firstMatch(name);
    return m == null ? (name, null) : ('${m[1]}${m[2] ?? ''}', m[3]);
  }

  /// The installed toolchain rustup runs for [wanted] ("stable", "1.80.0",
  /// "nightly-2024-05-01-aarch64-apple-darwin"). Without a host in [wanted],
  /// rustup uses its own [host]; a build for another host only counts when that
  /// one isn't installed, so a toolchain in use is never shown as unused.
  static String? matchToolchain(Iterable<String> installed, String wanted, {String? host}) {
    final (channel, wantedHost) = splitToolchain(wanted);
    final matches = installed.where((name) {
      final (c, h) = splitToolchain(name);
      return name == wanted || (c == channel && (wantedHost == null || h == wantedHost));
    }).toList();
    return matches.where((name) => name == wanted).firstOrNull ?? matches.where((name) => splitToolchain(name).$2 == host).firstOrNull ?? matches.firstOrNull;
  }

  /// Folders set with `rustup override set` and their toolchains, from the
  /// [overrides] table in rustup's settings.toml.
  static Map<String, String> overridesIn(String settings) {
    // Keys and values are TOML strings: "C:\\code\\app" (escaped) or 'C:\code\app' (literal).
    const str = r'''(?:"((?:[^"\\]|\\.)*)"|'([^']*)')''';
    final entry = RegExp('^\\s*$str\\s*=\\s*$str');
    String unescape(String s) => s.replaceAllMapped(RegExp(r'\\(.)'), (m) => m[1]!);
    final overrides = <String, String>{};
    var inTable = false;
    for (final line in const LineSplitter().convert(settings)) {
      if (line.trimLeft().startsWith('[')) {
        inTable = line.trim() == '[overrides]';
      } else if (inTable) {
        if (entry.firstMatch(line) case final m?) overrides[m[1] != null ? unescape(m[1]!) : m[2]!] = m[3] != null ? unescape(m[3]!) : m[4]!;
      }
    }
    return overrides;
  }

  /// The override on [path] itself or on the closest folder above it.
  static MapEntry<String, String>? _overrideFor(Map<String, String> overrides, String path) {
    final project = Sys.canonical(path);
    MapEntry<String, String>? best;
    var depth = -1;
    for (final e in overrides.entries) {
      final dir = Sys.canonical(e.key);
      final hit = dir == project || p.isWithin(dir, project);
      if (hit && dir.length > depth) (best, depth) = (e, dir.length);
    }
    return best;
  }
}
