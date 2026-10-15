import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'installers.dart';
import 'models.dart';
import 'semver.dart';
import 'sys.dart';
import 'techs/android_tech.dart';

/// A problem with the machine's setup rather than one tech, plus its fixes.
typedef SystemIssue = ({String text, List<NoteFix> fixes});

/// Looks for setup problems that quietly break builds and attaches each one,
/// with a fix, to the tech it belongs to (or returns it as a system issue).
class Doctor {
  Doctor(this.snapshotOf, this.projects);

  /// The last scan's result for a tech id, if that tech was found.
  final TechSnapshot? Function(String id) snapshotOf;
  final List<Project> projects;

  final _system = <SystemIssue>[];

  Future<List<SystemIssue>> run() async {
    _system.clear();
    if (Sys.isWindows) {
      final scopes = await _readScopes();
      _checkHomes(scopes);
      _system.addAll(_checkPath(scopes));
    }
    await _checkAndroidJava();
    return List.of(_system);
  }

  /// Shows a problem on its tech's page, or as a system issue when that tech wasn't found.
  void _report(TechSnapshot? snap, String text, List<NoteFix> fixes) {
    if (snap != null) {
      snap.problem(text, fixes);
    } else {
      _system.add((text: text, fixes: fixes));
    }
  }

  // ---- Environment variables (Windows) ----

  /// The user's and the machine's variables as stored (unexpanded).
  Future<Map<_Scope, Map<String, String>>> _readScopes() async {
    final value = RegExp(r'^ {4}(\S.*?) {4}(REG_SZ|REG_EXPAND_SZ) {4}(.*)$');
    Future<Map<String, String>> read(String key) async => {
      for (final line in const LineSplitter().convert(await Sys.run('reg.exe', ['query', key]) ?? ''))
        if (value.firstMatch(line) case final m?) m[1]!.toUpperCase(): m[3]!,
    };
    return {_Scope.user: await read(r'HKCU\Environment'), _Scope.machine: await read(r'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment')};
  }

  static String _expand(String s) => s.replaceAllMapped(RegExp(r'%([^%]+)%'), (m) => Sys.env[m[1]!] ?? m[0]!);

