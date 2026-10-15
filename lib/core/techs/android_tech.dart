import 'dart:io';
import 'dart:ui';

import 'package:path/path.dart' as p;

import '../models.dart';
import '../stack_file.dart';
import '../semver.dart';
import '../sys.dart';
import 'flutter_tech.dart';
import 'tech.dart';

/// Android SDK platforms, build tools, NDKs, system images and emulators.
class AndroidTech extends TechAdapter {
  @override
  final info = const TechInfo(
    id: 'android',
    name: 'Android SDK',
    kind: TechKind.toolchain,
    color: Color(0xFF3DDC84),
    monogram: 'A',
    logo: 'assets/tech/android.svg',
    logoTint: LogoTint.brand,
  );

  String? _sdkManager;

  /// Needs each Flutter project's SDK to resolve flutter.compileSdkVersion / ndkVersion.
  @override
  List<String> get dependsOn => const ['flutter'];

  /// Every Android SDK folder on the machine; the first is the active one.
  static List<String> findSdks() {
    final seen = <String>{};
    return [
      for (final c in [
        Sys.env['ANDROID_HOME'],
        Sys.env['ANDROID_SDK_ROOT'],
        p.join(Sys.localAppData, 'Android', 'Sdk'),
        p.join(Sys.home, 'Library', 'Android', 'sdk'),
      ])
        if (c != null && Sys.dirExists(c) && seen.add(p.normalize(c).toLowerCase())) c,
    ];
  }

  static bool _same(String a, String b) => p.normalize(a).toLowerCase() == p.normalize(b).toLowerCase();

