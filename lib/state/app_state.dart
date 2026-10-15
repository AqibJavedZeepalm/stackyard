import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:path/path.dart' as p;

import '../core/doctor.dart';
import '../core/installed_apps.dart';
import '../core/market/catalog.dart';
import '../core/market/installed.dart';
import '../core/models.dart';
import '../core/project_junk.dart';
import '../core/project_scanner.dart';
import '../core/registry.dart';
import '../core/semver.dart';
import '../core/sys.dart';
import '../core/techs/android_tech.dart';
import '../core/techs/tech.dart';
import 'jobs.dart';
import 'settings.dart';

/// One detected tech: its adapter plus what the last scan found.
class TechEntry {
  TechEntry(this.adapter, this.snapshot);
  final TechAdapter adapter;
  TechSnapshot snapshot;

  TechInfo get info => adapter.info;
  String get id => adapter.id;

  InstalledItem? get global => snapshot.items.where((i) => i.isGlobal).firstOrNull;

  /// True when upstream has a newer stable than the global version.
  bool get updateAvailable {
    final latest = snapshot.latest, g = global;
    if (latest == null || g == null || info.kind != TechKind.toolchain) return false;
    return compareVersions(latest, g.version) > 0 && !snapshot.items.any((i) => i.version == latest);
  }
}

enum ScanPhase { idle, projects, techs, sizes }

class AppState extends ChangeNotifier {
  AppState(this.settings) {
    jobs = JobQueue(onJobFinished: _onJobFinished);
  }

  final Settings settings;
  late final JobQueue jobs;
  final List<TechAdapter> adapters = buildRegistry();

  /// Everything the marketplace offers. Android tools go into the SDK you already have.
  late final List<MarketTool> catalog = buildCatalog(androidSdkRoot: () => AndroidTech.findSdks().firstOrNull ?? p.join(settings.installRoot, 'android-sdk'));

  MarketTool? marketTool(String id) => catalog.where((t) => t.id == id).firstOrNull;

  /// Global npm packages and their versions, for the marketplace's CLI cards.
  Future<Map<String, String>>? _npmGlobals;

  /// Set by widget tests, which can't wait on real processes.
  @visibleForTesting
  Map<String, String>? npmGlobalsForTest;

  Future<Map<String, String>> npmGlobals() => npmGlobalsForTest != null
      ? Future.value(npmGlobalsForTest)
      : _npmGlobals ??= () async {
          final npm = Sys.which('npm');
          if (npm == null) return <String, String>{};
          final out = await Sys.run(npm, ['ls', '--global', '--depth=0', '--json'], timeout: const Duration(seconds: 30));
          try {
            final deps = (jsonDecode(out ?? '{}') as Map)['dependencies'] as Map? ?? {};
            return {for (final e in deps.entries) e.key as String: ((e.value as Map)['version'] ?? '') as String};
          } catch (_) {
            return <String, String>{};
          }
        }();

  List<TechEntry> techs = [];
  List<Project> projects = [];

  /// Setup problems that don't belong to one tech (e.g. PATH).
  List<SystemIssue> systemIssues = [];

  /// Rebuildable folders (node_modules, build, .gradle…) per project.
  List<ProjectCleanup> cleanups = [];
  int get buildFolderBytes => cleanups.fold(0, (s, c) => s + c.bytes);
  ScanPhase phase = ScanPhase.idle;
  DateTime? lastScan;
  bool _scanQueued = false;

  /// Items removed by a finished job; rows collapse before the rescan lands.
  final Set<String> removedIds = {};

  /// Called with each finished job so the UI can show a notification.
  void Function(Job job)? onJobNotification;

  bool get scanning => phase != ScanPhase.idle && phase != ScanPhase.sizes;
  bool get measuring => phase == ScanPhase.sizes;

  TechEntry? tech(String id) => techs.where((t) => t.id == id).firstOrNull;

  List<TechEntry> get toolchains => techs.where((t) => t.info.kind == TechKind.toolchain).toList();
  List<TechEntry> get frameworks => techs.where((t) => t.info.kind == TechKind.framework).toList();

  Iterable<(TechEntry, InstalledItem)> get allItems sync* {
    for (final t in techs) {
      for (final i in t.snapshot.items) {
        yield (t, i);
      }
    }
  }

  int get totalBytes => techs.fold(0, (s, t) => s + t.snapshot.totalBytes);
  int get reclaimableBytes => techs.fold(0, (s, t) => s + t.snapshot.reclaimableBytes);
  int get cacheBytes => techs.fold(0, (s, t) => s + t.snapshot.cacheBytes);

