import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'models.dart';

/// One thing in an exported stack: a Flutter version, a JDK, an Android API…
class StackItem {
  const StackItem({required this.tech, required this.kind, required this.version, required this.label, this.global = false});

  /// The tech id ('flutter', 'android', ...).
  final String tech;

  /// 'version' for most techs; Android uses 'platform', 'build-tools', 'ndk', 'image'.
  final String kind;

  /// What to install. For Android system images, the sdkmanager package id.
  final String version;
  final String label;

  /// It was the default (global) version on the machine it came from.
  final bool global;

  Map<String, Object> toJson() => {'tech': tech, 'kind': kind, 'version': version, 'label': label, if (global) 'global': true};

  static StackItem fromJson(Map<String, dynamic> j) => StackItem(
    tech: j['tech'] as String,
    kind: (j['kind'] as String?) ?? 'version',
    version: j['version'] as String,
    label: (j['label'] as String?) ?? '${j['tech']} ${j['version']}',
    global: j['global'] == true,
  );
}

/// A list of the toolchains on a machine, to set up another one the same way.
class StackFile {
  StackFile({required this.items, required this.from, DateTime? exportedAt}) : exportedAt = exportedAt ?? DateTime.now();

  static const format = 'stackyard-stack';
  final List<StackItem> items;

  /// The machine it came from ("DESKTOP-1 (Windows)").
  final String from;
  final DateTime exportedAt;

  /// What's installed now, from the last scan's results by tech id.
  static StackFile fromMachine(Map<String, TechSnapshot> snapshots) {
    final items = <StackItem>[];
    void add(String tech, String kind, String version, String label, {bool global = false}) {
      if (!items.any((i) => i.tech == tech && i.kind == kind && i.version == version)) {
        items.add(StackItem(tech: tech, kind: kind, version: version, label: label, global: global));
      }
    }

    for (final MapEntry(key: tech, value: snap) in snapshots.entries) {
      for (final item in snap.items.where((i) => !i.isCache && !i.isBroken)) {
        switch (tech) {
          case 'flutter':
            add(tech, 'version', item.version, 'Flutter ${item.version}', global: item.isGlobal);
          case 'node':
            add(tech, 'version', item.version, 'Node.js ${item.version}', global: item.isGlobal);
          case 'python':
            add(tech, 'version', item.version, 'Python ${item.version}', global: item.isGlobal);
          case 'dotnet':
            add(tech, 'version', item.version, '.NET SDK ${item.version}', global: item.isGlobal);
          case 'java' when item.group == 'Versions':
            final major = javaMajorOf(item.version);
            add(tech, 'version', '$major', 'JDK $major', global: item.isGlobal);
          case 'android':
            switch (item.group) {
              case 'Platforms':
                add(tech, 'platform', item.version, 'Android API ${item.version}');
              case 'Build tools':
                add(tech, 'build-tools', item.version, 'Build tools ${item.version}');
              case 'NDK':
                add(tech, 'ndk', item.version, 'NDK ${item.version}');
              case 'System images':
                final parts = p.split(item.path).reversed.take(3).toList().reversed.toList();
                add(tech, 'image', 'system-images;${parts.join(';')}', 'System image ${parts.join(' · ')}');
            }
        }
      }
    }
    return StackFile(
      items: items,
      from:
          '${Platform.localHostname} (${Platform.isWindows
              ? 'Windows'
              : Platform.isMacOS
              ? 'macOS'
              : Platform.operatingSystem})',
    );
  }

  String encode() => const JsonEncoder.withIndent('  ').convert({
    'format': format,
    'version': 1,
    'exportedAt': exportedAt.toIso8601String(),
    'from': from,
    'items': [for (final i in items) i.toJson()],
  });

  /// Reads a stack file; throws a [FormatException] with a plain message otherwise.
  static StackFile decode(String text) {
    final Object? j;
    try {
      j = jsonDecode(text);
    } catch (_) {
      throw const FormatException('This file isn\'t a Stackyard stack. It isn\'t valid JSON.');
    }
    if (j is! Map<String, dynamic> || j['format'] != format || j['items'] is! List) {
      throw const FormatException('This file isn\'t a Stackyard stack.');
    }
    return StackFile(
      items: [for (final i in j['items'] as List) StackItem.fromJson((i as Map).cast<String, dynamic>())],
      from: (j['from'] as String?) ?? 'another computer',
      exportedAt: DateTime.tryParse(j['exportedAt'] as String? ?? ''),
    );
  }

  /// Whether [item] is already on this machine, per the last scan.
  static bool isInstalled(StackItem item, TechSnapshot? snap) {
    if (snap == null) return false;
    final items = snap.items.where((i) => !i.isBroken);
    return switch ((item.tech, item.kind)) {
      ('android', 'platform') => items.any((i) => i.group == 'Platforms' && i.version == item.version),
      ('android', 'build-tools') => items.any((i) => i.group == 'Build tools' && i.version == item.version),
      ('android', 'ndk') => items.any((i) => i.group == 'NDK' && i.version == item.version),
      ('android', 'image') => items.any(
        (i) => i.group == 'System images' && item.version.endsWith(p.split(i.path).reversed.take(3).toList().reversed.join(';')),
      ),
      ('java', _) => items.any((i) => i.group == 'Versions' && '${javaMajorOf(i.version)}' == item.version),
      // Python and .NET: the same minor / feature band counts (installers give the newest patch).
      ('python', _) => items.any((i) => _minor(i.version) == _minor(item.version)),
      ('dotnet', _) => items.any((i) => _minor(i.version) == _minor(item.version)),
      _ => items.any((i) => i.version == item.version),
    };
  }

  static String _minor(String v) => v.split('.').take(2).join('.');

  /// "17.0.9" → 17, "1.8.0_392" → 8.
  static int javaMajorOf(String v) {
    final parts = v.split(RegExp(r'[._+-]'));
    final first = int.tryParse(parts.first) ?? 0;
    return first == 1 && parts.length > 1 ? int.tryParse(parts[1]) ?? 1 : first;
  }
}
