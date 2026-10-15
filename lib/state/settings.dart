import 'dart:convert';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:path/path.dart' as p;

import '../core/settings_defaults.dart';
import '../core/sys.dart';

/// User preferences, saved as JSON next to the size cache.
class Settings extends ChangeNotifier {
  Settings._(this._file);

  /// Settings that are never written to disk (tests, previews).
  Settings.memory() : _file = null {
    onboarded = true;
  }

  final File? _file;

  List<String> roots = [];
  ThemeMode themeMode = ThemeMode.system;
  /// How much the desktop shows through the window, 0–100 (0 = solid).
  /// Mica on Windows 11, the sidebar material on macOS.
  int glass = 50;
  bool get mica => glass > 0;

  /// The first-run setup (project folders) is done. Existing users skip it.
  bool onboarded = false;
  bool reduceMotion = false;
  int scanDepth = 5;

  /// Closing the window keeps Stackyard in the tray / menu bar.
  bool runInBackground = true;

  /// How often the background check runs: 'daily', 'weekly' or 'off'.
  String checkEvery = 'weekly';

  /// When the last full check finished (ms since epoch).
  int lastCheckAt = 0;

  /// What the last notification was about, so the same news isn't repeated.
  String lastAlert = '';

  /// The "still running in the tray" tip has been shown once.
  bool trayTipShown = false;

  /// Where the marketplace installs tools: `<installRoot>/<tool>/<version>`.
  String installRoot = p.join(Sys.home, 'sdks');

  /// What the marketplace installed: {tool, version, dest, scope}.
  List<Map<String, String>> installs = [];

  Duration? get checkInterval => switch (checkEvery) {
    'daily' => const Duration(days: 1),
    'weekly' => const Duration(days: 7),
    _ => null,
  };

  /// path -> bytes, so sizes show instantly on the next launch.
  Map<String, int> sizeCache = {};

  /// path -> [folder modified ms, measured at ms]: lets a launch skip
  /// re-measuring folders that haven't changed.
  Map<String, List<int>> sizeMeta = {};

  /// Bump when sizes from older builds can't be trusted; their cache is dropped.
  static const sizeCacheVersion = 2;

  static Directory get dataDir {
    final base = Platform.isMacOS ? p.join(Sys.home, 'Library', 'Application Support', 'Stackyard') : p.join(Sys.appData, 'Stackyard');
    return Directory(base)..createSync(recursive: true);
  }

  static Future<Settings> load() async {
    final file = File(p.join(dataDir.path, 'settings.json'));
    final s = Settings._(file);
    try {
      if (file.existsSync()) {
        final j = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        s.roots = (j['roots'] as List?)?.cast<String>() ?? [];
        s.themeMode = ThemeMode.values.byName(j['themeMode'] ?? 'system');
        // Before the slider, glass was on/off ("mica").
        s.glass = j['glass'] ?? ((j['mica'] ?? true) ? 50 : 0);
        s.onboarded = j['onboarded'] ?? true;
        s.reduceMotion = j['reduceMotion'] ?? false;
        s.scanDepth = j['scanDepth'] ?? 5;
        s.runInBackground = j['runInBackground'] ?? true;
        s.checkEvery = j['checkEvery'] ?? 'weekly';
        s.lastCheckAt = j['lastCheckAt'] ?? 0;
        s.lastAlert = j['lastAlert'] ?? '';
        s.trayTipShown = j['trayTipShown'] ?? false;
        s.installRoot = j['installRoot'] ?? s.installRoot;
        s.installs = [for (final i in (j['installs'] as List? ?? const [])) (i as Map).cast<String, String>()];
        s.sizeCache = (j['sizeCache'] as Map?)?.map((k, v) => MapEntry(k as String, v as int)) ?? {};
        s.sizeMeta = (j['sizeMeta'] as Map?)?.map((k, v) => MapEntry(k as String, (v as List).cast<int>())) ?? {};
        if (j['sizeCacheVersion'] != sizeCacheVersion) {
          s.sizeCache = {};
          s.sizeMeta = {};
        }
      }
    } catch (_) {}
    if (s.roots.isEmpty) s.roots = defaultProjectRoots();
    return s;
  }

  Future<void> save() async {
    final file = _file;
    if (file == null) return;
    try {
      await file.writeAsString(
        jsonEncode({
          'roots': roots,
          'themeMode': themeMode.name,
          'glass': glass,
          'onboarded': onboarded,
          'reduceMotion': reduceMotion,
          'scanDepth': scanDepth,
          'runInBackground': runInBackground,
          'checkEvery': checkEvery,
          'lastCheckAt': lastCheckAt,
          'lastAlert': lastAlert,
          'trayTipShown': trayTipShown,
          'installRoot': installRoot,
          'installs': installs,
          'sizeCache': sizeCache,
          'sizeMeta': sizeMeta,
          'sizeCacheVersion': sizeCacheVersion,
        }),
      );
    } catch (_) {}
  }

  void update(void Function(Settings s) change) {
    change(this);
    notifyListeners();
    save();
  }

  /// Applies a change without saving yet (a slider being dragged); [update] saves it.
  void preview(void Function(Settings s) change) {
    change(this);
    notifyListeners();
  }
}
