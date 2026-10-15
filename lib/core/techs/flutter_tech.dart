import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../models.dart';
import '../semver.dart';
import '../sys.dart';
import 'tech.dart';

class FlutterTech extends TechAdapter {
  @override
  final info = const TechInfo(
    id: 'flutter',
    name: 'Flutter',
    kind: TechKind.toolchain,
    color: Color(0xFF02569B),
    monogram: 'Fl',
    logo: 'assets/tech/flutter.svg',
  );

  String? _fvm;

  List<VersionOption>? _releases;

  String get _fvmDir => Sys.env['FVM_CACHE_PATH'] != null ? Sys.env['FVM_CACHE_PATH']! : p.join(Sys.home, 'fvm');

  @override
  Future<TechSnapshot?> detect(ScanContext ctx) async {
    _fvm = Sys.which('fvm');
    final items = <InstalledItem>[];
    String manager = 'Flutter SDK';

    // FVM-managed versions.
    final versionsDir = p.join(_fvmDir, 'versions');
    final defaultTarget = Sys.linkTarget(p.join(_fvmDir, 'default'));
    if (_fvm != null) {
      final ver = await Sys.run(_fvm!, ['--version']);
      manager = 'FVM ${ver ?? ''}'.trim();
      final listJson = await Sys.run(_fvm!, ['api', 'list'], timeout: const Duration(seconds: 30));
      final decoded = _tryJson(listJson);
      for (final v in (decoded?['versions'] as List? ?? [])) {
        final dir = v['directory'] as String;
        items.add(
          _item(
            name: v['name'] as String,
            dir: dir,
            dart: v['dartSdkVersion'] as String?,
            sdkVersion: v['flutterSdkVersion'] as String?,
            isGlobal: _samePath(dir, defaultTarget),
            setUp: v['isSetup'] == true,
          ),
        );
      }
    }
    if (items.isEmpty && Sys.dirExists(versionsDir)) {
      if (_fvm == null) manager = 'FVM cache';
      for (final d in Sys.subdirs(versionsDir)) {
        items.add(_item(name: p.basename(d.path), dir: d.path, isGlobal: _samePath(d.path, defaultTarget)));
      }
    }

    // A Flutter on PATH that FVM doesn't manage (e.g. C:\src\flutter).
    final onPath = Sys.which('flutter');
    if (onPath != null) {
      // Homebrew links bin/flutter from a shared bin folder; follow the link to the SDK.
      var real = onPath;
      try {
        real = File(onPath).resolveSymbolicLinksSync();
      } catch (_) {}
      final root = Sys.linkTarget(p.dirname(p.dirname(real))) ?? p.dirname(p.dirname(real));
      final managed = items.any((i) => _samePath(i.path, root)) || p.isWithin(_fvmDir.toLowerCase(), root.toLowerCase());
      final isSdk = Sys.dirExists(p.join(root, 'packages', 'flutter_tools'));
      if (!managed && isSdk) {
        final version = _readSdkVersion(root) ?? 'unknown';
        items.add(_item(name: version, dir: root, label: '$version (standalone)', group: 'Standalone', isGlobal: !items.any((i) => i.isGlobal)));
      }
    }
    if (items.isEmpty) return null;
    items.sort((a, b) => compareVersions(b.version, a.version));

    final snap = TechSnapshot(managerLabel: manager, items: items);
    _link(snap, ctx);
    return snap;
  }

  InstalledItem _item({
    required String name,
    required String dir,
    String? dart,
    String? sdkVersion,
    String? label,
    String group = 'Versions',
    bool isGlobal = false,
    bool setUp = true,
  }) {
    final defaults = _sdkDefaults(dir);
    return InstalledItem(
      id: 'flutter:${dir.toLowerCase()}',
      version: name,
      label: label,
      path: dir,
      group: group,
      isGlobal: isGlobal,
      installedAt: Sys.modified(dir),
      details: {
        if (sdkVersion != null && sdkVersion != name) 'Flutter': sdkVersion,
        if (dart != null) 'Dart': dart,
        if (defaults['compileSdk'] != null) 'Default compileSdk': defaults['compileSdk']!,
        if (defaults['ndk'] != null) 'Default NDK': defaults['ndk']!,
        if (!setUp) 'Setup': 'Not finished',
      },
    );
  }

