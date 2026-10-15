import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackyard/core/models.dart';
import 'package:stackyard/core/techs/android_tech.dart';

void main() {
  late Directory avdDir;
  late InstalledItem avd;
  setUp(() {
    avdDir = Directory.systemTemp.createTempSync('stackyard-avd-');
    for (final f in ['config.ini', 'userdata.img', 'userdata-qemu.img.qcow2', 'cache.img', 'multiinstance.lock']) {
      File(p.join(avdDir.path, f)).writeAsStringSync('x');
    }
    Directory(p.join(avdDir.path, 'snapshots', 'default_boot')).createSync(recursive: true);
    avd = InstalledItem(id: 'avd', version: 'Pixel_7', label: 'Pixel 7', path: avdDir.path, group: 'Emulators', details: {'AVD': 'Pixel_7'});
  });
  tearDown(() => avdDir.deleteSync(recursive: true));

  test('wiping removes saved data and snapshots but keeps the image it starts fresh from', () {
    final plan = AndroidTech().planWipe(avd)!;
    final names = plan.recycle.map(p.basename).toSet();
    expect(names, {'userdata-qemu.img.qcow2', 'cache.img', 'snapshots'});
    expect(names, isNot(contains('userdata.img')));
    expect(names, isNot(contains('config.ini')));
  });

  test('deleting snapshots touches only the snapshots folder', () {
    expect(AndroidTech().planDeleteSnapshots(avd)!.recycle, [p.join(avdDir.path, 'snapshots')]);
  });

  test('an emulator counts as running only while it holds its lock files', () {
    // multiinstance.lock stays behind after a normal shutdown.
    expect(AndroidTech.isRunning(avd), isFalse);
    Directory(p.join(avdDir.path, 'hardware-qemu.ini.lock')).createSync();
    expect(AndroidTech.isRunning(avd), isTrue);
  });

  test('API levels read as Android versions', () {
    expect(AndroidTech.androidName('34'), 'Android 14 (API 34)');
    expect(AndroidTech.androidName('32'), 'Android 12L (API 32)');
    expect(AndroidTech.androidName('99'), 'API 99');
  });
}