  List<(TechEntry, InstalledItem)> get quickWins {
    final list = allItems.where((e) => e.$2.reclaimable && !removedIds.contains(e.$2.id)).toList()
      ..sort((a, b) => (b.$2.sizeBytes ?? 0).compareTo(a.$2.sizeBytes ?? 0));
    return list;
  }

  List<(TechEntry, String)> get notes => [
    for (final t in techs)
      for (final n in t.snapshot.notes) (t, n),
  ];

  // ---- Scanning ----

  Future<void> scan({bool quiet = false}) async {
    if (phase != ScanPhase.idle && phase != ScanPhase.sizes) {
      _scanQueued = true;
      return;
    }
    final firstScan = techs.isEmpty;
    // A fix may have just installed or removed something.
    InstalledApps.refresh();
    await Sys.refreshEnvironment();
    phase = ScanPhase.projects;
    notifyListeners();

    try {
      projects = await ProjectScanner.scan(settings.roots, maxDepth: settings.scanDepth);
    } catch (_) {
      projects = [];
    }
    cleanups = [
      for (final project in projects)
        if (findBuildFolders(project) case final folders when folders.isNotEmpty) ProjectCleanup(project, folders),
    ];
    for (final f in cleanups.expand((c) => c.folders)) {
      f.sizeBytes = settings.sizeCache[f.path];
    }
    phase = ScanPhase.techs;
    notifyListeners();

    final ctx = ScanContext(projects);
    final found = <TechEntry>[];
    final order = {for (final (i, a) in adapters.indexed) a.id: i};
    // Detect in parallel; a tech waits only for the techs it depends on.
    final done = <String, Future<void>>{};
    Future<void> detectOne(TechAdapter adapter) async {
      await Future.wait([
        for (final dep in adapter.dependsOn)
          if (done[dep] != null) done[dep]!,
      ]);
      TechSnapshot? snap;
      try {
        snap = await adapter.detect(ctx);
      } catch (e) {
        debugPrint('detect ${adapter.id} failed: $e');
      }
      if (snap == null) return;
      for (final item in snap.items) {
        if (item.path.isNotEmpty) item.sizeBytes = settings.sizeCache[item.path];
      }
      final previous = tech(adapter.id);
      if (previous?.snapshot.latest != null) snap.latest = previous!.snapshot.latest;
      found
        ..add(TechEntry(adapter, snap))
        ..sort((a, b) => order[a.id]!.compareTo(order[b.id]!));
      // First launch: tiles appear (in sidebar order) as each tech is found.
      if (firstScan) {
        techs = List.of(found);
        notifyListeners();
      }
    }

    for (final adapter in adapters) {
      done[adapter.id] = detectOne(adapter);
    }
    await Future.wait(done.values);
    _addMarketInstalls(found);
    // Setup problems (broken JAVA_HOME, dead PATH entries, Java vs Gradle) land on
    // their tech's page; the rest show as system issues.
    try {
      systemIssues = await Doctor((id) => found.where((t) => t.id == id).firstOrNull?.snapshot, projects).run();
    } catch (e) {
      debugPrint('doctor failed: $e');
      systemIssues = [];
    }
    techs = found;
    removedIds.clear();
    lastScan = DateTime.now();
    phase = ScanPhase.sizes;
    notifyListeners();

    unawaited(_fetchLatest());
    await measureSizes();
    if (phase == ScanPhase.sizes) phase = ScanPhase.idle;
    notifyListeners();

    if (_scanQueued) {
      _scanQueued = false;
      unawaited(scan(quiet: true));
    }
  }

  /// Versions the marketplace installed join their tech's page (a new page for
  /// tools Stackyard doesn't otherwise know, like Go). Records of removed ones go.
  void _addMarketInstalls(List<TechEntry> found) {
    final before = settings.installs.length;
    settings.installs.removeWhere((r) => !Sys.dirExists(r['dest'] ?? ''));
    if (settings.installs.length != before) settings.save();
    for (final r in settings.installs) {
      final tool = marketTool(r['tool'] ?? '');
      final techId = tool?.techId;
      if (tool == null || techId == null) continue;
      var entry = found.where((t) => t.id == techId).firstOrNull;
      if (entry == null) {
        entry = TechEntry(MarketOnlyTech(tool), TechSnapshot(managerLabel: 'Installed by Stackyard', items: []));
        found.add(entry);
      }
      final dest = p.normalize(r['dest']!).toLowerCase();
      if (entry.snapshot.items.any((i) => p.normalize(i.path).toLowerCase() == dest)) continue;
      final item = MarketInstalls.item(r, tool)..sizeBytes = settings.sizeCache[r['dest']];
      entry.snapshot.items.insert(0, item);
    }
    _npmGlobals = null;
  }

