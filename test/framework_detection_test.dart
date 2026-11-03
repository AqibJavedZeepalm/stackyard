import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackyard/core/project_scanner.dart';
import 'package:stackyard/core/registry.dart';
import 'package:stackyard/core/techs/tech.dart';

void main() {
  for (final package in ['@nestjs/core', '@ionic/core']) {
    for (final installed in [false, true]) {
      test('$package is linked to its project (${installed ? 'installed' : 'declared only'})', () async {
        final root = Directory.systemTemp.createTempSync('sy-framework');
        addTearDown(() => root.deleteSync(recursive: true));
        final manifest = File(p.join(root.path, 'package.json'));
        final contents = jsonEncode({
          'dependencies': {package: '^8.0.0'},
        });
        manifest.writeAsStringSync(contents);
        if (installed) {
          final dependency = File(p.join(root.path, 'node_modules', package, 'package.json'));
          dependency.createSync(recursive: true);
          dependency.writeAsStringSync(jsonEncode({'version': '8.1.0'}));
        }

        final projects = ProjectScanner.scanSync([root.path]);
        final adapter = buildRegistry().singleWhere((tech) => tech.id == 'npm:$package');
        final snapshot = await adapter.detect(ScanContext(projects));

        expect(snapshot, isNotNull);
        expect(snapshot!.projects, projects);
        expect(snapshot.items.single.version, installed ? '8.1.0' : '8.0.0');
        expect(snapshot.items.single.group, installed ? 'Versions' : 'Declared only');
        expect(snapshot.items.single.usedBy, hasLength(1));
        expect(snapshot.items.single.removable, isFalse);
        expect(adapter.projectVersion(projects.single), installed ? '8.1.0' : '^8.0.0');
        expect(manifest.readAsStringSync(), contents);
        expect(await adapter.detect(ScanContext([])), isNull);
      });
    }
  }

  for (final wrapper in ['@ionic/angular', '@ionic/react', '@ionic/vue']) {
    test('an $wrapper app shows under Ionic', () async {
      final root = Directory.systemTemp.createTempSync('sy-framework');
      addTearDown(() => root.deleteSync(recursive: true));
      File(p.join(root.path, 'package.json')).writeAsStringSync(
        jsonEncode({
          'dependencies': {wrapper: '^8.0.0'},
        }),
      );
      // pnpm links only declared packages into node_modules, so the wrapper's own version counts.
      File(p.join(root.path, 'node_modules', wrapper, 'package.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({'version': '8.4.1'}));

      final projects = ProjectScanner.scanSync([root.path]);
      final snapshot = await buildRegistry().singleWhere((tech) => tech.id == 'npm:@ionic/core').detect(ScanContext(projects));

      expect(snapshot!.items.single.version, '8.4.1');
      expect(snapshot.items.single.usedBy, hasLength(1));
    });
  }
}
