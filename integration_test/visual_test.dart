// Visual pass: light theme, minimum window size (icon-only pane), reduce motion.
// Any overflow or other Flutter error fails the test.
//   flutter test integration_test/visual_test.dart -d windows --dart-define=SHOTS=<dir>
// ignore_for_file: avoid_print
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:stackyard/main.dart';
import 'package:stackyard/state/app_state.dart';
import 'package:stackyard/state/settings.dart';
import 'package:stackyard/ui/shell.dart';
import 'package:window_manager/window_manager.dart';

import 'real_machine_test.dart' show captureDark, capturable, settle, shot, waitFor;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('light theme, minimum size, reduce motion', (tester) async {
    await tester.pumpWidget(capturable(await bootstrap()));
    final state = tester.element(find.byType(Shell)).read<AppState>();
    final settings = tester.element(find.byType(Shell)).read<Settings>();
    final shell = tester.state<ShellState>(find.byType(Shell));
    final originalTheme = settings.themeMode;
    addTearDown(() => settings.update((s) => s.themeMode = originalTheme));
    await waitFor(tester, () => state.lastScan != null && state.phase == ScanPhase.idle);

    Future<void> tour(String prefix) async {
      for (final id in ['overview', 'flutter', 'android', 'npm:react', 'activity', 'settings']) {
        if (id != 'overview' && id != 'activity' && id != 'settings' && state.tech(id) == null) continue;
        shell.open(id);
        await settle(tester, 1200);
        await shot(tester, '$prefix-${id.replaceAll(':', '-')}');
      }
    }

    // Light theme at the default size.
    settings.update((s) => s.themeMode = ThemeMode.light);
    captureDark.value = false;
    await settle(tester, 1500);
    await tour('light');

    // Minimum window size: the pane collapses to icons.
    await windowManager.setSize(const Size(720, 520));
    await settle(tester, 1500);
    print('WINDOW ${await windowManager.getSize()}');
    await tour('min');

    // Reduce motion: everything still renders, nothing animates.
    settings.update((s) => s.reduceMotion = true);
    await settle(tester, 600);
    shell.open('flutter');
    await settle(tester, 600);
    await shot(tester, 'reduced-motion-flutter');
    settings.update((s) => s.reduceMotion = false);

    // Back to dark at a normal size.
    settings.update((s) => s.themeMode = ThemeMode.dark);
    captureDark.value = true;
    await windowManager.setSize(const Size(1180, 780));
    shell.open('overview');
    await settle(tester, 1500);
    await shot(tester, 'dark-overview');
    print('VISUAL done');
  }, timeout: const Timeout(Duration(minutes: 15)));
}
