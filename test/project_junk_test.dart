import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackyard/core/project_junk.dart';
import 'package:stackyard/core/project_scanner.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('stackyard-junk-'));
  tearDown(() => root.deleteSync(recursive: true));

  void mk(String rel, [String? file]) {
    final dir = Directory(p.joinAll([root.path, ...rel.split('/')]))..createSync(recursive: true);
    if (file != null) File(p.join(dir.path, file)).writeAsStringSync('x');
  }

  Set<String> found(String name) {
    final project = ProjectScanner.scanSync([root.path]).firstWhere((pr) => pr.name == name);
    return findBuildFolders(project).map((f) => f.title).toSet();
  }

  test('a Flutter app: build output, tool cache and Android build folders', () {
    File(p.join((Directory(p.join(root.path, 'app'))..createSync()).path, 'pubspec.yaml')).writeAsStringSync('dependencies:\n  flutter:\n    sdk: flutter\n');
    for (final rel in ['app/build', 'app/.dart_tool', 'app/android/.gradle', 'app/android/app/build', 'app/lib']) {
      mk(rel);
    }
    File(p.join(root.path, 'app', 'android', 'settings.gradle')).writeAsStringSync('');
    expect(found('app'), {'build', '.dart_tool', 'android/.gradle', 'android/app/build'});
  });

  test('a web app: node_modules and framework caches, but never its build output', () {
    mk('web');
    File(p.join(root.path, 'web', 'package.json')).writeAsStringSync('{"name":"web"}');
    for (final rel in ['web/node_modules/react', 'web/.next', 'web/build', 'web/dist', 'web/src']) {
      mk(rel);
    }
    expect(found('web'), {'node_modules', '.next'});
  });

  test('links are skipped, so nothing outside the project can be removed', () {
    mk('web');
    File(p.join(root.path, 'web', 'package.json')).writeAsStringSync('{"name":"web"}');
    mk('elsewhere/precious', 'keep.txt');
    Link(p.join(root.path, 'web', 'node_modules')).createSync(p.join(root.path, 'elsewhere'));
    expect(found('web'), isEmpty);
  });
}