  void _checkHomes(Map<_Scope, Map<String, String>> scopes) {
    final java = snapshotOf('java');
    final android = snapshotOf('android');
    for (final scope in _Scope.values) {
      final vars = scopes[scope]!;

      if (vars['JAVA_HOME'] case final raw?) {
        final home = _expand(raw);
        if (FileSystemEntity.typeSync(p.join(home, 'bin', 'java.exe')) == FileSystemEntityType.notFound) {
          final best = _bestJdk(java);
          final text = Sys.dirExists(home)
              ? 'JAVA_HOME points to $home, which has no Java in it, so tools that read JAVA_HOME (Gradle, Maven) can\'t start.'
              : 'JAVA_HOME points to $home, which doesn\'t exist anymore, so tools that read JAVA_HOME (Gradle, Maven) can\'t start.';
          _report(java ?? android, text, [
            if (best != null) NoteFix('Point it to JDK ${javaMajor(best.version)}', _setVar('JAVA_HOME', best.home, scope), recommended: true),
            NoteFix('Remove JAVA_HOME', _setVar('JAVA_HOME', null, scope), recommended: best == null),
          ]);
        }
      }

      for (final name in ['ANDROID_HOME', 'ANDROID_SDK_ROOT']) {
        final raw = vars[name];
        if (raw == null) continue;
        final dir = _expand(raw);
        if (Sys.dirExists(p.join(dir, 'platform-tools')) || Sys.dirExists(p.join(dir, 'platforms'))) continue;
        final sdk = AndroidTech.findSdks().where((s) => Sys.dirExists(p.join(s, 'platform-tools'))).firstOrNull;
        _report(
          android,
          '$name points to $dir, which ${Sys.dirExists(dir) ? 'isn\'t an Android SDK' : 'doesn\'t exist anymore'}. '
          'Gradle and Flutter read it to find the SDK, so Android builds can fail.',
          [
            if (sdk != null) NoteFix('Point it to $sdk', _setVar(name, sdk, scope), recommended: true),
            NoteFix('Remove $name', _setVar(name, null, scope), recommended: sdk == null),
          ],
        );
      }
    }
  }

  /// Sets (or with null, removes) a variable for the user or the whole machine.
  static PlannedChange _setVar(String name, String? value, _Scope scope) {
    final target = scope == _Scope.user ? 'User' : 'Machine';
    final v = value == null ? r'$null' : "'${value.replaceAll("'", "''")}'";
    return PlannedChange(
      title: value == null ? 'Remove $name' : 'Set $name',
      commands: [
        CommandSpec(
          title: value == null ? 'Remove $name (${target.toLowerCase()} setting)' : 'Set $name to $value (${target.toLowerCase()} setting)',
          executable: 'powershell.exe',
          arguments: ['-NoProfile', '-NonInteractive', '-Command', "[Environment]::SetEnvironmentVariable('$name', $v, '$target')"],
          needsAdmin: scope == _Scope.machine,
        ),
      ],
      warning: 'Apps and terminals you open from now on see the change. Ones already open keep the old value until restarted.',
    );
  }

  List<SystemIssue> _checkPath(Map<_Scope, Map<String, String>> scopes) {
    final issues = <SystemIssue>[];
    String key(String entry) => p.normalize(_expand(entry)).toLowerCase();
    final inSystem = {
      for (final e in (scopes[_Scope.machine]!['PATH'] ?? '').split(';'))
        if (e.trim().isNotEmpty) key(e.trim()),
    };
    // System first: Windows puts the system PATH before the user's.
    for (final scope in [_Scope.machine, _Scope.user]) {
      final raw = scopes[scope]!['PATH'];
      if (raw == null) continue;
      final seen = <String>{};
      final dead = <String>[];
      final repeats = <String>[];
      final alsoInSystem = <String>[];
      for (final entry in raw.split(';').map((e) => e.trim()).where((e) => e.isNotEmpty)) {
        final dir = _expand(entry);
        // Can't judge entries with unknown variables, or on a drive that isn't plugged in.
        if (dir.contains('%')) continue;
        final drive = RegExp(r'^[A-Za-z]:\\').firstMatch(dir)?[0];
        if (drive != null && _exists(drive) != true) continue;
        if (!seen.add(key(entry))) {
          repeats.add(entry);
        } else if (scope == _Scope.user && inSystem.contains(key(entry))) {
          alsoInSystem.add(entry);
        } else if (_exists(dir) == false) {
          dead.add(entry);
        }
      }
      if (dead.isEmpty && repeats.isEmpty && alsoInSystem.isEmpty) continue;
      final who = scope == _Scope.user ? 'Your' : 'The system';
      String n(int count, String one, String many) => '$count ${count == 1 ? one : many}';
      final parts = [
        if (dead.isNotEmpty) '${n(dead.length, 'folder that doesn\'t', 'folders that don\'t')} exist anymore',
        if (repeats.isNotEmpty) n(repeats.length, 'folder listed twice', 'folders listed twice'),
        if (alsoInSystem.isNotEmpty) n(alsoInSystem.length, 'folder already in the system PATH', 'folders already in the system PATH'),
      ];
      issues.add((
        text:
            '$who PATH has ${parts.join(', ')}. Every command searches through them, and leftovers from '
            'uninstalled tools can make the wrong version of a tool run.',
        fixes: [
          NoteFix(
            'Clean up PATH',
            cleanPathAt(
              scope == _Scope.user ? r'HKCU:\Environment' : r'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment',
              machine: scope == _Scope.machine,
              missing: dead,
              repeats: repeats,
              alsoInSystem: alsoInSystem,
            ),
            recommended: true,
          ),
        ],
      ));
    }
    return issues;
  }

  /// Whether a folder exists; null when Windows won't let us look (then it can't be judged).
  static bool? _exists(String dir) {
    try {
      return Directory(dir).existsSync();
    } catch (_) {
      return null;
    }
  }

  /// Removes exact entries from the PATH stored under [key], keeping a backup of
  /// the old value. (Public so tests can aim it at a scratch registry key.)
  static PlannedChange cleanPathAt(
    String key, {
    required bool machine,
    List<String> missing = const [],
    List<String> repeats = const [],
    List<String> alsoInSystem = const [],
    String? backupTo,
  }) {
    final scope = machine ? _Scope.machine : _Scope.user;
    final backup = backupTo ?? p.join(Sys.appData, 'Stackyard', 'path-backup-${scope.name}-${DateTime.now().millisecondsSinceEpoch}.txt');
    String q(String s) => "'${s.replaceAll("'", "''")}'";
    final count = missing.length + repeats.length + alsoInSystem.length;
    // Read the stored value (not expanded), save it, drop the listed entries and any
    // folder already listed earlier (compared after expanding %VARS%), write it back
    // as the same type, and tell Windows.
    final script = [
      '\$k = Get-Item ${q(key)}',
      "\$raw = \$k.GetValue('Path', '', 'DoNotExpandEnvironmentNames')",
      'New-Item -ItemType Directory -Force (Split-Path ${q(backup)}) | Out-Null',
      'Set-Content -LiteralPath ${q(backup)} -Value \$raw',
      '\$drop = @(${[...missing, ...alsoInSystem].map(q).join(',')})',
      '\$seen = @{}',
      '\$keep = foreach (\$e in \$raw -split \';\') { \$t = \$e.Trim(); if (-not \$t) { continue }; '
          '\$n = [Environment]::ExpandEnvironmentVariables(\$t).TrimEnd(\'\\\').ToLower(); '
          'if (\$drop -contains \$t -or \$seen.ContainsKey(\$n)) { continue }; \$seen[\$n] = 1; \$t }',
      "Set-ItemProperty -Path ${q(key)} -Name Path -Value (\$keep -join ';') -Type ExpandString",
      "[Environment]::SetEnvironmentVariable('STACKYARD_REFRESH', '1', '${scope == _Scope.user ? 'User' : 'Machine'}')",
      "[Environment]::SetEnvironmentVariable('STACKYARD_REFRESH', \$null, '${scope == _Scope.user ? 'User' : 'Machine'}')",
    ].join('; ');
    return PlannedChange(
      title: 'Clean up ${scope == _Scope.user ? 'your' : 'the system'} PATH',
      commands: [
        CommandSpec(
          title: 'Remove $count entr${count == 1 ? 'y' : 'ies'} from PATH',
          executable: 'powershell.exe',
          arguments: ['-NoProfile', '-NonInteractive', '-Command', script],
          needsAdmin: scope == _Scope.machine,
        ),
      ],
      warning: [
        if (missing.isNotEmpty) 'Folders that no longer exist: ${missing.join('; ')}.',
        if (repeats.isNotEmpty) 'Second copies of folders listed earlier (the first copy stays): ${repeats.join('; ')}.',
        if (alsoInSystem.isNotEmpty) 'Copies of folders the system PATH already has (no effect here): ${alsoInSystem.join('; ')}.',
        'The old PATH is saved to $backup first.',
      ].join('\n'),
    );
  }

  // ---- Java for Flutter's Android builds (all platforms) ----

  Future<void> _checkAndroidJava() async {
    final flutterApps = projects.where((pr) => pr.types.contains('flutter') && pr.types.contains('android')).toList();
    final android = snapshotOf('android');
    if (flutterApps.isEmpty || android == null) return;
    final (home: jdk, from: from) = _flutterJdk();
    if (jdk == null) return;
    final major = _jdkMajor(jdk);
    if (major == null) return;

    // Which Java each app can build with: from its Android Gradle Plugin (minimum)
    // and its Gradle wrapper (maximum).
    final needs = <Project, ({int min, int max, String why})>{};
    for (final app in flutterApps) {
      final gradle = RegExp(r'gradle-(\d+(?:\.\d+)*)').firstMatch(app.buildInfo['gradle'] ?? '')?[1];
      final agp = _agpVersion(p.join(app.path, 'android'));
      final min = agp == null ? 8 : minJavaForAgp(agp);
      final max = gradle == null ? 99 : maxJavaForGradle(gradle);
      needs[app] = (min: min, max: max, why: [if (gradle != null) 'Gradle $gradle', if (agp != null) 'Android Gradle Plugin $agp'].join(' and '));
    }
    final broken = needs.entries.where((e) => major < e.value.min || major > e.value.max).toList();
    if (broken.isEmpty) return;

    // A JDK every app accepts, preferring the long-term-support ones.
    final lo = needs.values.map((n) => n.min).reduce((a, b) => a > b ? a : b);
    final hi = needs.values.map((n) => n.max).reduce((a, b) => a < b ? a : b);
    final jdks = _installedJdks();
    final fits = jdks.where((j) => j.major >= lo && j.major <= hi).toList()..sort((a, b) => _ltsFirst(a.major).compareTo(_ltsFirst(b.major)));
    final target = fits.firstOrNull;
    final wantMajor = [21, 17, 11].firstWhere((v) => v >= lo && v <= hi, orElse: () => lo);

    final names = broken.map((e) => e.key.name).toList();
    final first = broken.first.value;
    final flutter = _flutterExe();
    final install = flutter == null || target != null ? null : _installJdk(wantMajor, flutter);
    android.problem(
      'Android builds of ${_list(names)} will fail: ${broken.length == 1 ? 'it needs' : 'they need'} Java '
      '${first.min}${first.max >= 99 ? '+' : '–${first.max}'} (${first.why}), but Flutter builds with Java $major from $from.',
      [
        if (flutter != null && target != null)
          NoteFix(
            'Build Android with JDK ${target.major}',
            PlannedChange(
              title: 'Build Android apps with JDK ${target.major}',
              commands: [
                CommandSpec(title: 'Point Flutter at JDK ${target.major}', executable: flutter, arguments: ['config', '--jdk-dir', target.home]),
              ],
              warning: 'Applies to all your Flutter apps. Every Flutter app found here builds with JDK ${target.major}.',
            ),
            recommended: true,
          )
        else if (install != null)
          NoteFix('Install JDK $wantMajor and build with it', install, recommended: true),
      ],
    );
  }

  /// The JDK Flutter uses for Android builds, in Flutter's own order of preference.
  static ({String? home, String from}) _flutterJdk() {
    // Flutter's own order: the legacy ~/.flutter_settings if it exists, else the XDG config folder.
    final settingsFile = Sys.isWindows
        ? p.join(Sys.appData, '.flutter_settings')
        : [
            p.join(Sys.home, '.flutter_settings'),
            p.join(Sys.env['XDG_CONFIG_HOME'] ?? p.join(Sys.home, '.config'), 'flutter', 'settings'),
          ].firstWhere(Sys.fileExists, orElse: () => p.join(Sys.home, '.config', 'flutter', 'settings'));
    try {
      final dir = (jsonDecode(File(settingsFile).readAsStringSync()) as Map)['jdk-dir'];
      if (dir is String && Sys.dirExists(dir)) return (home: dir, from: 'flutter config');
    } catch (_) {}
    final studio = Sys.isWindows
        ? [
            for (final pf in [Sys.env['ProgramFiles'] ?? r'C:\Program Files'])
              for (final sub in ['jbr', 'jre']) p.join(pf, 'Android', 'Android Studio', sub),
          ]
        : ['/Applications/Android Studio.app/Contents/jbr/Contents/Home', '/Applications/Android Studio.app/Contents/jre/Contents/Home'];
    for (final s in studio) {
      if (File(p.join(s, 'release')).existsSync()) return (home: s, from: 'Android Studio');
    }
    final javaHome = Sys.env['JAVA_HOME'];
    if (javaHome != null && File(p.join(javaHome, 'release')).existsSync()) return (home: javaHome, from: 'JAVA_HOME');
    final java = Sys.which('java');
    if (java != null) {
      final home = p.dirname(p.dirname(java));
      if (File(p.join(home, 'release')).existsSync()) return (home: home, from: 'your PATH');
    }
    return (home: null, from: '');
  }

  static int? _jdkMajor(String home) {
    try {
      final v = RegExp(r'JAVA_VERSION="([^"]+)"').firstMatch(File(p.join(home, 'release')).readAsStringSync())?[1];
      return v == null ? null : javaMajor(v);
    } catch (_) {
      return null;
    }
  }

  /// "17.0.9" → 17, "1.8.0_392" → 8.
  static int javaMajor(String v) {
    final parts = v.split(RegExp(r'[._+-]'));
    final first = int.tryParse(parts.first) ?? 0;
    return first == 1 && parts.length > 1 ? int.tryParse(parts[1]) ?? 1 : first;
  }

  static int _ltsFirst(int major) => switch (major) {
    17 => 0,
    21 => 1,
    11 => 2,
    _ => 10 + major,
  };

  List<({String home, int major, String version})> _installedJdks() {
    final java = snapshotOf('java');
    return [
      for (final item in java?.items ?? const <InstalledItem>[])
        if (_jdkHome(item.path) case final home?) (home: home, major: javaMajor(item.version), version: item.version),
    ];
  }

  ({String home, String version})? _bestJdk(TechSnapshot? java) {
    final all = _installedJdks();
    if (all.isEmpty) return null;
    all.sort((a, b) => _ltsFirst(a.major).compareTo(_ltsFirst(b.major)));
    final active = java?.items.where((i) => i.isGlobal).firstOrNull;
    final pick = active == null ? all.first : all.firstWhere((j) => j.home.startsWith(active.path), orElse: () => all.first);
    return (home: pick.home, version: pick.version);
  }

  static String? _jdkHome(String path) {
    for (final home in [path, p.join(path, 'Contents', 'Home')]) {
      if (File(p.join(home, 'release')).existsSync()) return home;
    }
    return null;
  }

  /// Installs a JDK with the platform's package manager, then points Flutter at it.
  static PlannedChange? _installJdk(int major, String flutter) {
    final install = Installers.jdk(major);
    if (install == null) return null;
    final point = Sys.isWindows
        ? CommandSpec(
            title: 'Point Flutter at it',
            executable: 'powershell.exe',
            arguments: [
              '-NoProfile',
              '-NonInteractive',
              '-Command',
              "\$j = Get-ChildItem \"\$env:ProgramFiles\\Microsoft\" -Directory -Filter 'jdk-$major*' | Sort-Object Name | Select-Object -Last 1; "
                  "if (-not \$j) { exit 1 }; & '${flutter.replaceAll("'", "''")}' config --jdk-dir \$j.FullName",
            ],
          )
        : CommandSpec(
            title: 'Point Flutter at it',
            executable: '/bin/sh',
            arguments: ['-c', '"$flutter" config --jdk-dir "\$(/usr/libexec/java_home -v $major)"'],
          );
    return PlannedChange(title: 'Install JDK $major for Android builds', commands: [install, point], warning: 'Applies to all your Flutter apps.');
  }

  static String? _flutterExe() {
    final onPath = Sys.which('flutter');
    if (onPath != null) return onPath;
    final fvmDefault = p.join(Sys.home, 'fvm', 'default', 'bin', Sys.isWindows ? 'flutter.bat' : 'flutter');
    return File(fvmDefault).existsSync() ? fvmDefault : null;
  }

  /// The Android Gradle Plugin version, from the plugins block or the old buildscript.
  static String? _agpVersion(String androidRoot) {
    for (final f in ['settings.gradle', 'settings.gradle.kts', 'build.gradle', 'build.gradle.kts']) {
      String text;
      try {
        text = File(p.join(androidRoot, f)).readAsStringSync();
      } catch (_) {
        continue;
      }
      final m =
          RegExp(r'''com\.android\.application["']?\)?\s+version\s+["'](\d+\.\d+(?:\.\d+)?)''').firstMatch(text) ??
          RegExp(r'''com\.android\.tools\.build:gradle:(\d+\.\d+(?:\.\d+)?)''').firstMatch(text);
      if (m != null) return m[1];
    }
    return null;
  }

  /// The newest Java each Gradle version can run on (docs.gradle.org compatibility matrix).
  static int maxJavaForGradle(String gradle) {
    const table = [
      ('8.14', 24),
      ('8.10', 23),
      ('8.8', 22),
      ('8.5', 21),
      ('8.3', 20),
      ('7.6', 19),
      ('7.5', 18),
      ('7.3', 17),
      ('7.0', 16),
      ('6.7', 15),
      ('6.3', 14),
      ('6.0', 13),
      ('5.4', 12),
      ('5.0', 11),
    ];
    for (final (since, java) in table) {
      if (compareVersions(gradle, since) >= 0) return java;
    }
    return 10;
  }

  /// The oldest Java the Android Gradle Plugin accepts.
  static int minJavaForAgp(String agp) => compareVersions(agp, '8.0') >= 0
      ? 17
      : compareVersions(agp, '7.0') >= 0
      ? 11
      : 8;

  static String _list(List<String> names) => names.length <= 1
      ? names.join()
      : names.length == 2
      ? names.join(' and ')
      : '${names.take(2).join(', ')} and ${names.length - 2} more';
}

enum _Scope { user, machine }
