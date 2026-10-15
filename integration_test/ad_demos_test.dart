// The Stackyard ad's footage: a copy of integration_test/site_demos_test.dart with an ad
// script. Same made-up machine, plus a sixth Flutter SDK and a 13 GB tablet emulator nobody
// started for a year. Prints "MARK <name> <epoch ms>" for record.sh. Every removal it runs
// points at made-up /Users/dev paths, which the app skips as already gone.
// record.sh copies it into ~/Projects/stackyard/integration_test, runs it and removes it:
//   fvm flutter test integration_test/ad_demos_test.dart -d macos --dart-define=AD=true
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:stackyard/core/models.dart';
import 'package:stackyard/core/project_junk.dart';
import 'package:stackyard/core/techs/android_tech.dart';
import 'package:stackyard/core/techs/dotnet_tech.dart';
import 'package:stackyard/core/techs/flutter_tech.dart';
import 'package:stackyard/core/techs/framework_tech.dart';
import 'package:stackyard/core/techs/gradle_tech.dart';
import 'package:stackyard/core/techs/java_tech.dart';
import 'package:stackyard/core/techs/node_tech.dart';
import 'package:stackyard/core/techs/python_tech.dart';
import 'package:stackyard/core/techs/xcode_tech.dart';
import 'package:stackyard/main.dart';
import 'package:stackyard/state/app_state.dart';
import 'package:stackyard/state/jobs.dart';
import 'package:stackyard/state/settings.dart';
import 'package:stackyard/ui/shell.dart';
import 'package:window_manager/window_manager.dart';

const gb = 1024 * 1024 * 1024;
const mb = 1024 * 1024;
const home = '/Users/dev';

/// Node.js as found with nvm: the real adapter only offers "Make global" once it has found nvm, which
/// the made-up machine doesn't have. Same plan the app builds for Unix nvm. The ad shows it and cancels.
class DemoNodeTech extends NodeTech {
  @override
  bool canSetGlobal(InstalledItem item) => !item.isGlobal && item.group == 'Versions';

  @override
  PlannedChange? planSetGlobal(InstalledItem item) => PlannedChange(
    title: 'Make Node.js ${item.version} the active version',
    commands: [
      CommandSpec(title: 'Switch active Node', executable: 'nvm', arguments: ['alias', 'default', item.version]),
    ],
    warning: 'New terminals use it. Terminals already open keep their Node until you run "nvm use default".',
  );
}

/// A scan that takes a moment, then finds the made-up machine below.
class DemoState extends AppState {
  DemoState(super.settings);

  /// After the fix job: Flutter 3.19.6 is installed and driftboard's problem is gone.
  bool fixed = false;

  @override
  Future<void> scan({bool quiet = false}) async {
    // The quiet rescan after a job keeps what was removed (the base scan would forget it).
    if (quiet) {
      if (jobs.jobs.any((j) => j.status == JobStatus.done && j.change.title.startsWith('Install Flutter'))) fixed = true;
      _fill(this, fixed: fixed);
      notifyListeners();
      return;
    }
    phase = ScanPhase.projects;
    notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 900));
    phase = ScanPhase.techs;
    notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 900));
    _fill(this, fixed: fixed);
    phase = ScanPhase.idle;
    lastScan = DateTime.now();
    notifyListeners();
  }

  /// The machine as found, without the scan animation (the hook opens on it).
  void fillNow() {
    _fill(this);
    lastScan = DateTime.now();
    notifyListeners();
  }

  /// Nothing scanned yet, for the scan scene.
  void forget() {
    techs = [];
    projects = [];
    cleanups = [];
    lastScan = null;
    notifyListeners();
  }
}

Project project(String name, Set<String> types, {int daysAgo = 2, Map<String, String> pins = const {}}) {
  final p = Project(
    path: '$home/Projects/$name',
    name: name,
    lastModified: DateTime.now().subtract(Duration(days: daysAgo)),
  )..types.addAll(types);
  pins.forEach((tech, v) => p.pins[tech] = Pin(raw: v, source: tech == 'flutter' ? '.fvmrc' : '.nvmrc'));
  return p;
}