  @override
  Future<TechSnapshot?> detect(ScanContext ctx) async {
    final sdks = findSdks();
    final sdk = sdks.firstOrNull;
    final avdDir = Sys.env['ANDROID_AVD_HOME'] ?? p.join(Sys.home, '.android', 'avd');
    if (sdk == null && !Sys.dirExists(avdDir)) return null;

    final items = <InstalledItem>[];
    // Extra SDK folders: used only if a project's local.properties points at them.
    for (final other in sdks.skip(1)) {
      final item = InstalledItem(
        id: 'android:sdk:${other.toLowerCase()}',
        version: other,
        label: 'Android SDK at $other',
        path: other,
        group: 'Other SDK folders',
        installedAt: Sys.modified(other),
        details: {
          'Note':
              'A second SDK. ANDROID_HOME points to $sdk. Before removing, check that '
              'Android Studio → Settings → Android SDK doesn\'t point here.',
        },
      );
      for (final project in ctx.projects) {
        final dir = project.buildInfo['sdkDir'];
        if (dir != null && _same(dir, other)) item.usedBy.add(project.toUsage(note: 'sdk.dir in local.properties'));
      }
      items.add(item);
    }
    if (sdk != null) {
      final sm = p.join(sdk, 'cmdline-tools', 'latest', 'bin', Sys.isWindows ? 'sdkmanager.bat' : 'sdkmanager');
      _sdkManager = Sys.fileExists(sm) ? sm : null;

      for (final d in Sys.subdirs(p.join(sdk, 'platforms'))) {
        final api = p.basename(d.path).replaceFirst('android-', '');
        items.add(
          InstalledItem(
            id: 'android:platform:$api',
            version: api,
            label: 'Android API $api',
            path: d.path,
            group: 'Platforms',
            installedAt: Sys.modified(d.path),
          ),
        );
      }
      for (final d in Sys.subdirs(p.join(sdk, 'build-tools'))) {
        final v = p.basename(d.path);
        items.add(
          InstalledItem(
            id: 'android:build-tools:$v',
            version: v,
            label: 'Build tools $v',
            path: d.path,
            group: 'Build tools',
            usageTracked: false,
            installedAt: Sys.modified(d.path),
            details: {'Note': 'Android Gradle Plugin picks build tools on its own unless a project pins one.'},
          ),
        );
      }
      for (final d in Sys.subdirs(p.join(sdk, 'ndk'))) {
        final v = p.basename(d.path);
        items.add(InstalledItem(id: 'android:ndk:$v', version: v, label: 'NDK $v', path: d.path, group: 'NDK', installedAt: Sys.modified(d.path)));
      }
      // system-images/android-34/google_apis_playstore/x86_64
      for (final api in Sys.subdirs(p.join(sdk, 'system-images'))) {
        for (final tag in Sys.subdirs(api.path)) {
          for (final abi in Sys.subdirs(tag.path)) {
            final rel = p.relative(abi.path, from: sdk);
            items.add(
              InstalledItem(
                id: 'android:image:${rel.toLowerCase()}',
                version: p.basename(api.path).replaceFirst('android-', ''),
                label: '${p.basename(api.path)} · ${p.basename(tag.path)} · ${p.basename(abi.path)}',
                path: abi.path,
                group: 'System images',
                installedAt: Sys.modified(abi.path),
              ),
            );
          }
        }
      }
    }

    // Emulators (AVDs).
    if (Sys.dirExists(avdDir)) {
      for (final ini in Directory(avdDir).listSync().whereType<File>().where((f) => f.path.endsWith('.ini'))) {
        final iniText = Sys.readText(ini.path) ?? '';
        final name = p.basenameWithoutExtension(ini.path);
        var avdPath = RegExp(r'^path=(.+)$', multiLine: true).firstMatch(iniText)?[1]?.trim();
        avdPath ??= p.join(avdDir, '$name.avd');
        final config = Sys.readText(p.join(avdPath, 'config.ini')) ?? '';
        final sysdir = RegExp(r'^image\.sysdir\.1\s*=\s*(.+)$', multiLine: true).firstMatch(config)?[1]?.trim();
        final display = RegExp(r'^avd\.ini\.displayname\s*=\s*(.+)$', multiLine: true).firstMatch(config)?[1]?.trim();
        String? cfg(String key) => RegExp('^${RegExp.escape(key)}\\s*=\\s*(.+)\$', multiLine: true).firstMatch(config)?[1]?.trim();
        final api = RegExp(r'android-(\d+)').firstMatch(sysdir ?? '')?[1];
        final imagePath = sysdir == null || sdk == null ? null : p.normalize(p.join(sdk, sysdir));
        final imageMissing = imagePath != null && !Sys.dirExists(imagePath);
        final lastBoot = _lastBoot(avdPath);
        final emulator = InstalledItem(
          id: 'android:avd:${name.toLowerCase()}',
          version: name,
          label: display ?? name.replaceAll('_', ' '),
          path: avdPath,
          extraPaths: [ini.path],
          group: 'Emulators',
          isBroken: imageMissing || !Sys.dirExists(avdPath),
          usageTracked: false,
          lastUsedAt: lastBoot,
          installedAt: Sys.modified(ini.path),
          details: {
            if (cfg('hw.device.name') case final device?) 'Device': device.replaceAll('_', ' '),
            if (api != null) 'Android': androidName(api),
            if (cfg('tag.display') case final tag?) 'Image': tag,
            if (sysdir != null) 'System image': sysdir.replaceAll('\\', '/'),
            if (imageMissing) 'Problem': 'Its system image isn\'t installed, so it can\'t start.',
            'Last started': lastBoot == null ? 'Never' : _ago(lastBoot),
            'AVD': name,
          },
        );
        items.add(emulator);
        if (imagePath != null && !imageMissing) {
          final image = items.where((i) => i.group == 'System images' && p.equals(i.path.toLowerCase(), imagePath.toLowerCase())).firstOrNull;
          image?.usedBy.add(UsageRef(name: emulator.title, path: avdPath, kind: 'emulator', lastActive: lastBoot));
        }
      }
    }
    if (items.isEmpty) return null;
    items.sort((a, b) => compareVersions(b.version, a.version));

    final snap = TechSnapshot(managerLabel: sdk ?? 'Android emulators', items: items);
    _link(snap, ctx);
    return snap;
  }

