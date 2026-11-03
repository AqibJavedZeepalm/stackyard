import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackyard/core/models.dart';
import 'package:stackyard/core/project_scanner.dart';
import 'package:stackyard/core/sys.dart';
import 'package:stackyard/core/techs/rust_tech.dart';
import 'package:stackyard/core/techs/tech.dart';

void main() {
  test('toolchain names split into channel and host', () {
    expect(RustTech.splitToolchain('stable-aarch64-apple-darwin'), ('stable', 'aarch64-apple-darwin'));
    expect(RustTech.splitToolchain('1.80.0-x86_64-pc-windows-msvc'), ('1.80.0', 'x86_64-pc-windows-msvc'));
    expect(RustTech.splitToolchain('1.80-x86_64-pc-windows-gnu'), ('1.80', 'x86_64-pc-windows-gnu'));
    expect(RustTech.splitToolchain('nightly-2024-05-01-x86_64-pc-windows-msvc'), ('nightly-2024-05-01', 'x86_64-pc-windows-msvc'));
    expect(RustTech.splitToolchain('1.81.0-beta.3-aarch64-apple-darwin'), ('1.81.0-beta.3', 'aarch64-apple-darwin'));
    expect(RustTech.splitToolchain('nightly'), ('nightly', null));
    expect(RustTech.splitToolchain('my-build'), ('my-build', null), reason: 'a linked toolchain keeps its name');
  });

  test('a channel resolves to the build for rustup\'s host, like rustup does', () {
    const installed = [
      'stable-aarch64-apple-darwin',
      'stable-x86_64-apple-darwin',
      '1.80.0-aarch64-apple-darwin',
      'nightly-2024-05-01-aarch64-apple-darwin',
      'my-build',
    ];
    String? match(String wanted, [String? host = 'aarch64-apple-darwin']) => RustTech.matchToolchain(installed, wanted, host: host);
    expect(match('stable'), 'stable-aarch64-apple-darwin');
    expect(match('stable', 'x86_64-apple-darwin'), 'stable-x86_64-apple-darwin');
    expect(match('stable-x86_64-apple-darwin'), 'stable-x86_64-apple-darwin');
    expect(match('1.80.0'), '1.80.0-aarch64-apple-darwin');
    expect(match('1.80'), isNull, reason: '"1.80" is its own toolchain, not 1.80.0');
    expect(match('nightly'), isNull, reason: 'a dated nightly is not "nightly"');
    expect(match('nightly-2024-05-01'), 'nightly-2024-05-01-aarch64-apple-darwin');
    expect(match('my-build'), 'my-build');
    expect(match('stable', null), isNotNull);
  });

  test('reads rustup override folders from settings.toml, Windows paths too', () {
    const settings = r'''
version = "12"
default_toolchain = "stable-x86_64-pc-windows-msvc"
profile = "default"

[overrides]
"C:\\Users\\me\\code\\engine" = "nightly-x86_64-pc-windows-msvc"
'C:\Users\me\code\tool' = "1.80.0-x86_64-pc-windows-msvc"
"/Users/me/code/app" = "beta-aarch64-apple-darwin"
''';
    expect(RustTech.overridesIn(settings), {
      r'C:\Users\me\code\engine': 'nightly-x86_64-pc-windows-msvc',
      r'C:\Users\me\code\tool': '1.80.0-x86_64-pc-windows-msvc',
      '/Users/me/code/app': 'beta-aarch64-apple-darwin',
    });
    expect(RustTech.overridesIn('version = "12"\ndefault_toolchain = "stable"\n'), isEmpty);
  });

  group('project files', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('sy-rust'));
    tearDown(() => dir.deleteSync(recursive: true));

    Project scan(Map<String, String> files) {
      for (final MapEntry(:key, :value) in files.entries) {
        File(p.join(dir.path, 'crate', key))
          ..createSync(recursive: true)
          ..writeAsStringSync(value);
      }
      return ProjectScanner.scanSync([dir.path]).single;
    }

    test('Cargo.toml makes a Rust project, unpinned without a toolchain file', () {
      final project = scan({'Cargo.toml': '[package]\nname = "crate"\n'});
      expect(project.types, contains('rust'));
      expect(project.pins['rust'], isNull);
      expect(DateTime.now().difference(project.lastModified).inMinutes, lessThan(5), reason: 'Cargo.toml counts as activity');
    });

    test('rust-toolchain.toml channel', () {
      final project = scan({'Cargo.toml': '', 'rust-toolchain.toml': '[toolchain]\nchannel = "1.80.0"\ncomponents = ["rustfmt"]\n'});
      expect(project.pins['rust']?.raw, '1.80.0');
      expect(project.pins['rust']?.source, 'rust-toolchain.toml');
    });

    test('the old one-line rust-toolchain file, which wins over rust-toolchain.toml', () {
      final project = scan({'Cargo.toml': '', 'rust-toolchain': 'nightly-2024-05-01\n', 'rust-toolchain.toml': '[toolchain]\nchannel = "stable"\n'});
      expect(project.pins['rust']?.raw, 'nightly-2024-05-01');
      expect(project.pins['rust']?.source, 'rust-toolchain');
    });

    test('a path toolchain', () {
      final project = scan({'Cargo.toml': '', 'rust-toolchain.toml': '[toolchain]\npath = "/opt/rust/stage1"\n'});
      expect(project.pins['rust']?.raw, '/opt/rust/stage1');
    });

    test('a workspace member uses the toolchain file of a folder above it', () {
      for (final MapEntry(:key, :value) in {
        'Cargo.toml': '[workspace]\nmembers = ["crates/*"]\n',
        'rust-toolchain.toml': '[toolchain]\nchannel = "1.80.0"\n',
        'crates/core/Cargo.toml': '[package]\nname = "core"\n',
      }.entries) {
        File(p.join(dir.path, 'ws', key))
          ..createSync(recursive: true)
          ..writeAsStringSync(value);
      }
      final member = ProjectScanner.scanSync([dir.path]).singleWhere((pr) => pr.name == 'core');
      expect(member.pins['rust']?.raw, '1.80.0');
      expect(member.pins['rust']?.source, p.join('..', '..', 'rust-toolchain.toml'));
    });

    test('apps inside a Cargo repo are still found', () {
      for (final MapEntry(:key, :value) in {
        'Cargo.toml': '[package]\nname = "server"\n',
        'frontend/package.json': '{}',
        'mobile/pubspec.yaml': 'name: mobile\n',
        'target/debug/package.json': '{}',
      }.entries) {
        File(p.join(dir.path, 'server', key))
          ..createSync(recursive: true)
          ..writeAsStringSync(value);
      }
      expect(ProjectScanner.scanSync([dir.path]).map((pr) => pr.name), unorderedEquals(['server', 'frontend', 'mobile']));
    });
  });

  group('detect', () {
    late Directory home;
    final saved = <String, String?>{};
    void setEnv(String key, String? value) {
      saved.putIfAbsent(key, () => Sys.env[key]);
      value == null ? Sys.env.remove(key) : Sys.env[key] = value;
    }

    setUp(() {
      home = Directory.systemTemp.createTempSync('sy-rustup');
      final rustup = p.join(home.path, 'rustup');
      for (final name in ['stable-aarch64-apple-darwin', '1.80.0-aarch64-apple-darwin', 'nightly-2024-05-01-aarch64-apple-darwin']) {
        Directory(p.join(rustup, 'toolchains', name)).createSync(recursive: true);
      }
      File(p.join(rustup, 'settings.toml')).writeAsStringSync(
        'version = "12"\ndefault_toolchain = "stable-aarch64-apple-darwin"\n\n[overrides]\n"${p.join(home.path, 'code', 'old').replaceAll(r'\', r'\\')}" = "1.80.0-aarch64-apple-darwin"\n',
      );
      Directory(p.join(home.path, 'code', 'old')).createSync(recursive: true);
      // A rustup to find without one on PATH.
      File(p.join(home.path, 'cargo', 'bin', Sys.isWindows ? 'rustup.exe' : 'rustup')).createSync(recursive: true);
      setEnv('RUSTUP_HOME', rustup);
      setEnv('CARGO_HOME', p.join(home.path, 'cargo'));
      setEnv('PATH', '');
    });
    tearDown(() {
      saved.forEach((k, v) => v == null ? Sys.env.remove(k) : Sys.env[k] = v);
      saved.clear();
      home.deleteSync(recursive: true);
    });

    Project project(String name, {String? pin}) => Project(path: (Directory(p.join(home.path, 'code', name))..createSync(recursive: true)).path, name: name, lastModified: DateTime.now())
      ..types.add('rust')
      ..pins.addAll({if (pin != null) 'rust': Pin(raw: pin, source: 'rust-toolchain.toml')});

    test('finds the toolchains, marks the default and links projects', () async {
      final tech = RustTech();
      final snap = (await tech.detect(ScanContext([project('app'), project('pinned', pin: '1.80.0'), project('new', pin: '1.85.0')])))!;
      InstalledItem item(String name) => snap.items.singleWhere((i) => i.title == name);

      expect(
        snap.items.map((i) => i.title),
        containsAll(['stable-aarch64-apple-darwin', '1.80.0-aarch64-apple-darwin', 'nightly-2024-05-01-aarch64-apple-darwin']),
      );
      expect(item('stable-aarch64-apple-darwin').isGlobal, isTrue);
      expect(item('stable-aarch64-apple-darwin').usedBy.single.name, 'app');
      expect(item('1.80.0-aarch64-apple-darwin').usedBy.map((u) => u.name), ['pinned', 'old'], reason: 'the override folder uses it too');
      expect(item('nightly-2024-05-01-aarch64-apple-darwin').status, ItemStatus.unused);
      expect(snap.info.single, contains('1.85.0'));
    });

    test('an override on the project folder beats its toolchain file', () async {
      final tech = RustTech();
      final old = project('old', pin: 'nightly-2024-05-01');
      final snap = (await tech.detect(ScanContext([old])))!;
      expect(snap.items.singleWhere((i) => i.title == '1.80.0-aarch64-apple-darwin').usedBy.single.note, 'rustup override');
      expect(tech.projectVersion(old), '1.80.0');
      expect(snap.items.singleWhere((i) => i.title.startsWith('nightly')).usedBy, isEmpty);
    });

    test('an override applies to a project found through a link to its folder', () async {
      Link(p.join(home.path, 'linked')).createSync(p.join(home.path, 'code'));
      final viaLink = Project(path: p.join(home.path, 'linked', 'old'), name: 'old', lastModified: DateTime.now())..types.add('rust');
      final snap = (await RustTech().detect(ScanContext([viaLink])))!;
      expect(snap.items.singleWhere((i) => i.title == '1.80.0-aarch64-apple-darwin').usedBy.single.note, 'rustup override');
      expect(snap.items.singleWhere((i) => i.isGlobal).usedBy, isEmpty);
    });

    test('a toolchain file closer to the project beats an override further up', () async {
      final nested = project('old/inner', pin: 'nightly-2024-05-01');
      final snap = (await RustTech().detect(ScanContext([nested, project('old/plain')])))!;
      expect(snap.items.singleWhere((i) => i.title.startsWith('nightly')).usedBy.single.name, 'old/inner');
      expect(snap.items.singleWhere((i) => i.title == '1.80.0-aarch64-apple-darwin').usedBy.map((u) => u.name), ['old/plain']);
    });

    test('removal goes through rustup, for the same RUSTUP_HOME', () async {
      final tech = RustTech();
      final snap = (await tech.detect(ScanContext([])))!;
      final nightly = snap.items.singleWhere((i) => i.title.startsWith('nightly'));
      final plan = tech.planRemove(nightly)!;
      final cmd = plan.commands.single;
      expect(cmd.executable, p.join(home.path, 'cargo', 'bin', Sys.isWindows ? 'rustup.exe' : 'rustup'));
      expect(cmd.arguments, ['toolchain', 'uninstall', 'nightly-2024-05-01-aarch64-apple-darwin']);
      expect(cmd.environment['RUSTUP_HOME'], p.join(home.path, 'rustup'));
      expect(plan.recycle, isEmpty, reason: 'rustup removes its own files');
      expect(tech.planRemove(snap.items.singleWhere((i) => i.isGlobal))!.warning, isNull, reason: 'the remove dialog warns about the default itself');
    });

    test('a linked toolchain only loses its link', () async {
      final build = Directory(p.join(home.path, 'build', 'stage1'))..createSync(recursive: true);
      Link(p.join(home.path, 'rustup', 'toolchains', 'stage1')).createSync(build.path);
      final tech = RustTech();
      final snap = (await tech.detect(ScanContext([])))!;
      final linked = snap.items.singleWhere((i) => i.title == 'stage1');
      expect(linked.details['Linked to'], build.path);
      expect(tech.planRemove(linked)!.warning, contains('link'));
    });

    test('Rust from Get tools is still removed as a whole', () async {
      final tech = RustTech();
      await tech.detect(ScanContext([]));
      final market = InstalledItem(
        id: 'market:x',
        version: '1.80.0',
        path: p.join(home.path, 'tools', 'rust', '1.80.0'),
        details: const {'_tool': 'rust', '_env': 'user'},
      );
      final plan = tech.planRemove(market)!;
      expect(plan.commands, isEmpty);
      expect(plan.recycle, [market.path]);
    });

    test('no rustup home, no Rust page', () async {
      setEnv('RUSTUP_HOME', p.join(home.path, 'missing'));
      expect(await RustTech().detect(ScanContext([])), isNull);
    });
  });
}