InstalledItem item(String id, String version, double gigs, {String? label, String group = 'Versions', bool global = false, String path = '', List<Project> users = const []}) {
  final i = InstalledItem(id: id, version: version, label: label, path: path.isEmpty ? '$home/sdk/$id' : path, group: group, isGlobal: global)..sizeBytes = (gigs * gb).round();
  for (final u in users) {
    i.usedBy.add(u.toUsage());
  }
  return i;
}

/// A stand-in `fvm` that only prints git-style progress, so the fix scene shows real progress without installing anything.
String fakeFvmDir() {
  final dir = Directory('${Directory.systemTemp.path}/stackyard-demo-bin')..createSync(recursive: true);
  final fvm = File('${dir.path}/fvm');
  fvm.writeAsStringSync(r'''#!/bin/sh
echo "Installing Flutter SDK 3.19.6"
for p in 4 9 15 22 30 38 47 55 63 71 79 86 92 97 100; do
  printf 'Receiving objects: %3d%% (%d/57954), %d.%d MiB | 9.80 MiB/s\r' $p $((p*579)) $((p*7)) $((p%10))
  sleep 0.3
done
echo
echo "Flutter SDK 3.19.6 installed"
''');
  Process.runSync('chmod', ['+x', fvm.path]);
  return dir.path;
}