  void _link(TechSnapshot snap, ScanContext ctx) {
    for (final project in ctx.projects.where((pr) => pr.types.contains('android'))) {
      final flutterSdk = ctx.flutterSdkForProject[project.path];
      final defaults = flutterSdk == null ? const <String, String?>{} : FlutterTech.sdkDefaults(flutterSdk);
      var used = false;

      var compile = project.buildInfo['compileSdk'];
      String? compileNote;
      if (compile == 'flutter') {
        compile = defaults['compileSdk'];
        compileNote = 'compileSdk from Flutter';
      }
      if (compile != null) {
        final platform = snap.items.where((i) => i.group == 'Platforms' && i.version == compile).firstOrNull;
        if (platform != null) {
          platform.usedBy.add(project.toUsage(note: compileNote));
          used = true;
        } else {
          snap.problem('${project.name} builds against Android API $compile, which isn\'t installed.', [
            if (canInstall) NoteFix('Install Android API $compile', planInstall(compile)!, recommended: true),
          ]);
        }
      }

      var ndk = project.buildInfo['ndk'];
      String? ndkNote;
      if (ndk == 'flutter' || (ndk == null && flutterSdk != null)) {
        ndk = defaults['ndk'];
        ndkNote = 'NDK from Flutter';
      }
      if (ndk != null) {
        final item = snap.items.where((i) => i.group == 'NDK' && i.version == ndk).firstOrNull;
        if (item != null) {
          item.usedBy.add(project.toUsage(note: ndkNote));
          used = true;
        }
      }

      final bt = project.buildInfo['buildTools'];
      if (bt != null) {
        final item = snap.items.where((i) => i.group == 'Build tools' && i.version == bt).firstOrNull;
        if (item != null) {
          item.usedBy.add(project.toUsage());
          used = true;
        }
      }
      if (used || compile != null) snap.projects.add(project);
    }
  }

  @override
  String? projectVersion(Project project) {
    final c = project.buildInfo['compileSdk'];
    if (c == null) return null;
    return c == 'flutter' ? 'API (from Flutter)' : 'API $c';
  }

