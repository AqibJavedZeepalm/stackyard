// End-to-end: install, make global and remove,
// all through the real UI, against fixture projects only.
//   flutter test integration_test/actions_test.dart -d windows --dart-define=SHOTS=<dir> --dart-define=STEPS=all
// ignore_for_file: avoid_print
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:stackyard/core/models.dart';
import 'package:stackyard/core/sys.dart';
import 'package:stackyard/main.dart';
import 'package:stackyard/state/app_state.dart';
import 'package:stackyard/state/jobs.dart';
import 'package:stackyard/ui/shell.dart';

import 'real_machine_test.dart' show capturable, settle, shot, waitFor;

const flutterTest = String.fromEnvironment('FLUTTER_TEST_VERSION', defaultValue: '3.32.8');
const nodeTest = String.fromEnvironment('NODE_TEST_VERSION', defaultValue: '22.11.0');
const steps = String.fromEnvironment('STEPS', defaultValue: 'all');
bool runs(String step) => steps == 'all' || steps.split(',').contains(step);

late AppState state;
late ShellState shell;

TechEntry tech(String id) => state.tech(id)!;
InstalledItem? item(String techId, String version) =>
    state.tech(techId)?.snapshot.items.where((i) => i.version == version).firstOrNull;
Project fixture(String name) => state.projects.firstWhere((p) => p.name == name);

/// Scrolls the current page until [finder] is built and on screen.
Future<void> reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    final page = find.descendant(of: find.byType(ScaffoldPage), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(finder, 250, scrollable: page, maxScrolls: 80);
  }
  await tester.ensureVisible(finder.first);
  await settle(tester, 400);
}

Future<void> tapText(WidgetTester tester, String text, {int index = 0, bool last = false}) async {
  print('STEP tap "$text"');
  final f = find.text(text);
  await reveal(tester, f);
  expect(f, findsWidgets, reason: 'expected to find "$text"');
  // Dialog content is built after the page behind it, so .last targets the dialog.
  final target = last ? f.last : f.at(index);
  await tester.ensureVisible(target);
  await settle(tester, 300);
  await tester.tap(target);
  await settle(tester, 600);
}

/// Waits for the newest job to finish and the follow-up rescan to land.
Future<Job> finishJob(WidgetTester tester, {Duration timeout = const Duration(minutes: 15)}) async {
  final job = state.jobs.jobs.first;
  await waitFor(tester, () => job.status == JobStatus.done || job.status == JobStatus.failed, timeout: timeout);
  print('JOB "${job.title}" ${job.status.name}${job.error != null ? ': ${job.error}' : ''}');
  if (job.status == JobStatus.failed) print(job.log.join('\n'));
  final finished = job.finishedAt!;
  await waitFor(tester, () => state.lastScan != null && state.lastScan!.isAfter(finished) && state.phase == ScanPhase.idle,
      timeout: const Duration(minutes: 3));
  await settle(tester);
  return job;
}

/// Picks [version] in the version picker dialog that's currently open.
Future<void> pickInDialog(WidgetTester tester, String version, String action) async {
  await waitFor(tester, () => find.byType(ProgressRing).evaluate().isEmpty, timeout: const Duration(seconds: 30));
  await tester.enterText(find.byType(TextBox).last, version);
  await settle(tester, 600);
  await tester.tap(find.text(version).last);
  await settle(tester, 300);
  // The page behind can have a same-named button (e.g. the update banner's Install).
  await tapText(tester, action, last: true);
}