void _fill(AppState state, {bool fixed = false}) {
  final driftboard = project('driftboard', {'flutter', 'android', 'ios'}, pins: {'flutter': '3.19.6'});
  final pantry = project('pixel-pantry', {'flutter', 'android', 'ios'}, pins: {'flutter': '3.35.5'});
  final orbit = project('orbit-notes', {'flutter'}, daysAgo: 400, pins: {'flutter': '3.29.2'});
  final lumen = project('lumen-web', {'node'}, pins: {'node': '22'});
  final atlas = project('atlas-api', {'node'}, daysAgo: 150, pins: {'node': '20'});
  final ledger = project('ledger-admin', {'node'}, daysAgo: 6);

  // Flutter
  final flutter = TechSnapshot(
    managerLabel: 'FVM 3.2.1',
    latest: '3.47.7',
    items: [
      item('flutter-3.47.7', '3.47.7', 1.8, global: true),
      item('flutter-3.35.5', '3.35.5', 2.1, users: [pantry]),
      item('flutter-3.29.2', '3.29.2', 1.9, users: [orbit]),
      item('flutter-3.27.4', '3.27.4', 2.2),
      item('flutter-3.24.0', '3.24.0', 2.0),
      item('flutter-3.22.3', '3.22.3', 2.8),
      if (fixed) item('flutter-3.19.6', '3.19.6', 1.7, users: [driftboard]),
    ],
  )..projects.addAll([driftboard, pantry, orbit]);
  if (!fixed) {
    flutter.problem('driftboard pins Flutter 3.19.6, which isn\'t installed, so it won\'t build until it is.', [
      NoteFix(
        'Install Flutter 3.19.6',
        PlannedChange(
          title: 'Install Flutter 3.19.6',
          commands: [
            CommandSpec(title: 'Download and set up Flutter 3.19.6', executable: 'fvm', arguments: const ['install', '3.19.6'], environment: {'PATH': '${fakeFvmDir()}:/usr/bin:/bin'}),
          ],
        ),
        recommended: true,
      ),
    ]);
  }

  // Node.js
  final node = TechSnapshot(
    managerLabel: 'nvm',
    latest: '24.22.0',
    items: [
      item('node-24', '24.22.0', 0.13, global: true, users: [ledger]),
      item('node-22', '22.11.0', 0.12, users: [lumen]),
      item('node-20', '20.20.2', 0.11, users: [atlas]),
      item('node-18', '18.20.4', 0.1),
    ],
  )..projects.addAll([lumen, atlas, ledger]);

  // Android SDK, with emulators
  final android = TechSnapshot(
    managerLabel: '$home/Library/Android/sdk',
    items: [
      item('android-36', 'android-36', 0.21, label: 'Android 16 (API 36)', group: 'Platforms', users: [pantry, driftboard]),
      item('android-34', 'android-34', 0.19, label: 'Android 14 (API 34)', group: 'Platforms'),
      item('ndk-27', '27.0.12077973', 2.6, label: 'NDK 27.0.12077973', group: 'NDK', users: [pantry]),
      item('ndk-26', '26.3.11579264', 2.5, label: 'NDK 26.3.11579264', group: 'NDK'),
      item('ndk-25', '25.1.8937393', 2.4, label: 'NDK 25.1.8937393', group: 'NDK'),
      item('img-34', 'system-images;android-34', 6.2, label: 'Android 14 Google APIs', group: 'System images'),
      InstalledItem(
        id: 'avd-pixel8',
        version: 'Pixel_8',
        label: 'Pixel 8',
        path: '$home/.android/avd/Pixel_8.avd',
        group: 'Emulators',
        usageTracked: false,
        lastUsedAt: DateTime.now().subtract(const Duration(days: 3)),
        details: const {'Device': 'pixel 8', 'Android': 'Android 15 (API 35)', 'Last started': '3 days ago', 'AVD': 'Pixel_8'},
      )..sizeBytes = (5.8 * gb).round(),
      InstalledItem(
        id: 'avd-tablet',
        version: 'Tablet',
        label: 'Pixel Tablet',
        path: '$home/.android/avd/Tablet.avd',
        group: 'Emulators',
        usageTracked: false,
        lastUsedAt: DateTime.now().subtract(const Duration(days: 400)),
        details: {'Device': 'pixel tablet', 'Android': 'Android 14 (API 34)', 'Last started': agoText(DateTime.now().subtract(const Duration(days: 400))), 'AVD': 'Tablet'},
      )..sizeBytes = (13.2 * gb).round(),
    ],
  )..projects.addAll([pantry, driftboard]);

  // Xcode: simulators and runtimes
  InstalledItem sim(String udid, String name, String device, String os, double gigs, int? days) => InstalledItem(
    id: 'xcode:sim:$udid',
    version: name,
    path: '$home/Library/Developer/CoreSimulator/Devices/$udid',
    group: XcodeTech.simulatorsGroup,
    usageTracked: false,
    lastUsedAt: days == null ? null : DateTime.now().subtract(Duration(days: days)),
    details: {'Device': device, 'OS': os, 'Last started': days == null ? 'Never' : (days == 0 ? 'Today' : '$days days ago'), 'UDID': udid},
  )..sizeBytes = (gigs * gb).round();
  final runtime26 = InstalledItem(
    id: 'xcode:runtime:26',
    version: '26.0',
    label: 'iOS 26.0',
    path: '',
    group: XcodeTech.runtimesGroup,
    details: const {'Build': '23A343', 'Identifier': 'R26', 'Last used': 'Today'},
  )..sizeBytes = (8.0 * gb).round();
  final runtime18 = InstalledItem(
    id: 'xcode:runtime:18',
    version: '18.4',
    label: 'iOS 18.4',
    path: '',
    group: XcodeTech.runtimesGroup,
    details: const {'Build': '22E238', 'Identifier': 'R18', 'Last used': '5 mo ago'},
  )..sizeBytes = (8.8 * gb).round();
  final sims = [
    sim('A1', 'iPhone 17 Pro', 'iPhone 17 Pro', 'iOS 26.0', 4.1, 0),
    sim('A2', 'iPad Air', 'iPad Air 13-inch (M3)', 'iOS 26.0', 2.3, 12),
    sim('A3', 'iPhone 16', 'iPhone 16', 'iOS 18.4', 3.2, 160),
  ];
  runtime26.usedBy.addAll([const UsageRef(name: 'iPhone 17 Pro', path: '', kind: 'simulator'), const UsageRef(name: 'iPad Air', path: '', kind: 'simulator')]);
  runtime18.usedBy.add(UsageRef(name: 'iPhone 16', path: '', kind: 'simulator', lastActive: DateTime.now().subtract(const Duration(days: 160))));
  final xcode = TechSnapshot(
    managerLabel: 'xcrun simctl',
    items: [
      runtime26,
      runtime18,
      ...sims,
      InstalledItem(id: 'xcode:cache:dd', version: 'DerivedData (build cache)', path: '$home/Library/Developer/Xcode/DerivedData', group: 'Caches', isCache: true)..sizeBytes = (6.4 * gb).round(),
    ],
  );

  // Java and Python
  final java = TechSnapshot(
    managerLabel: 'JDKs on this machine',
    items: [
      item('jdk-21', '21.0.8', 0.31, label: 'JDK 21.0.8', global: true),
      item('jdk-17', '17.0.16', 0.29, label: 'JDK 17.0.16'),
    ],
  );
  final python = TechSnapshot(managerLabel: 'pyenv', items: [item('py-313', '3.13.7', 0.09, global: true), item('py-311', '3.11.12', 0.08)]);

  // Frameworks found in projects
  // Gradle and .NET
  final gradle = TechSnapshot(
    managerLabel: '$home/.gradle',
    items: [
      item('gradle:gradle-8.10.2-all', '8.10.2', 0.42, label: 'Gradle 8.10.2 (all)', users: [pantry, driftboard]),
      item('gradle:gradle-8.3-bin', '8.3', 0.15, label: 'Gradle 8.3 (bin)'),
      InstalledItem(
        id: 'gradle:cache:caches',
        version: 'caches',
        label: 'Dependency and build caches',
        path: '$home/.gradle/caches',
        group: 'Caches',
        isCache: true,
        details: const {'Note': 'Gradle downloads or rebuilds this on the next build.'},
      )..sizeBytes = (3.1 * gb).round(),
    ],
  );
  final dotnet = TechSnapshot(managerLabel: 'dotnet CLI', items: [item('dotnet:9.0.100', '9.0.100', 0.78, global: true), item('dotnet:8.0.404', '8.0.404', 0.71)]);
  final next = FrameworkTech(package: 'next', name: 'Next.js', color: const Color(0xFF6E6E6E), monogram: 'Nx', logo: 'assets/tech/next.svg', logoTint: LogoTint.foreground);
  final nextSnap = TechSnapshot(
    managerLabel: 'Found in 1 project',
    items: [InstalledItem(id: 'n15', version: '15.5.4', path: '', removable: false)..usedBy.add(lumen.toUsage())],
  )..projects.add(lumen);
  final ts = FrameworkTech(package: 'typescript', name: 'TypeScript', color: const Color(0xFF3178C6), monogram: 'TS', logo: 'assets/tech/typescript.svg');
  final tsSnap = TechSnapshot(
    managerLabel: 'Found in 3 projects',
    items: [
      InstalledItem(id: 'ts59', version: '5.9.3', path: '', removable: false)..usedBy.addAll([lumen.toUsage(), ledger.toUsage()]),
      InstalledItem(id: 'ts54', version: '5.4.5', path: '', removable: false)..usedBy.add(atlas.toUsage()),
    ],
  )..projects.addAll([lumen, ledger, atlas]);
  // What the environment doctor reports, worded as the app words it (core/doctor.dart).
  state.systemIssues = [
    (
      text: 'JAVA_HOME points to $home/sdks/java/17, which doesn\'t exist anymore, so tools that read JAVA_HOME (Gradle, Maven) can\'t start.',
      fixes: [
        NoteFix('Point it to JDK 21', PlannedChange(title: 'Point JAVA_HOME to JDK 21'), recommended: true),
        NoteFix('Remove JAVA_HOME', PlannedChange(title: 'Remove JAVA_HOME')),
      ],
    ),
    (
      text:
          'Your PATH has 2 folders that don\'t exist anymore, 1 folder listed twice. Every command searches through them, and leftovers from '
          'uninstalled tools can make the wrong version of a tool run.',
      fixes: [NoteFix('Clean up PATH', PlannedChange(title: 'Clean up your PATH'), recommended: true)],
    ),
  ];

  final react = FrameworkTech(package: 'react', name: 'React', color: const Color(0xFF58C4DC), monogram: 'R', logo: 'assets/tech/react.svg');
  final reactSnap = TechSnapshot(
    managerLabel: 'Found in 2 projects',
    items: [
      InstalledItem(id: 'r19', version: '19.2.6', path: '', removable: false)..usedBy.addAll([lumen.toUsage(), ledger.toUsage()]),
    ],
  )..projects.addAll([lumen, ledger]);

  state.techs = [
    TechEntry(FlutterTech(), flutter),
    TechEntry(DemoNodeTech(), node),
    TechEntry(AndroidTech(), android),
    TechEntry(XcodeTech(), xcode),
    TechEntry(GradleTech(), gradle),
    TechEntry(JavaTech(), java),
    TechEntry(PythonTech(), python),
    TechEntry(DotnetTech(), dotnet),
    TechEntry(react, reactSnap),
    TechEntry(next, nextSnap),
    TechEntry(ts, tsSnap),
  ];
  state.projects = [driftboard, pantry, orbit, lumen, atlas, ledger];
  InstalledItem junk(Project p, String name, double gigs, String back) =>
      InstalledItem(id: 'junk:${p.name}:$name', version: name, label: name, path: '${p.path}/$name', group: p.name, details: {'Comes back with': back})..sizeBytes = (gigs * gb).round();
  state.cleanups = [
    ProjectCleanup(orbit, [junk(orbit, 'build', 1.6, 'the next flutter build'), junk(orbit, '.dart_tool', 0.4, 'flutter pub get')]),
    ProjectCleanup(atlas, [junk(atlas, 'node_modules', 0.9, 'npm install')]),
    ProjectCleanup(pantry, [junk(pantry, 'build', 2.4, 'the next flutter build'), junk(pantry, 'ios/Pods', 1.1, 'pod install')]),
    ProjectCleanup(lumen, [junk(lumen, 'node_modules', 0.7, 'npm install'), junk(lumen, '.next', 0.3, 'the next build')]),
  ];
}

