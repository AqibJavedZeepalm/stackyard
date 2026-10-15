import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackyard/core/models.dart';
import 'package:stackyard/core/sys.dart';
import 'package:stackyard/core/techs/gradle_tech.dart';
import 'package:stackyard/state/app_state.dart';
import 'package:stackyard/state/settings.dart';

/// Builds a tree with many folders two levels down, so parallel sizing
/// has lots of sibling work finishing at once.
int buildTree(Directory root) {
  var total = 0;
  for (var a = 0; a < 6; a++) {
    final top = Directory('${root.path}/top$a')..createSync();
    File('${top.path}/f.bin').writeAsBytesSync(List.filled(100 + a, 1));
    total += 100 + a;
    for (var b = 0; b < 8; b++) {
      final mid = Directory('${top.path}/mid$b')..createSync();
      for (var c = 0; c < 3; c++) {
        final deep = Directory('${mid.path}/deep$c')..createSync();
        final size = 1000 * (a + 1) + 10 * b + c;
        File('${deep.path}/g.bin').writeAsBytesSync(List.filled(size, 2));
        total += size;
      }
      File('${mid.path}/h.bin').writeAsBytesSync(List.filled(7, 3));
      total += 7;
    }
  }
  File('${root.path}/root.bin').writeAsBytesSync(List.filled(55, 4));
  return total + 55;
}

void main() {
  test('parallel sizing matches a straight count exactly', () async {
    final tmp = Directory.systemTemp.createTempSync('stackyard-size-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final expected = buildTree(tmp);
    expect(await Sys.dirSize(tmp.path), expected);

    final state = AppState(Settings.memory());
    final item = InstalledItem(id: 'x', version: '1', path: tmp.path);
    state.techs = [
      TechEntry(GradleTech(), TechSnapshot(managerLabel: 'test', items: [item])),
    ];
    for (var run = 0; run < 3; run++) {
      item.sizeBytes = null;
      await state.measureSizes();
      expect(item.sizeBytes, expected, reason: 'run $run');
      expect(state.measureDone, state.measureTotal);
    }
  });

  test('unchanged folders reuse their cached size', () async {
    final tmp = Directory.systemTemp.createTempSync('stackyard-fresh-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    buildTree(tmp);
    final state = AppState(Settings.memory());
    final item = InstalledItem(id: 'x', version: '1', path: tmp.path);
    state.techs = [
      TechEntry(GradleTech(), TechSnapshot(managerLabel: 'test', items: [item])),
    ];
    await state.measureSizes();
    expect(state.measureTotal, 1);
    await state.measureSizes();
    expect(state.measureTotal, 0, reason: 'second pass should skip the unchanged folder');
  });
}
