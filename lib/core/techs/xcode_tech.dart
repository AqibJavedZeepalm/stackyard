import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:path/path.dart' as p;

import '../models.dart';
import '../sys.dart';
import 'tech.dart';

/// Xcode's simulators (iOS, watchOS, tvOS, visionOS), the runtimes they boot
/// and Xcode's rebuildable caches. macOS only; read through `xcrun simctl`.
class XcodeTech extends TechAdapter {
  @override
  final info = const TechInfo(id: 'xcode', name: 'Xcode', kind: TechKind.toolchain, color: Color(0xFF1C8CF5), monogram: 'X');

  static const simulatorsGroup = 'Simulators';
  static const runtimesGroup = 'Runtimes';
  static const _xcrun = '/usr/bin/xcrun';

  static String get _developer => p.join(Sys.home, 'Library', 'Developer');

  @override
  Future<TechSnapshot?> detect(ScanContext ctx) async {
    if (Sys.isWindows) return null;
    final items = <InstalledItem>[];

    // Runtimes: one disk image per OS version, several GB each.
    final runtimes = <String, InstalledItem>{};
    final runtimeJson = _decode(await Sys.run(_xcrun, ['simctl', 'runtime', 'list', '-j'], timeout: const Duration(seconds: 60)));
    for (final r in (runtimeJson as Map? ?? const {}).values.whereType<Map>()) {
      final rid = r['runtimeIdentifier'] as String?;
      if (rid == null) continue;
      final platform = _platform(r['platformIdentifier'] as String?);
      final version = '${r['version'] ?? '?'}';
      final lastUsed = DateTime.tryParse('${r['lastUsedAt']}');
      final item = InstalledItem(
        id: 'xcode:runtime:${r['identifier']}',
        version: version,
        label: '$platform $version',
        // Lives in a system folder Stackyard doesn't measure; simctl knows its size.
        path: '',
        group: runtimesGroup,
        isBroken: r['state'] != null && r['state'] != 'Ready',
        // A runtime used recently isn't a clean-up candidate even with no simulator on it now.
        lastUsedAt: lastUsed,
        removable: r['deletable'] != false,
        removeHint: r['deletable'] == false ? 'Xcode itself includes this runtime, so it can\'t be deleted on its own.' : null,
        details: {
          'Build': '${r['build'] ?? ''}',
          'Last used': lastUsed == null ? 'Never' : agoText(lastUsed),
          'Identifier': '${r['identifier']}',
          if (r['state'] != null && r['state'] != 'Ready') 'Problem': 'Its state is "${r['state']}", so simulators can\'t use it.',
        },
      )..sizeBytes = (r['sizeBytes'] as num?)?.toInt();
      runtimes[rid] = item;
      items.add(item);
    }

    // Simulators.
    final deviceJson = _decode(await Sys.run(_xcrun, ['simctl', 'list', '-j', 'devices'], timeout: const Duration(seconds: 60)));
    var unavailable = 0;
    for (final MapEntry(key: rid, value: devices) in ((deviceJson as Map?)?['devices'] as Map? ?? const {}).entries) {
      for (final d in (devices as List).whereType<Map>()) {
        final udid = d['udid'] as String;
        final dataPath = d['dataPath'] as String?;
        final path = dataPath != null ? p.dirname(dataPath) : p.join(_developer, 'CoreSimulator', 'Devices', udid);
        final available = d['isAvailable'] != false;
        if (!available) unavailable++;
        final lastBoot = DateTime.tryParse('${d['lastBootedAt']}');
        final os = _runtimeName('$rid');
        final sim = InstalledItem(
          id: 'xcode:sim:$udid',
          version: '${d['name']}',
          path: path,
          group: simulatorsGroup,
          isBroken: !available,
          usageTracked: false,
          lastUsedAt: lastBoot,
          installedAt: Sys.modified(path),
          details: {
            'Device': _deviceName(d['deviceTypeIdentifier'] as String?),
            'OS': os,
            'Last started': lastBoot == null ? 'Never' : agoText(lastBoot),
            'UDID': udid,
            if (!available) 'Problem': '${d['availabilityError'] ?? 'Its runtime ($os) isn\'t installed'}, so it can\'t start.',
          },
        );
        items.add(sim);
        runtimes['$rid']?.usedBy.add(UsageRef(name: sim.title, path: path, kind: 'simulator', lastActive: lastBoot));
      }
    }

    // Caches Xcode rebuilds by itself. Archives are left alone: they're needed to read crash reports.
    for (final (rel, label) in [
      (p.join('Xcode', 'DerivedData'), 'DerivedData (build cache)'),
      (p.join('Xcode', 'iOS DeviceSupport'), 'iOS device support files'),
      (p.join('Xcode', 'watchOS DeviceSupport'), 'watchOS device support files'),
      (p.join('CoreSimulator', 'Caches'), 'Simulator caches'),
    ]) {
      final path = p.join(_developer, rel);
      if (!Sys.dirExists(path)) continue;
      items.add(InstalledItem(id: 'xcode:cache:$rel', version: label, path: path, group: 'Caches', isCache: true));
    }