  /// Folders measured so far / to measure in this pass (for progress UI).
  int measureDone = 0;
  int measureTotal = 0;

  /// A cached size is reused when its folder hasn't changed and it isn't
  /// older than a week. Caches change all the time without touching their
  /// top folder, so they're simply re-measured once a day.
  bool _sizeIsFresh(InstalledItem item) {
    if (item.sizeBytes == null) return false;
    final meta = settings.sizeMeta[item.path];
    if (meta == null || meta.length < 2) return false;
    final age = DateTime.now().millisecondsSinceEpoch - meta[1];
    if (item.isCache) return age < const Duration(days: 1).inMilliseconds;
    final modified = Sys.modified(item.path)?.millisecondsSinceEpoch;
    return modified == meta[0] && age < const Duration(days: 7).inMilliseconds;
  }

  @visibleForTesting
  Future<void> measureSizes() async {
    final buildFolders = {for (final c in cleanups) ...c.folders};
    final todo = [
      for (final (_, item) in allItems)
        if (item.path.isNotEmpty && !_sizeIsFresh(item)) item,
      for (final folder in buildFolders)
        if (!_sizeIsFresh(folder)) folder,
    ];
    // Things you could free first (they drive the headline), caches last.
    int rank(InstalledItem i) => i.isCache
        ? 3
        : i.reclaimable
        ? 0
        : i.sizeBytes == null || buildFolders.contains(i)
        ? 1
        : 2;
    todo.sort((a, b) => rank(a).compareTo(rank(b)));
    measureTotal = todo.length;
    measureDone = 0;
    notifyListeners();
    if (todo.isEmpty) return;

    // Each item is split into sub-folders so big ones (Gradle caches, SDKs)
    // are measured on several cores at once.
    final queue = <Future<void> Function()>[];
    final pending = <InstalledItem, int>{};
    final partial = <InstalledItem, int>{};
    var lastNotify = DateTime.now();

    void finish(InstalledItem item) {
      item.sizeBytes = partial[item] ?? 0;
      settings.sizeCache[item.path] = item.sizeBytes!;
      final modified = Sys.modified(item.path)?.millisecondsSinceEpoch;
      if (modified != null) settings.sizeMeta[item.path] = [modified, DateTime.now().millisecondsSinceEpoch];
      measureDone++;
      if (DateTime.now().difference(lastNotify) > const Duration(milliseconds: 100) || measureDone == measureTotal) {
        lastNotify = DateTime.now();
        notifyListeners();
      }
    }

    for (final item in todo) {
      queue.add(() async {
        try {
          final (bytes, deeper) = await Sys.sizeUnits(item.path);
          partial[item] = bytes;
          if (deeper.isEmpty) return finish(item);
          pending[item] = deeper.length;
          for (final dir in deeper) {
            queue.insert(0, () async {
              try {
                // Await first, then add: reading partial[item] before the await
                // would lose updates from sibling folders finishing meanwhile.
                final bytes = await Sys.dirSize(dir);
                partial[item] = partial[item]! + bytes;
              } catch (_) {}
              pending[item] = pending[item]! - 1;
              if (pending[item] == 0) finish(item);
            });
          }
        } catch (_) {
          finish(item);
        }
      });
    }

    // Workers stay alive while others may still be splitting folders into more work.
    var inFlight = 0;
    Future<void> worker() async {
      while (queue.isNotEmpty || inFlight > 0) {
        if (queue.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 15));
          continue;
        }
        final task = queue.removeAt(0);
        inFlight++;
        try {
          await task();
        } finally {
          inFlight--;
        }
      }
    }

    // Leave a core free so the UI and the rest of the machine stay responsive.
    final workers = (Platform.numberOfProcessors - 1).clamp(2, 8);
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
    settings.save();
  }

  Future<void> _fetchLatest() async {
    await Future.wait(
      techs.map((t) async {
        try {
          t.snapshot.latest = await t.adapter.latestVersion();
        } catch (_) {}
      }),
    );
    notifyListeners();
  }

  // ---- Actions ----

  Job run(PlannedChange change, {List<String> removesItemIds = const []}) => jobs.enqueue(change, removesItemIds: removesItemIds);

  void _onJobFinished(Job job) {
    final record = job.change.record;
    if (job.status == JobStatus.done && record != null) {
      settings.update((s) => s.installs = [...s.installs.where((r) => r['dest'] != record['dest']), record]);
    }
    if (job.status == JobStatus.done) {
      removedIds.addAll(job.removesItemIds);
      notifyListeners();
    }
    onJobNotification?.call(job);
    // Let the collapse animation play, then pick up the new state.
    Future.delayed(const Duration(milliseconds: 450), () => scan(quiet: true));
  }
}
