import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:stackyard/core/autostart.dart';
import 'package:stackyard/core/models.dart';
import 'package:stackyard/core/project_junk.dart';
import 'package:stackyard/core/techs/android_tech.dart';
import 'package:stackyard/core/techs/flutter_tech.dart';
import 'package:stackyard/core/techs/framework_tech.dart';
import 'package:stackyard/state/app_state.dart';
import 'package:stackyard/state/settings.dart';
import 'package:stackyard/ui/shell.dart';
import 'package:stackyard/ui/widgets.dart';

const gb = 1024 * 1024 * 1024;

AppState fakeState() {
  final state = AppState(Settings.memory());
  final project = Project(path: r'C:\Projects\pixel-pantry', name: 'pixel-pantry', lastModified: DateTime.now())
    ..types.addAll({'flutter', 'android'})
    ..pins['flutter'] = const Pin(raw: '3.35.5', source: '.fvmrc');
  final old = Project(path: r'C:\Projects\orbit-notes', name: 'orbit-notes', lastModified: DateTime(2024, 1, 1))
    ..types.add('flutter')
    ..pins['flutter'] = const Pin(raw: '3.29.2', source: '.fvmrc');

  final f1 = InstalledItem(id: 'f1', version: '3.35.5', path: r'C:\fvm\versions\3.35.5', details: {'Dart': '3.9.2'})
    ..sizeBytes = (1.04 * gb).round()
    ..usedBy.add(project.toUsage());
  final f2 = InstalledItem(id: 'f2', version: '3.29.3', path: r'C:\fvm\versions\3.29.3', isGlobal: true)..sizeBytes = (2.86 * gb).round();
  final f3 = InstalledItem(id: 'f3', version: '3.29.2', path: r'C:\fvm\versions\3.29.2')
    ..sizeBytes = (1.1 * gb).round()
    ..usedBy.add(old.toUsage());
  final f4 = InstalledItem(id: 'f4', version: '3.22.3', path: r'C:\fvm\versions\3.22.3')..sizeBytes = (1.2 * gb).round();
  final flutter = TechSnapshot(managerLabel: 'FVM 3.2.1', items: [f1, f2, f3, f4], latest: '3.47.7')
    ..notes.add('driftboard pins Flutter 3.19.6, which isn\'t installed.');
  flutter.projects.addAll([project, old]);

  final avd = InstalledItem(
    id: 'avd',
    version: 'Pixel_6a_API_34',
    label: 'Pixel 6a API 34',
    path: r'C:\avd\Pixel_6a.avd',
    group: 'Emulators',
    isBroken: true,
    usageTracked: false,
    details: {'Problem': 'Its system image isn\'t installed, so it can\'t start.'},
  )..sizeBytes = 13 * gb;
  final ndk = InstalledItem(id: 'ndk', version: '23.1.7779620', label: 'NDK 23.1.7779620', path: r'F:\sdk\ndk\23', group: 'NDK')
    ..sizeBytes = (2.59 * gb).round();
  final android = TechSnapshot(managerLabel: r'F:\androidSDK', items: [ndk, avd]);

  final react = FrameworkTech(package: 'react', name: 'React', color: const Color(0xFF58C4DC), monogram: 'R');
  final web = Project(path: r'C:\Projects\lumen-web', name: 'lumen-web', lastModified: DateTime.now())
    ..types.add('node')
    ..deps['react'] = const DepVersion(declared: '^19.2.0', installed: '19.2.6');
  final r1 = InstalledItem(id: 'r1', version: '19.2.6', path: '', removable: false)..usedBy.add(web.toUsage());
  final reactSnap = TechSnapshot(managerLabel: 'Found in 1 project', items: [r1])..projects.add(web);

  state.techs = [TechEntry(FlutterTech(), flutter), TechEntry(AndroidTech(), android), TechEntry(react, reactSnap)];
  state.projects = [project, old, web];
  state.cleanups = [
    ProjectCleanup(old, [
      InstalledItem(
        id: 'junk:kb',
        version: 'build',
        label: 'build',
        path: r'C:\Projects\orbit-notes\build',
        group: 'orbit-notes',
        details: {'Comes back with': 'the next flutter build or run'},
      )..sizeBytes = (1.6 * gb).round(),
    ]),
  ];
  state.lastScan = DateTime.now();
  return state;
}

