// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackyard/core/settings_defaults.dart';

void main() {
  test('finds the folders that hold projects, with counts, skipping system folders', () async {
    final home = Directory.systemTemp.createTempSync('sy-home');
    addTearDown(() => home.deleteSync(recursive: true));
    void project(String rel, String file) => File(p.join(home.path, rel, file)).createSync(recursive: true);
    project('Code/app', 'pubspec.yaml');
    project('Code/web', 'package.json');
    project('Documents/GitHub/site', 'package.json');
    project('Library/cache/thing', 'pubspec.yaml'); // never searched
    project('.hidden/tool', 'package.json'); // never searched
    project('flutter/packages/flutter_tools', 'pubspec.yaml'); // an SDK, not your projects
    project('android-sdk/sample', 'package.json');
    Directory(p.join(home.path, 'Empty')).createSync();

    final found = await findProjectFolders(home: home.path, usual: [p.join(home.path, 'Documents', 'GitHub')]);
    expect(found.map((f) => (p.relative(f.$1, from: home.path), f.$2)), [('Code', 2), (p.join('Documents', 'GitHub'), 1)]);
  });

  test('on this machine', () async {
    final sw = Stopwatch()..start();
    final found = await findProjectFolders();
    print('${sw.elapsedMilliseconds} ms: $found');
  }, skip: !const bool.fromEnvironment('SMOKE'));
}