/// Expands the version row with [title] on the current tech page.
Future<void> expandRow(WidgetTester tester, String title) async {
  print('STEP expand $title');
  await reveal(tester, find.text(title));
  final f = find.text(title).first;
  await settle(tester, 300);
  await tester.tap(f);
  await settle(tester, 800);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('actions on fixtures', (tester) async {

    await tester.pumpWidget(capturable(await bootstrap()));
    state = tester.element(find.byType(Shell)).read<AppState>();
    shell = tester.state<ShellState>(find.byType(Shell));
    await waitFor(tester, () => state.lastScan != null && state.phase == ScanPhase.idle);

    // ---- Detection ----
    if (runs('detect')) {
      final ff = fixture('flutter_fixture');
      expect(ff.pins['flutter']?.raw, '3.35.5');
      expect(item('flutter', '3.35.5')!.usedBy.any((u) => u.name == 'flutter_fixture'), isTrue);
      final web = fixture('web_fixture');
      expect(web.deps['react']?.installed, '18.2.0');
      expect(web.pins['node']?.raw, '22');
      expect(state.tech('npm:react-native'), isNotNull, reason: 'RN tile from rn_fixture');
      expect(state.tech('npm:expo'), isNotNull, reason: 'Expo tile from rn_fixture');
      expect(find.text('React Native'), findsWidgets);
      expect(find.text('Expo'), findsWidgets);
      print('DETECT ok: flutter_fixture=3.35.5, web_fixture react=18.2.0 node=22, RN + Expo tiles shown');
      shell.open('npm:react-native');
      await settle(tester);
      await shot(tester, 'detect-react-native-tile');
      shell.open('npm:react');
      await settle(tester);
      await shot(tester, 'detect-react-fixture');
    }

    // ---- Install a Flutter version through the UI ----
    if (runs('flutter-install')) {
      shell.open('flutter');
      await settle(tester);
      await tapText(tester, 'Install version');
      await shot(tester, 'flutter-install-picker');
      await pickInDialog(tester, flutterTest, 'Install');
      await shot(tester, 'flutter-install-confirm');
      await tapText(tester, 'Run');
      shell.open('activity');
      await settle(tester, 4000);
      await shot(tester, 'flutter-install-running');
      final job = await finishJob(tester);
      expect(job.status, JobStatus.done);
      final installed = item('flutter', flutterTest);
      expect(installed, isNotNull, reason: 'new version detected after install');
      expect(installed!.status, ItemStatus.unused);
      shell.open('flutter');
      await settle(tester);
      await shot(tester, 'flutter-installed-unused');
    }

    // ---- Make it global, verify, restore the original global ----
    if (runs('flutter-global')) {
      final original = tech('flutter').global!.version;
      // "3.29.3 (standalone)" for an SDK FVM doesn't manage.
      final originalTitle = tech('flutter').global!.title;
      print('GLOBAL original=$originalTitle');
      shell.open('flutter');
      await settle(tester);
      await expandRow(tester, flutterTest);
      await tapText(tester, 'Make global');
      await tapText(tester, 'Run');
      expect((await finishJob(tester)).status, JobStatus.done);
      expect(tech('flutter').global?.version, flutterTest);
      await shot(tester, 'flutter-global-changed');
      await expandRow(tester, originalTitle);
      await tapText(tester, 'Make global');
      await tapText(tester, 'Run');
      expect((await finishJob(tester)).status, JobStatus.done);
      expect(tech('flutter').global?.version, original, reason: 'global restored');
      await shot(tester, 'flutter-global-restored');
    }

    // ---- Install a Node version (nvm) ----
    if (runs('node-install')) {
      shell.open('node');
      await settle(tester);
      await tapText(tester, 'Install version');
      await pickInDialog(tester, nodeTest, 'Install');
      await shot(tester, 'node-install-confirm');
      await tapText(tester, 'Run');
      final job = await finishJob(tester);
      expect(job.status, JobStatus.done);
      expect(item('node', nodeTest), isNotNull, reason: 'nvm version detected');
      expect(item('node', nodeTest)!.usedBy.any((u) => u.name == 'web_fixture'), isTrue,
          reason: 'web_fixture .nvmrc "22" resolves to the new version');
      await shot(tester, 'node-installed-used-by-fixture');
    }

    // ---- Remove what we installed ----
    if (runs('remove')) {
      for (final (techId, version) in [('flutter', flutterTest), ('node', nodeTest), ('python', '3.11.17')]) {
        if (item(techId, version) == null) continue;
        shell.open(techId);
        await settle(tester);
        await expandRow(tester, version);
        await shot(tester, '$techId-remove-expanded');
        await tapText(tester, 'Remove');
        await shot(tester, '$techId-remove-confirm');
        await tapText(tester, 'Move to ${Sys.trashName}');
        await settle(tester, 1500);
        await shot(tester, '$techId-remove-collapsing');
        expect((await finishJob(tester)).status, JobStatus.done);
        expect(item(techId, version), isNull, reason: '$techId $version gone after removal');
        await shot(tester, '$techId-removed');
        print('REMOVE $techId $version ok');
      }
      shell.open('activity');
      await settle(tester);
      await shot(tester, 'activity-after-all');
    }

    // flutter_test fails the test on any uncaught Flutter error by itself.
  }, timeout: const Timeout(Duration(minutes: 30)));
}