Widget app(AppState state) => MultiProvider(
  providers: [
    ChangeNotifierProvider.value(value: state.settings),
    ChangeNotifierProvider.value(value: state),
    ChangeNotifierProvider.value(value: state.jobs),
  ],
  child: FluentApp(theme: FluentThemeData(), home: const Shell(autoScan: false, nativeChrome: false)),
);

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('navigates every page and opens the remove dialog', (tester) async {
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    AutoStart.testValue = false;
    // Layout errors (overflows…) fail the test on their own, with the widget named.
    final state = fakeState();
    await tester.pumpWidget(app(state));
    await settle(tester);
    expect(tester.takeException(), isNull, reason: 'layout error after step at line 99');

    // Overview: reclaimable = unused Flutter 3.22.3 + NDK + broken emulator.
    expect(find.text('Overview'), findsWidgets);
    expect(find.text('Quick wins'), findsOneWidget);
    expect(find.textContaining('Pixel 6a'), findsOneWidget);
    expect(find.textContaining('Flutter 3.47.7 is available'), findsOneWidget);

    // The storage bar's colored segments are actually visible.
    final segments = find.descendant(of: find.byType(StorageBar), matching: find.byType(ColoredBox));
    expect(segments, findsWidgets);
    for (final e in segments.evaluate()) {
      final size = (e.renderObject! as RenderBox).size;
      expect(size.height, greaterThan(0), reason: 'segment has no height');
    }
    expect(segments.evaluate().any((e) => (e.renderObject! as RenderBox).size.width > 50), isTrue);

    // Sidebar shows only detected techs.
    expect(find.text('Flutter'), findsWidgets);
    expect(find.text('Android SDK'), findsWidgets);
    expect(find.text('React'), findsWidgets);
    expect(find.text('Node.js'), findsNothing);

    // Flutter page.
    await tester.tap(find.text('Flutter').first);
    await settle(tester);
    expect(tester.takeException(), isNull, reason: 'layout error after step at line 124');
    expect(find.text('3.22.3'), findsOneWidget);
    // The page's Projects section, besides the Projects page in the sidebar.
    expect(find.text('Projects'), findsNWidgets(2));
    expect(find.text('pixel-pantry'), findsWidgets);

    // Short lists don't get filters (less clutter).
    expect(find.byKey(const ValueKey('filter-all')), findsNothing);
    // No way to change a project's version: that's deliberately not offered.
    expect(find.text('Change'), findsNothing);

    // Expand a row and open the remove confirmation.
    await tester.tap(find.text('3.22.3'));
    await settle(tester);
    expect(tester.takeException(), isNull, reason: 'layout error after step at line 137');
    expect(find.text('Show in Explorer'), findsOneWidget);
    await tester.tap(find.text('Remove'));
    await settle(tester);
    expect(tester.takeException(), isNull, reason: 'layout error after step at line 140');
    expect(find.text('Move to Recycle Bin'), findsOneWidget);
    // Choosing to skip the Recycle Bin changes the button, so it's never a surprise.
    await tester.tap(find.textContaining('Delete permanently instead'));
    await settle(tester);
    expect(find.text('Delete permanently'), findsWidgets);
    expect(find.text('Move to Recycle Bin'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(tester.takeException(), isNull, reason: 'layout error after step at line 143');

    // Android and React pages.
    await tester.tap(find.text('Android SDK').first);
    await settle(tester);
    expect(tester.takeException(), isNull, reason: 'layout error after step at line 147');
    // Its Emulators section, besides the Emulators page in the sidebar.
    expect(find.text('Emulators'), findsNWidgets(2));
    await tester.tap(find.text('React').first);
    await settle(tester);
    expect(tester.takeException(), isNull, reason: 'layout error after step at line 151');
    expect(find.text('lumen-web'), findsWidgets);

    // Projects: build folders, sized, with a clean button for idle projects.
    await tester.tap(find.text('Projects').first);
    await settle(tester);
    expect(tester.takeException(), isNull, reason: 'layout error after step at line 156');
    expect(find.text('Build folders in your projects'), findsOneWidget);
    expect(find.textContaining('Clean idle projects'), findsOneWidget);
    expect(find.textContaining('orbit-notes', findRichText: true), findsOneWidget);

    // Emulators: one card per emulator with its actions.
    await tester.tap(find.text('Emulators').first);
    await settle(tester);
    expect(tester.takeException(), isNull, reason: 'layout error after step at line 163');
    expect(find.text('Pixel 6a API 34'), findsOneWidget);
    expect(find.text('Wipe data'), findsOneWidget);
    expect(find.text('Cold boot'), findsOneWidget);

    // Activity and Settings.
    await tester.tap(find.text('Activity'));
    await settle(tester);
    expect(tester.takeException(), isNull, reason: 'layout error after step at line 170');
    expect(find.text('No activity yet'), findsOneWidget);
    await tester.tap(find.text('Settings'));
    await settle(tester);
    expect(tester.takeException(), isNull, reason: 'layout error after step at line 173');
    expect(find.text('Project folders'), findsOneWidget);

    // Turning on reduce motion doesn't break anything.
    state.settings.update((s) => s.reduceMotion = true);
    await settle(tester);
    expect(tester.takeException(), isNull, reason: 'layout error after step at line 178');
    final error = tester.takeException();
    expect(error, isNull, reason: error is FlutterError ? error.diagnostics.map((d) => d.toString()).join('\n') : '$error');
  });
}