  static DateTime? _lastBoot(String avdPath) {
    // The emulator rewrites these on every launch.
    DateTime? best;
    for (final f in ['hardware-qemu.ini', 'emulator-user.ini', 'multiinstance.lock', 'snapshots']) {
      final m = Sys.modified(p.join(avdPath, f));
      if (m != null && (best == null || m.isAfter(best))) best = m;
    }
    return best;
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inDays >= 365) return '${(d.inDays / 365).floor()} yr ago';
    if (d.inDays >= 30) return '${(d.inDays / 30).floor()} mo ago';
    if (d.inDays >= 1) return '${d.inDays} days ago';
    return 'Today';
  }

  /// "Android 14 (API 34)" for an API level.
  static String androidName(String api) {
    const names = {
      '37': '17',
      '36': '16',
      '35': '15',
      '34': '14',
      '33': '13',
      '32': '12L',
      '31': '12',
      '30': '11',
      '29': '10',
      '28': '9',
      '27': '8.1',
      '26': '8.0',
      '25': '7.1',
      '24': '7.0',
      '23': '6.0',
    };
    final v = names[api];
    return v == null ? 'API $api' : 'Android $v (API $api)';
  }

  // ---- Emulators ----

  /// The emulator program in the active SDK, if it's installed.
  String? get emulatorExe {
    final sdk = findSdks().firstOrNull;
    if (sdk == null) return null;
    final exe = p.join(sdk, 'emulator', Sys.isWindows ? 'emulator.exe' : 'emulator');
    return Sys.fileExists(exe) ? exe : null;
  }

  /// The emulator holds lock files in its folder while it runs.
  static bool isRunning(InstalledItem avd) {
    try {
      return Directory(avd.path).listSync().any((e) => e.path.endsWith('.lock') && p.basename(e.path) != 'multiinstance.lock');
    } catch (_) {
      return false;
    }
  }

  /// Starts an emulator in its own window. [cold] skips the saved snapshot.
  Future<bool> startEmulator(InstalledItem avd, {bool cold = false}) async {
    final exe = emulatorExe;
    final name = avd.details['AVD'];
    if (exe == null || name == null) return false;
    await Process.start(exe, ['-avd', name, if (cold) '-no-snapshot-load'], mode: ProcessStartMode.detached);
    return true;
  }

  /// Saved quick-boot states. They come back on the next normal shutdown.
  static String snapshotsDir(InstalledItem avd) => p.join(avd.path, 'snapshots');

  /// Files that hold what was installed and saved inside the emulator.
  static List<String> userDataFiles(InstalledItem avd) => [
    for (final f in ['userdata-qemu.img', 'userdata-qemu.img.qcow2', 'cache.img', 'cache.img.qcow2'])
      if (Sys.fileExists(p.join(avd.path, f))) p.join(avd.path, f),
    if (Sys.dirExists(snapshotsDir(avd))) snapshotsDir(avd),
  ];

  /// Like Android Studio's "Wipe Data": the emulator starts fresh from its system image.
  PlannedChange? planWipe(InstalledItem avd) {
    final files = userDataFiles(avd);
    if (files.isEmpty) return null;
    return PlannedChange(
      title: 'Wipe ${avd.title}',
      recycle: files,
      warning: 'Apps, accounts and files inside this emulator are erased. It starts like new next time.',
    );
  }

  PlannedChange? planDeleteSnapshots(InstalledItem avd) {
    if (!Sys.dirExists(snapshotsDir(avd))) return null;
    return PlannedChange(
      title: 'Delete snapshots of ${avd.title}',
      recycle: [snapshotsDir(avd)],
      warning: 'The next start is a full boot. Nothing installed inside the emulator is lost.',
    );
  }

  // ---- Actions ----

  @override
  PlannedChange? planInstallFromStack(StackItem item) {
    if (_sdkManager == null) return null;
    final package = switch (item.kind) {
      'platform' => 'platforms;android-${item.version}',
      'build-tools' => 'build-tools;${item.version}',
      'ndk' => 'ndk;${item.version}',
      'image' => item.version,
      _ => null,
    };
    if (package == null) return null;
    return PlannedChange(
      title: 'Install ${item.label}',
      commands: [
        CommandSpec(title: 'Install $package', executable: _sdkManager!, arguments: [package], runInShell: true),
      ],
    );
  }

  @override
  String get stackInstallHint => 'Needs the Android SDK command-line tools (Android Studio → SDK Manager → SDK Tools).';

  @override
  bool get canInstall => _sdkManager != null;

  @override
  Future<List<VersionOption>> availableVersions() async {
    // Platforms are the common ask; offer recent API levels.
    return [for (var api = 36; api >= 28; api--) VersionOption(version: '$api', note: 'platforms;android-$api')];
  }

  @override
  PlannedChange? planInstall(String version) {
    if (_sdkManager == null) return null;
    return PlannedChange(
      title: 'Install Android API $version',
      commands: [
        CommandSpec(title: 'Install platforms;android-$version', executable: _sdkManager!, arguments: ['platforms;android-$version'], runInShell: true),
      ],
    );
  }

  @override
  PlannedChange? planRemove(InstalledItem item) {
    final base = super.planRemove(item);
    if (base == null) return null;
    if (item.group == 'System images' && item.usedBy.isNotEmpty) {
      return PlannedChange(title: base.title, recycle: base.recycle, warning: '${item.usedBy.length} emulator(s) use this image and will stop working.');
    }
    return base;
  }
}