    if (items.isEmpty) return null;
    final snap = TechSnapshot(managerLabel: runtimeJson == null && deviceJson == null ? 'Xcode caches' : 'xcrun simctl', items: items);
    if (unavailable > 0) {
      snap.problem(
        '$unavailable simulator${unavailable == 1 ? '' : 's'} can\'t start because ${unavailable == 1 ? 'its runtime is' : 'their runtimes are'} gone.',
        [NoteFix('Delete ${unavailable == 1 ? 'it' : 'them'}', planDeleteUnavailable(), recommended: true)],
      );
    }
    return snap;
  }

  // ---- Simulator actions ----

  static String? udid(InstalledItem sim) => sim.details['UDID'];

  /// Simulators running right now (they start and stop outside Stackyard).
  static Future<Set<String>> booted() async {
    final json = _decode(await Sys.run(_xcrun, ['simctl', 'list', '-j', 'devices', 'booted']));
    return {
      for (final devices in ((json as Map?)?['devices'] as Map? ?? const {}).values)
        for (final d in (devices as List).whereType<Map>()) '${d['udid']}',
    };
  }

  /// Boots the simulator and shows it in the Simulator app.
  static Future<void> start(InstalledItem sim) async {
    await Process.run(_xcrun, ['simctl', 'boot', udid(sim)!]);
    await Process.run('open', ['-a', 'Simulator', '--args', '-CurrentDeviceUDID', udid(sim)!]);
  }

  static Future<void> shutDown(InstalledItem sim) => Process.run(_xcrun, ['simctl', 'shutdown', udid(sim)!]);

  static PlannedChange planErase(InstalledItem sim) => PlannedChange(
    title: 'Erase ${sim.title}',
    commands: [CommandSpec(title: 'Erase all content and settings', executable: _xcrun, arguments: ['simctl', 'erase', udid(sim)!])],
    warning: 'Apps and data inside this simulator are erased. It starts like new next time.',
    confirmLabel: 'Erase',
  );

  static PlannedChange planDeleteUnavailable() => PlannedChange(
    title: 'Delete simulators that can\'t start',
    commands: [CommandSpec(title: 'Delete every simulator whose runtime is gone', executable: _xcrun, arguments: ['simctl', 'delete', 'unavailable'])],
    confirmLabel: 'Delete',
  );

  /// Simulators and runtimes are removed through simctl, which keeps Xcode's
  /// list of devices in step; moving their folders away would leave it stale.
  @override
  PlannedChange? planRemove(InstalledItem item) {
    if (!item.removable) return null;
    if (item.group == simulatorsGroup) {
      return PlannedChange(
        title: 'Delete simulator ${item.title}',
        commands: [CommandSpec(title: 'Delete ${item.title} (${item.details['OS']})', executable: _xcrun, arguments: ['simctl', 'delete', udid(item)!])],
        warning: 'Apps and data inside it are deleted for good. Xcode can make a new one in Window → Devices and Simulators.',
        confirmLabel: 'Delete',
      );
    }
    if (item.group == runtimesGroup) {
      final users = item.usedBy.length;
      return PlannedChange(
        title: 'Delete the ${item.title} runtime',
        commands: [CommandSpec(title: 'Delete ${item.title} (${item.details['Build']})', executable: _xcrun, arguments: ['simctl', 'runtime', 'delete', item.details['Identifier']!])],
        warning: [
          if (users > 0) '$users simulator${users == 1 ? '' : 's'} use${users == 1 ? 's' : ''} it and won\'t start until it\'s back.',
          'Xcode downloads it again from Settings → Components.',
        ].join(' '),
        confirmLabel: 'Delete',
      );
    }
    return super.planRemove(item);
  }

  // ---- Helpers ----

  static Object? _decode(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      return jsonDecode(s);
    } catch (_) {
      return null;
    }
  }

  static String _platform(String? id) => switch (id) {
    'com.apple.platform.iphonesimulator' => 'iOS',
    'com.apple.platform.watchsimulator' => 'watchOS',
    'com.apple.platform.appletvsimulator' => 'tvOS',
    'com.apple.platform.xrsimulator' => 'visionOS',
    _ => 'Simulator',
  };

  /// "com.apple.CoreSimulator.SimRuntime.iOS-26-0" → "iOS 26.0"
  static String _runtimeName(String id) {
    final m = RegExp(r'SimRuntime\.([A-Za-z]+)-([\d-]+)$').firstMatch(id);
    return m == null ? id.split('.').last : '${m[1]} ${m[2]!.replaceAll('-', '.')}';
  }

  /// "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro" → "iPhone 17 Pro"
  static String _deviceName(String? id) => id == null ? '' : id.split('.').last.replaceAll('-', ' ');
}
