// Checks the .NET SDK resolver against the real `dotnet`: for every global.json
// combination below, Stackyard must pick the SDK `dotnet --version` reports
// (or none when dotnet fails). Needs a dotnet root with a few SDKs, e.g.
//   ./dotnet-install.sh --channel 8.0.1xx --install-dir /tmp/dn --no-path   (also 8.0.4xx, 9.0.1xx)
//   flutter test test/dotnet_live_test.dart --dart-define=DOTNET=/tmp/dn
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackyard/core/techs/dotnet_tech.dart';

const root = String.fromEnvironment('DOTNET');

void main() {
  test('Stackyard picks the same SDK as dotnet for every global.json', () async {
    final dotnet = p.join(root, Platform.isWindows ? 'dotnet.exe' : 'dotnet');
    final env = {'DOTNET_ROOT': root, 'DOTNET_MULTILEVEL_LOOKUP': '0', 'DOTNET_CLI_TELEMETRY_OPTOUT': '1', 'DOTNET_NOLOGO': '1'};
    final list = await Process.run(dotnet, ['--list-sdks'], environment: env);
    final installed = [for (final m in RegExp(r'^(\S+) \[', multiLine: true).allMatches('${list.stdout}')) m[1]!];
    print('installed: $installed');
    expect(installed, isNotEmpty);

    final versions = <String?>[null, '7.0.100', '8.0.100', '8.0.132', '8.0.140', '8.0.300', '8.0.426', '8.0.500', '9.0.100', '9.0.200', '10.0.100'];
    const policies = <String?>[null, 'patch', 'feature', 'minor', 'major', 'latestPatch', 'latestFeature', 'latestMinor', 'latestMajor', 'disable'];
    final tmp = Directory.systemTemp.createTempSync('sy-dotnet');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final mismatches = <String>[];
    var cases = 0;
    for (final version in versions) {
      for (final policy in policies) {
        for (final pre in <bool?>[null, false]) {
          final sdk = {'version': ?version, 'rollForward': ?policy, 'allowPrerelease': ?pre};
          final dir = Directory(p.join(tmp.path, '${cases++}'))..createSync();
          if (sdk.isNotEmpty) File(p.join(dir.path, 'global.json')).writeAsStringSync(jsonEncode({'sdk': sdk}));
          final r = await Process.run(dotnet, ['--version'], workingDirectory: dir.path, environment: env);
          final real = r.exitCode == 0 ? '${r.stdout}'.trim() : null;
          final ours = resolveDotnetSdk(installed, version, rollForward: policy, allowPrerelease: pre);
          final line = '${jsonEncode(sdk).padRight(70)} dotnet: ${real ?? 'fails'}   Stackyard: ${ours ?? 'none'}';
          if (real != ours) mismatches.add(line);
        }
      }
    }
    print('$cases cases, ${mismatches.length} mismatches');
    for (final m in mismatches) {
      print('MISMATCH $m');
    }
    expect(mismatches, isEmpty);
  }, skip: root.isEmpty, timeout: const Timeout(Duration(minutes: 10)));
}
