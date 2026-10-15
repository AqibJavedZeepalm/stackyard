import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackyard/core/doctor.dart';

void main() {
  test('Gradle runs on Java up to the version its docs list', () {
    expect(Doctor.maxJavaForGradle('7.5'), 18);
    expect(Doctor.maxJavaForGradle('7.6.3'), 19);
    expect(Doctor.maxJavaForGradle('8.3'), 20);
    expect(Doctor.maxJavaForGradle('8.4'), 20);
    expect(Doctor.maxJavaForGradle('8.5'), 21);
    expect(Doctor.maxJavaForGradle('8.11.1'), 23);
  });

  test('the Android Gradle Plugin sets the oldest Java', () {
    expect(Doctor.minJavaForAgp('8.1.0'), 17);
    expect(Doctor.minJavaForAgp('7.3.0'), 11);
    expect(Doctor.minJavaForAgp('4.2.2'), 8);
  });

  test('Java versions, old and new style', () {
    expect(Doctor.javaMajor('17.0.9'), 17);
    expect(Doctor.javaMajor('21'), 21);
    expect(Doctor.javaMajor('1.8.0_392'), 8);
  });

  test(
    'PATH cleanup drops missing folders and repeats, keeps variables and the value type, and saves a backup',
    () async {
      const key = r'HKCU\Software\StackyardTest';
      final backup = p.join(Directory.systemTemp.createTempSync('stackyard-path-').path, 'backup.txt');
      // %SystemRoot%\System32 repeats C:\Windows\System32 once expanded; C:\Windows\ and
      // C:\Windows repeat C:\Windows; C:\Program Files stands in for "also in the system PATH".
      const original = r'C:\Windows;C:\Windows\System32;%SystemRoot%\System32;C:\stackyard-missing-folder;C:\Windows\;C:\Windows;C:\Program Files';
      await Process.run('reg.exe', ['add', key, '/v', 'Path', '/t', 'REG_EXPAND_SZ', '/d', original, '/f']);
      addTearDown(() => Process.run('reg.exe', ['delete', key, '/f']));

      final change = Doctor.cleanPathAt(
        r'HKCU:\Software\StackyardTest',
        machine: false,
        missing: [r'C:\stackyard-missing-folder'],
        repeats: [r'%SystemRoot%\System32', r'C:\Windows\', r'C:\Windows'],
        alsoInSystem: [r'C:\Program Files'],
        backupTo: backup,
      );
      final cmd = change.commands.single;
      final r = await Process.run(cmd.executable, cmd.arguments);
      expect(r.exitCode, 0, reason: '${r.stderr}');

      final after = (await Process.run('reg.exe', ['query', key, '/v', 'Path'])).stdout as String;
      expect(after, contains('REG_EXPAND_SZ'));
      expect(RegExp(r'REG_EXPAND_SZ\s+(.*)').firstMatch(after)![1]!.trim(), r'C:\Windows;C:\Windows\System32');
      expect(File(backup).readAsStringSync().trim(), original);
    },
    skip: !Platform.isWindows,
    // The command tells every window the environment changed, which can take
    // well over 30 seconds on a busy CI runner.
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