  void _link(TechSnapshot snap, ScanContext ctx) {
    final global = snap.items.where((i) => i.isGlobal).firstOrNull;
    for (final project in ctx.projects.where((pr) => pr.types.contains('flutter'))) {
      final pin = project.pins['flutter'];
      InstalledItem? target;
      String? note;
      if (pin != null) {
        target = snap.items.where((i) => i.version == pin.raw).firstOrNull ?? snap.items.where((i) => i.details['Flutter'] == pin.raw).firstOrNull;
        if (target == null) {
          snap.problem('${project.name} pins Flutter ${pin.raw}, which isn\'t installed, so it won\'t build until it is.', [
            if (canInstall) NoteFix('Install Flutter ${pin.raw}', planInstall(pin.raw)!, recommended: true),
          ]);
        }
      } else {
        target = global;
        note = 'No pin, uses global';
      }
      if (target == null) continue;
      target.usedBy.add(project.toUsage(note: note));
      ctx.flutterSdkForProject[project.path] = target.path;
      snap.projects.add(project);
    }
  }

  @override
  String? projectVersion(Project project) => project.pins['flutter']?.raw ?? (project.types.contains('flutter') ? 'global' : null);

  /// compileSdk / NDK defaults baked into a Flutter SDK's Gradle plugin.
  static Map<String, String?> sdkDefaults(String sdk) => _sdkDefaults(sdk);

  static final _defaultsCache = <String, Map<String, String?>>{};
  static Map<String, String?> _sdkDefaults(String sdk) {
    return _defaultsCache.putIfAbsent(sdk, () {
      final base = p.join(sdk, 'packages', 'flutter_tools', 'gradle', 'src', 'main');
      final source =
          Sys.readText(p.join(base, 'kotlin', 'FlutterExtension.kt')) ??
          Sys.readText(p.join(base, 'groovy', 'flutter.groovy')) ??
          Sys.readText(p.join(base, 'groovy', 'flutter_extension.groovy')) ??
          '';
      return {
        'compileSdk': RegExp(r'compileSdkVersion(?:\s*:\s*Int)?\s*=\s*(\d+)').firstMatch(source)?[1],
        'ndk': RegExp(r'''ndkVersion(?:\s*:\s*String)?\s*=\s*"([^"]+)"''').firstMatch(source)?[1],
      };
    });
  }

  static String? _readSdkVersion(String root) {
    final json = Sys.readJson(p.join(root, 'bin', 'cache', 'flutter.version.json'));
    final v = json?['frameworkVersion'] ?? json?['flutterVersion'];
    if (v is String) return v;
    return Sys.readText(p.join(root, 'version'))?.trim();
  }

  static bool _samePath(String a, String? b) => b != null && p.equals(p.normalize(a).toLowerCase(), p.normalize(b).toLowerCase());

  static Map<String, dynamic>? _tryJson(String? s) {
    if (s == null) return null;
    final start = s.indexOf('{');
    if (start < 0) return null;
    try {
      return jsonDecode(s.substring(start)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  // ---- Upstream releases ----

  @override
  Future<List<VersionOption>> availableVersions() async {
    if (_releases != null) return _releases!;
    final os = Platform.isMacOS
        ? 'macos'
        : Platform.isLinux
        ? 'linux'
        : 'windows';
    final res = await http
        .get(Uri.parse('https://storage.googleapis.com/flutter_infra_release/releases/releases_$os.json'))
        .timeout(const Duration(seconds: 15));
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final latestStableHash = data['current_release']?['stable'];
    final seen = <String>{};
    final list = <VersionOption>[];
    for (final r in data['releases'] as List) {
      final channel = r['channel'] as String;
      if (channel != 'stable' && channel != 'beta') continue;
      final version = r['version'] as String;
      if (!seen.add(version)) continue;
      list.add(
        VersionOption(
          version: version,
          channel: channel,
          date: DateTime.tryParse(r['release_date'] ?? ''),
          isLatest: r['hash'] == latestStableHash,
          note: r['dart_sdk_version'] != null ? 'Dart ${r['dart_sdk_version']}' : null,
        ),
      );
    }
    return _releases = list;
  }

  @override
  Future<String?> latestVersion() async {
    final list = await availableVersions();
    return list.where((v) => v.isLatest).firstOrNull?.version ?? list.where((v) => v.channel == 'stable').firstOrNull?.version;
  }

  // ---- Actions ----

  @override
  bool get canInstall => _fvm != null;

  @override
  String get stackInstallHint => 'Needs FVM, the Flutter version manager (fvm.app).';

  @override
  PlannedChange? planInstall(String version) {
    if (_fvm == null) return null;
    return PlannedChange(
      title: 'Install Flutter $version',
      commands: [
        CommandSpec(title: 'Download and set up Flutter $version', executable: _fvm!, arguments: ['install', version]),
      ],
    );
  }

  @override
  bool canSetGlobal(InstalledItem item) => _fvm != null && item.group == 'Versions' && !item.isGlobal;

  @override
  PlannedChange? planSetGlobal(InstalledItem item) => PlannedChange(
    title: 'Make Flutter ${item.version} the global version',
    commands: [
      CommandSpec(title: 'Set global version', executable: _fvm!, arguments: ['global', item.version]),
    ],
  );
}
