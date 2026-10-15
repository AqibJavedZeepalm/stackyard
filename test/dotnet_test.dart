import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackyard/core/project_scanner.dart';
import 'package:stackyard/core/techs/dotnet_tech.dart';

void main() {
  String? pick(List<String> installed, String? version, [String? rollForward, bool? allowPrerelease]) =>
      resolveDotnetSdk(installed, version, rollForward: rollForward, allowPrerelease: allowPrerelease);

  const sdks = ['6.0.428', '7.0.410', '8.0.204', '8.0.303', '8.0.308', '8.0.402', '8.0.405', '9.0.101'];

  test('defaults: newest SDK without a version, patch with one', () {
    expect(pick(sdks, null), '9.0.101');
    expect(pick(sdks, '8.0.303'), '8.0.303');
    expect(pick(sdks, '8.0.301'), '8.0.308');
    expect(pick(sdks, '8.0.310'), isNull);
  });

  test('disable needs the exact version', () {
    expect(pick(sdks, '8.0.303', 'disable'), '8.0.303');
    expect(pick(sdks, '8.0.302', 'disable'), isNull);
  });

  test('patch prefers the exact version, else the newest patch in the band', () {
    expect(pick(sdks, '8.0.303', 'patch'), '8.0.303');
    expect(pick(sdks, '8.0.300', 'patch'), '8.0.308');
    expect(pick(['8.0.402'], '8.0.302', 'patch'), isNull);
  });

  test('feature, minor and major take the nearest band, then its newest patch', () {
    expect(pick(sdks, '8.0.303', 'feature'), '8.0.308');
    expect(pick(sdks, '8.0.310', 'feature'), '8.0.405');
    expect(pick(sdks, '8.0.500', 'feature'), isNull);
    expect(pick(['8.0.402', '8.1.100'], '8.0.500', 'minor'), '8.1.100');
    expect(pick(sdks, '8.0.500', 'minor'), isNull);
    expect(pick(sdks, '8.0.500', 'major'), '9.0.101');
    expect(pick(sdks, '7.0.100', 'major'), '7.0.410');
  });

  test('latest policies take the newest version in their range', () {
    expect(pick(sdks, '8.0.303', 'latestPatch'), '8.0.308');
    expect(pick(sdks, '8.0.303', 'latestFeature'), '8.0.405');
    expect(pick(sdks, '7.0.100', 'latestMinor'), '7.0.410');
    expect(pick(sdks, '7.0.100', 'latestMajor'), '9.0.101');
    expect(pick(sdks, '9.0.200', 'latestMajor'), isNull);
  });

  test("Microsoft's examples", () {
    // 7.0.200 or later, including 8.0.xxx.
    expect(pick(['7.0.100', '7.0.203', '8.0.402'], '7.0.200', 'latestMajor'), '8.0.402');
    expect(pick(['7.0.100'], '7.0.200', 'latestMajor'), isNull);
    // 8.0.302 or any later 8.0.xxx: the Reddit report.
    expect(pick(['8.0.402'], '8.0.302', 'latestFeature'), '8.0.402');
    expect(pick(['8.0.301', '9.0.100'], '8.0.302', 'latestFeature'), isNull);
    // 8.0.102 or a later 8.0.1xx.
    expect(pick(['8.0.103', '8.0.199', '8.0.200'], '8.0.102', 'latestPatch'), '8.0.199');
    // Exact.
    expect(pick(['8.0.302', '8.0.303'], '8.0.302', 'disable'), '8.0.302');
    // "10.0" isn't a valid version.
    expect(pick(['10.0.100'], '10.0', 'latestFeature'), isNull);
  });

  test('allowPrerelease', () {
    const withPreview = ['8.0.402', '9.0.100-rc.2.24474.11'];
    expect(pick(withPreview, null), '9.0.100-rc.2.24474.11');
    expect(pick(withPreview, null, null, false), '8.0.402');
    expect(pick(withPreview, '8.0.400', 'latestMajor', false), '8.0.402');
    expect(pick(withPreview, '8.0.400', 'latestMajor', true), '9.0.100-rc.2.24474.11');
    // Asking for a prerelease allows them whatever allowPrerelease says.
    expect(pick(withPreview, '9.0.100-rc.2.24474.11', null, false), '9.0.100-rc.2.24474.11');
  });

  test('without a version any rollForward takes the newest SDK (as the real dotnet does), unknown policies fail', () {
    expect(pick(sdks, null, 'latestFeature'), '9.0.101');
    expect(pick(sdks, null, 'disable'), '9.0.101');
    expect(pick(sdks, null, 'latestMajor'), '9.0.101');
    expect(pick(sdks, '8.0.303', 'sideways'), isNull);
    expect(pick(sdks, '8.0.303', 'LatestFeature'), '8.0.405');
  });

  test("reads global.json's version, rollForward and allowPrerelease", () {
    final dir = Directory.systemTemp.createTempSync('sy-dotnet');
    addTearDown(() => dir.deleteSync(recursive: true));
    File(p.join(dir.path, 'api', 'global.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{"sdk": {"version": "8.0.302", "rollForward": "latestFeature", "allowPrerelease": false}}');
    final project = ProjectScanner.scanSync([dir.path]).single;
    expect(project.pins['dotnet']?.raw, '8.0.302');
    expect(project.buildInfo['rollForward'], 'latestFeature');
    expect(project.buildInfo['allowPrerelease'], 'false');
  });
}
