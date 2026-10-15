// Runs the real app against this machine.
//   flutter test integration_test/real_machine_test.dart -d windows
// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:stackyard/main.dart';
import 'package:stackyard/state/app_state.dart';
import 'package:stackyard/ui/motion.dart';
import 'package:stackyard/ui/shell.dart';

Future<void> waitFor(WidgetTester tester, bool Function() done, {Duration timeout = const Duration(minutes: 5)}) async {
  final end = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('Timed out after $timeout');
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }
}

final _shotKey = GlobalKey();
var _shotIndex = 0;
const _shotDir = String.fromEnvironment('SHOTS');

/// Saves a PNG of the app's content (works even if the screen is locked).
Future<void> shot(WidgetTester tester, String name) async {
  if (_shotDir.isEmpty) return;
  await settle(tester, 400);
  final boundary = _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 1);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File('$_shotDir/it-${(++_shotIndex).toString().padLeft(2, '0')}-$name.png');
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes!.buffer.asUint8List());
  print('SHOT ${file.path}');
}

/// Brightness of the stand-in background behind captures; follows the app's theme.
final captureDark = ValueNotifier<bool>(
  WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark,
);

/// Wraps the app so it can be captured. In-app captures can't see Mica, so
/// this paints Windows' base color for the current theme underneath.
Widget capturable(Widget app) {
  return RepaintBoundary(
    key: _shotKey,
    child: ValueListenableBuilder<bool>(
      valueListenable: captureDark,
      builder: (context, dark, child) =>
          ColoredBox(color: dark ? const Color(0xFF202020) : const Color(0xFFF3F3F3), child: child),
      child: app,
    ),
  );
}

Future<void> settle(WidgetTester tester, [int ms = 900]) async {
  for (var i = 0; i < ms ~/ 100; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('real machine: scan, measure, open every page', (tester) async {

    await tester.pumpWidget(capturable(await bootstrap()));
    final state = tester.element(find.byType(Shell)).read<AppState>();
    final shell = tester.state<ShellState>(find.byType(Shell));

    final sw = Stopwatch()..start();
    await waitFor(tester, () => state.lastScan != null && state.phase == ScanPhase.idle);
    print('SCAN_DONE ${sw.elapsedMilliseconds}ms projects=${state.projects.length} techs=${state.techs.map((t) => t.id).join(',')}');
    print('TOTAL ${formatBytes(state.totalBytes)} RECLAIMABLE ${formatBytes(state.reclaimableBytes)} CACHE ${formatBytes(state.cacheBytes)}');
    await shot(tester, 'overview');

    expect(state.techs, isNotEmpty);
    expect(state.totalBytes, greaterThan(0));
    expect(state.allItems.where((e) => e.$2.path.isNotEmpty && e.$2.sizeBytes == null), isEmpty,
        reason: 'every size should be measured');

    // The sidebar only builds the entries that fit on screen, so each tech is
    // checked by opening its page instead.
    for (final t in state.techs) {
      shell.open(t.id);
      await settle(tester);
      expect(find.text(t.info.name), findsWidgets, reason: 'page header for ${t.id}');
      print('PAGE ${t.id} items=${t.snapshot.items.length} projects=${t.snapshot.projects.length} '
          'latest=${t.snapshot.latest} notes=${t.snapshot.notes.length}');
      await shot(tester, 'tech-${t.id.replaceAll(RegExp(r'[^a-z0-9]'), '-')}');
    }
    for (final id in ['overview', 'market', 'projects', 'emulators', 'activity', 'settings']) {
      shell.open(id);
      await settle(tester, id == 'market' ? 4000 : 900);
      print('PAGE $id');
      await shot(tester, id);
    }

    // flutter_test fails the test on any uncaught Flutter error by itself.
  }, timeout: const Timeout(Duration(minutes: 10)));
}