Future<void> settle(WidgetTester tester, [int ms = 600]) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 16));
    await Future<void>.delayed(const Duration(milliseconds: 16));
  }
}

/// Presses the button holding [f] through its own callback: a synthetic tap would make
/// the live test binding paint its green pointer crosshair into the recording.
Future<void> tap(WidgetTester tester, Finder f) async {
  final button = find
      .ancestor(
        of: f.first,
        matching: find.byWidgetPredicate((w) => (w is BaseButton || w is HoverButton || const {'HoverRow', 'SurfaceCard'}.contains(w.runtimeType.toString())) && (w as dynamic).onPressed != null),
      )
      .first;
  ((tester.widget(button) as dynamic).onPressed as VoidCallback)();
  await settle(tester, 50);
}

void main() {
  // Draw every frame the app asks for, like a normal run, not only the test's pumps (smooth 60 fps footage).
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets(
    'ad footage',
    (tester) async {
      await acrylic.Window.initialize();
      await windowManager.ensureInitialized();
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: true);
      await windowManager.setSize(const Size(1200, 750));
      await windowManager.center();
      await windowManager.show();

      final settings = Settings.memory()
        ..glass = 0
        ..themeMode = ThemeMode.dark
        ..installRoot = '$home/sdks'
        ..roots = ['$home/Projects']
        ..runInBackground = true
        ..checkEvery = 'daily'
        ..lastCheckAt = DateTime.now().subtract(const Duration(hours: 2)).millisecondsSinceEpoch;
      final state = DemoState(settings);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: settings),
            ChangeNotifierProvider<AppState>.value(value: state),
            ChangeNotifierProvider.value(value: state.jobs),
          ],
          child: const StackyardApp(),
        ),
      );
      final shell = tester.state<ShellState>(find.byType(Shell));
      void mark(String name) => print('MARK $name ${DateTime.now().millisecondsSinceEpoch}');

      // PART2: only the pick-up scenes (emulator, Xcode cache, simulators, settings).
      const part2 = bool.fromEnvironment('PART2');
      if (!part2) {
        // Warm up the Java version list (from Adoptium) so the marketplace scene doesn't wait on the network.
        await settle(tester, 2500);
        shell.open('market');
        await settle(tester, 800);
        await tap(tester, find.text('Java (JDK)'));
        for (var i = 0; i < 20 && find.text('Install').evaluate().isEmpty; i++) {
          await settle(tester, 1500);
          if (find.text('Try again').evaluate().isNotEmpty) await tap(tester, find.text('Try again'));
        }
        expect(find.text('Install'), findsWidgets, reason: 'Java versions loaded');
      }

      state.fillNow();
      shell.open('flutter');
      await settle(tester, 1500);
      print('AD READY');
      await settle(tester, 5000); // record.sh starts the recorder

      if (!part2) {
        // Hook: six Flutter SDKs, three NDKs, the 13 GB emulator nobody started for a year.
        mark('hook_flutter');
        await settle(tester, 3000);
        mark('hook_android');
        shell.open('android');
        await settle(tester, 3000);
        mark('hook_emulators');
        shell.open('emulators');
        await settle(tester, 3000);

        // Scan from nothing.
        state.forget();
        shell.open('overview');
        await settle(tester, 1500);
        mark('scan');
        await state.scan();
        await settle(tester, 4000);

        // Every tech it found, one page each.
        for (final t in [...state.techs]) {
          mark('tech_${t.id}');
          shell.open(t.id);
          await settle(tester, 1700);
        }

        // Who uses what, and making a version global (shown, then cancelled).
        mark('uses_flutter');
        shell.open('flutter');
        await settle(tester, 3000);
        mark('uses_node');
        shell.open('node');
        await settle(tester, 1500);
        mark('node_expand');
        await tap(tester, find.text('22.11.0'));
        await settle(tester, 1500);
        mark('node_global');
        await tap(tester, find.text('Make global'));
        await settle(tester, 2500);
        await tap(tester, find.text('Cancel'));
        await settle(tester, 800);

        // One-click fix with live progress.
        mark('fix');
        shell.open('overview');
        await settle(tester, 1500);
        mark('fix_click');
        await tap(tester, find.text('Install Flutter 3.19.6'));
        await settle(tester, 1500);
        mark('fix_run');
        await tap(tester, find.text('Run'));
        await settle(tester, 300);
        shell.open('activity');
        mark('fix_progress');
        await settle(tester, 6500);

        // The environment doctor's findings, each with its fix.
        mark('doctor');
        shell.open('overview');
        await settle(tester, 3500);

        // Clean up idle projects for real (made-up paths, skipped as already gone).
        mark('clean');
        shell.open('projects');
        await settle(tester, 1800);
        mark('clean_click');
        await tap(tester, find.textContaining('Clean idle projects'));
        await settle(tester, 1800);
        mark('clean_confirm');
        await tap(tester, find.text('Move to Trash'));
        await settle(tester, 3000);
      }

      // Delete the year-old tablet emulator.
      mark('emu');
      shell.open('emulators');
      await settle(tester, 1800);
      mark('emu_click');
      await tap(tester, find.text('Delete').last);
      await settle(tester, 1800);
      mark('emu_confirm');
      await tap(tester, find.text('Move to Trash'));
      await settle(tester, 3000);

      // Xcode: runtimes, simulators and the DerivedData cache, which goes to the Trash.
      mark('xcode');
      shell.open('xcode');
      await settle(tester, 1800);
      mark('xcode_expand');
      await tap(tester, find.text('DerivedData (build cache)'));
      await settle(tester, 1300);
      mark('xcode_remove');
      await tap(tester, find.text('Remove'));
      await settle(tester, 1600);
      mark('xcode_confirm');
      await tap(tester, find.text('Move to Trash'));
      await settle(tester, 2500);

      // Simulators: erase shown, then cancelled.
      mark('sims');
      shell.open('simulators');
      await settle(tester, 2000);
      mark('sims_erase');
      await tap(tester, find.text('Erase'));
      await settle(tester, 2000);
      await tap(tester, find.text('Cancel'));
      await settle(tester, 800);

      if (!part2) {
        // Get tools: the marketplace, Java's versions, the install dialog (cancelled).
        mark('market');
        shell.open('market');
        await settle(tester, 2500);
        mark('market_java');
        await tap(tester, find.text('Java (JDK)'));
        await settle(tester, 2000);
        mark('market_install');
        await tap(tester, find.text('Install'));
        await settle(tester, 3000);
        await tap(tester, find.text('Cancel'));
        await settle(tester, 800);
      }

      // Settings: menu bar, daily checks, open at login, moving your setup.
      mark('settings');
      shell.open('settings');
      await settle(tester, 2000);
      mark('settings_scroll');
      unawaited(Scrollable.ensureVisible(tester.element(find.text('Move your setup to another computer')), alignment: 0.82, duration: const Duration(milliseconds: 1400), curve: Curves.easeInOut));
      await settle(tester, 3500);
      mark('end');
      print('AD DONE');
    },
    skip: !const bool.fromEnvironment('AD'),
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
